# Offline tests for the queue-based cost ingest (Modules/CostIngest.psm1, PlanCostIngest-Timer,
# ProcessCostTask-Queue). Cost Management is a fake per-subscription series, the queue is a list,
# and tasks are worked through by running the real queue function. No Azure.
# Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$subA = $sub                                        # 10 USD a day
$subB = '22222222-2222-3333-4444-555555555555'      # 1000 USD a day
$global:RestResponder = {
    param($Method, $Uri, $Body)
    if ($Uri -like '*management.azure.com/subscriptions?*') {
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ subscriptionId = $subA; displayName = 'Production'; state = 'Enabled' }
            [PSCustomObject]@{ subscriptionId = $subB; displayName = 'Sandbox'; state = 'Enabled' }
        ); nextLink = $null }
    }
    throw "unexpected REST call: $Method $Uri"
}
function Set-Scope { param([string[]]$Ids)
    $json = if ($Ids -and $Ids.Count) { (@($Ids) | ConvertTo-Json -Compress -AsArray) } else { '' }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $json }
}

# --- fake Cost Management: one resource per subscription, a fixed amount every day -------------
$global:CostCalls = [System.Collections.Generic.List[object]]::new()
$global:FailSubs = @{}          # subscription id -> how many more calls to fail
$global:FailHistorySub = $null  # this subscription fails every call older than the nightly window
function global:Get-SubscriptionDailyCost {
    param($SubscriptionId, $MgmtToken, $From, $To, $CostType)
    $global:CostCalls.Add([PSCustomObject]@{ Sub = $SubscriptionId; From = $From.Date; To = $To.Date })
    if ($global:FailSubs[$SubscriptionId] -gt 0) { $global:FailSubs[$SubscriptionId]--; throw 'COST_QUERY_THROTTLED: test throttle' }
    if ($global:FailHistorySub -eq $SubscriptionId -and $To -lt [datetime]::UtcNow.Date.AddDays(-9)) { throw 'COST_QUERY_THROTTLED: history throttle' }
    $perDay = if ($SubscriptionId -eq $subB) { 1000.0 } else { 10.0 }
    $rows = @(); $days = @{}
    for ($d = $From.Date; $d -le $To.Date; $d = $d.AddDays(1)) {
        $k = $d.ToString('yyyy-MM-dd')
        $rows += [PSCustomObject]@{ Date = $k; ResourceId = "/subscriptions/$SubscriptionId/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1"
                                    Scope = $SubscriptionId; Meter = 'Virtual Machines'; CostUsd = $perDay }
        $days[$k] = @{ Usd = $perDay; Billing = $perDay * 7; Currency = 'EUR' }
    }
    return @{ Rows = $rows; Days = $days; Currency = 'EUR' }
}

# --- the queue ------------------------------------------------------------------------------------
$global:Queue = [System.Collections.Generic.List[object]]::new()
function global:Add-QueueMessage {
    param($Queue, [hashtable]$Message, [int]$DelaySeconds = 0, $Token)
    # Round-trip through JSON, as the real queue does.
    $global:Queue.Add([PSCustomObject]@{ Message = ($Message | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json -AsHashtable); Delay = $DelaySeconds })
}
function global:Remove-TableEntityBatch {
    param($Table, $Entities, $Token)
    foreach ($e in @($Entities)) { $global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") }
    return @($Entities).Count
}
$worker = Join-Path $fa 'ProcessCostTask-Queue/run.ps1'
# Works the queue like the host (one at a time, delays ignored). Follow-up tasks are only
# recorded: they run the real analysis timers, which other test files cover.
function Invoke-Drain {
    $global:Followups = @()
    for ($i = 0; $i -lt 500 -and $global:Queue.Count; $i++) {
        $m = $global:Queue[0].Message; $global:Queue.RemoveAt(0)
        if ($m.kind -eq 'followup') { $global:Followups += , $m; continue }
        & $worker -Task $m -TriggerMetadata $null *> $null
    }
}
function Reset-Ingest {
    Reset-State
    $global:Queue.Clear(); $global:CostCalls.Clear(); $global:FailSubs = @{}; $global:FailHistorySub = $null
}
# Today 03:00 UTC: after the nightly start hour.
$now = [datetime]::UtcNow.Date.AddHours(3)
$today = $now.Date
$settled = Get-RollingWindowEndDate -Today $today
function Get-Row { param($Table, $Key) $global:Store[$Table][$Key] }

Write-Host "`nQueue-based ingest: the nightly run"
Test-That 'a run queues one task per included subscription and records every one it can see' {
    Reset-Ingest
    Set-Scope @($subA)
    Assert-Equal 'started' (Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now) 'planner'
    $disc = @([string](Get-Row 'PortalConfig' 'subscriptions|discovered').SubscriptionsJson | ConvertFrom-Json)
    Assert-Equal 2 $disc.Count 'both recorded for the scope script to offer'
    Assert-Equal 1 $global:Queue.Count 'one task'
    Assert-Equal $subA $global:Queue[0].Message.subId 'only the included one'
    Assert-Equal 'running' (Get-Row 'PortalConfig' 'ingestrun|current').Status 'run open'
    Assert-Equal 'running' (Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now) 'a second planner pass leaves it alone'
    Assert-Equal 1 $global:Queue.Count 'nothing queued twice'
}
Test-That 'the last task completes the run: day totals, month rows, snapshots and the marker' {
    Reset-Ingest
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    # Only the nightly tasks (the history is queued after the run completes).
    $n = $global:Queue.Count
    for ($i = 0; $i -lt $n; $i++) { $m = $global:Queue[0].Message; $global:Queue.RemoveAt(0); & $worker -Task $m -TriggerMetadata $null *> $null }
    $day = $settled.ToString('yyyy-MM-dd')
    $t = Get-Row 'CostSummary' "dailytotal|$day"
    Assert-Equal 1010.0 $t.TotalUsd 'both subscriptions summed'
    Assert-Equal 7070.0 $t.TotalBilling 'billing currency summed'
    Assert-Equal 'EUR' $t.Currency 'currency'
    $mk = Get-Row 'PortalConfig' 'ingest|lastrun'
    Assert-True ([bool]$mk.Complete) 'marker complete'
    Assert-Equal 2 $mk.SubscriptionsOk 'ok count'
    Assert-Equal 'EUR' $mk.BillingCurrency 'billing currency recorded for SyncAdvisor'
    Assert-Equal $today.ToString('yyyy-MM-dd') ([datetime]$mk.At).ToUniversalTime().ToString('yyyy-MM-dd') 'today, so the detectors see it'
    Assert-Equal 2 @($global:Store['CostSnapshots'].Values | Where-Object { $_.PartitionKey -eq $day }).Count 'one resource row per subscription'
    Assert-Equal 'done' (Get-Row 'PortalConfig' 'ingestrun|current').Status 'run closed'
    Assert-True (@($global:Queue | Where-Object { $_.Message.kind -eq 'history' }).Count -eq 1) 'history queued once the run is done'
}
Test-That 'a throttled subscription is put back on the queue with a delay, then completes the run' {
    Reset-Ingest
    $global:FailSubs[$subB] = 2
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    $delays = @()
    for ($i = 0; $i -lt 20 -and @($global:Queue | Where-Object { $_.Message.kind -eq 'recent' }).Count; $i++) {
        $q = $global:Queue[0]; $global:Queue.RemoveAt(0)
        if ($q.Message.kind -ne 'recent') { continue }
        if ($q.Message.attempt -gt 1) { $delays += $q.Delay }
        & $worker -Task $q.Message -TriggerMetadata $null *> $null
    }
    Assert-Equal '120,240' ($delays -join ',') 'backs off longer each time'
    Assert-True ([bool](Get-Row 'PortalConfig' 'ingest|lastrun').Complete) 'complete after the retries'
}
Test-That 'a subscription that never answers: the run completes without it, and its days get no partial total' {
    Reset-Ingest
    $global:FailSubs[$subB] = 99
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    for ($i = 0; $i -lt 30 -and @($global:Queue | Where-Object { $_.Message.kind -eq 'recent' }).Count; $i++) {
        $q = $global:Queue[0]; $global:Queue.RemoveAt(0)
        if ($q.Message.kind -eq 'recent') { & $worker -Task $q.Message -TriggerMetadata $null *> $null }
    }
    $mk = Get-Row 'PortalConfig' 'ingest|lastrun'
    Assert-True (-not [bool]$mk.Complete) 'reported incomplete'
    Assert-Equal 1 $mk.SubscriptionsOk 'one of two'
    Assert-True ($null -eq (Get-Row 'CostSummary' "dailytotal|$($settled.ToString('yyyy-MM-dd'))")) 'no day total from half the tenant'
}
Test-That 'a run whose tasks went missing is completed by the planner after three hours' {
    Reset-Ingest
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    $global:Queue.Clear()   # lost
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'ingestrun'; RowKey = 'current'; StartedAt = $now.AddHours(-4).ToString('o') }
    Assert-Equal 'recovered' (Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now) 'planner'
    $mk = Get-Row 'PortalConfig' 'ingest|lastrun'
    Assert-True ($mk -and -not [bool]$mk.Complete) 'marker written, incomplete'
}
Test-That 'no run before 02:00 once one ran yesterday; a new deployment starts at any hour' {
    Reset-Ingest
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'ingestrun'; RowKey = 'current'; Status = 'done'; Date = $today.AddDays(-1).ToString('yyyy-MM-dd'); RunId = 'x' }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'backfill'; RowKey = 'history'; CostType = 'AmortizedCost'; Pending = '[]'; Covered = '[]' }
    Assert-True ((Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $today.AddHours(1)) -ne 'started') 'waits for 02:00'
    Reset-Ingest
    Assert-Equal 'started' (Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $today.AddHours(1)) 'nothing ever ran'
}

Write-Host "`nQueue-based ingest: history"
Test-That 'history loads one month per task for every subscription, newest first, then queues the analysis' {
    Reset-Ingest
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    Invoke-Drain
    $w = Get-CostIngestWindow -StorageToken 't' -Today $today
    $hist = @($global:CostCalls | Where-Object { $_.To -lt $w.From } | Where-Object Sub -eq $subA)
    $months = @($hist | ForEach-Object { $_.From.ToString('yyyy-MM') })
    Assert-Equal (@(Get-MonthSlices -From $w.HistoryFrom -To $w.From.AddDays(-1)).Count) $months.Count 'one query per month'
    Assert-Equal (($months | Sort-Object -Descending) -join ',') ($months -join ',') 'newest month first'
    Assert-True (@($hist | Where-Object { $_.From.Month -ne $_.To.Month }).Count -eq 0) 'no query crosses a month (one QPU each)'
    $old = $w.HistoryFrom.AddDays(1).ToString('yyyy-MM-dd')
    Assert-Equal 1010.0 (Get-Row 'CostSummary' "dailytotal|$old").TotalUsd 'an old day totalled'
    $st = Get-Row 'PortalConfig' 'backfill|history'
    Assert-True ([bool]$st.Complete) 'history complete'
    Assert-Equal 2 @([string]$st.Covered | ConvertFrom-Json).Count 'both covered'
    Assert-Equal 1 @($global:Followups).Count 'analysis queued once'
    Assert-Equal 'SyncMonthlyCosts-Timer,DetectSavings-Timer,DetectCostSpikes-Timer,SyncAllocation-Timer,brief' (@($global:Followups[0].steps) -join ',') 'steps'
    $prevMonth = $today.AddMonths(-1).ToString('yyyy-MM')
    Assert-True ($null -ne (Get-Row 'CostSummary' "monthly-sub|$prevMonth|$subA")) 'a complete past month gets its monthly row'
    $calls = $global:CostCalls.Count
    Assert-Equal 'complete' (Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now) 'nothing left'
    Assert-Equal $calls $global:CostCalls.Count 'no query'
}
Test-That 'a history month one subscription fails writes nothing for that month' {
    Reset-Ingest
    $global:FailHistorySub = $subB
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    Invoke-Drain
    $w = Get-CostIngestWindow -StorageToken 't' -Today $today
    $old = $w.From.AddDays(-3).ToString('yyyy-MM-dd')
    Assert-Equal 0 @($global:Store['CostSnapshots'].Values | Where-Object { $_.PartitionKey -eq $old }).Count 'no half-loaded day for the detectors'
    Assert-True ($null -eq (Get-Row 'CostSummary' "dailysub|$old|$subA")) 'not even the subscription that answered'
    Assert-True (-not [bool](Get-Row 'PortalConfig' 'backfill|history').Complete) 'history not complete'
    Assert-Equal '' ([string](Get-Row 'PortalConfig' 'backfill|history').InFlight) 'handed back to the planner after the last attempt'
}

Write-Host "`nQueue-based ingest: scope changes"
Test-That 'a scope change re-totals from the stored rows, without a single query' {
    Reset-Ingest
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    Invoke-Drain
    $calls = $global:CostCalls.Count
    Set-Scope @($subA)
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now.AddHours(2)
    $w = Get-CostIngestWindow -StorageToken 't' -Today $today
    $old = $w.HistoryFrom.AddDays(1).ToString('yyyy-MM-dd')
    Assert-Equal 10.0 (Get-Row 'CostSummary' "dailytotal|$old").TotalUsd 'old day without the excluded subscription'
    Assert-Equal $calls $global:CostCalls.Count 'no Cost Management query'
    Assert-Equal (Get-SubscriptionScope -Token 't').Hash (Get-Row 'PortalConfig' 'backfill|dailytotal90').ScopeHash 'marker records the new scope'
}
Test-That 'a subscription added back gets its own history fetched, and only its own' {
    Reset-Ingest
    Set-Scope @($subA)
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    Invoke-Drain
    $global:CostCalls.Clear()
    Set-Scope @($subA, $subB)
    $null = Update-CostHistoryPlan -StorageToken 't' -Today $today
    Invoke-Drain
    $w = Get-CostIngestWindow -StorageToken 't' -Today $today
    Assert-Equal 0 @($global:CostCalls | Where-Object Sub -eq $subA).Count 'the covered one is not refetched'
    Assert-True (@($global:CostCalls | Where-Object Sub -eq $subB).Count -gt 0) 'the new one is'
    $old = $w.HistoryFrom.AddDays(1).ToString('yyyy-MM-dd')
    Assert-Equal 1010.0 (Get-Row 'CostSummary' "dailytotal|$old").TotalUsd 'old day now includes it'
}
Test-That 'a cost-type change refetches the history on the new basis' {
    Reset-Ingest
    $null = Invoke-CostIngestPlanner -StorageToken 't' -MgmtToken 'm' -Now $now
    Invoke-Drain
    Set-Setting @{ CostType = 'ActualCost' }
    $global:CostCalls.Clear()
    $null = Update-CostHistoryPlan -StorageToken 't' -Today $today
    Invoke-Drain
    Assert-True ($global:CostCalls.Count -gt 0) 'refetched'
    Assert-Equal 'ActualCost' (Get-Row 'PortalConfig' 'backfill|history').CostType 'state on the new basis'
}

Write-Host "`nCost Management parsing"
Test-That 'per-resource query: charges without a resource count in the day total, not as a resource' {
    Reset-State
    $global:CostResponder = {
        param($b, $Uri)
        if ($b.dataset.grouping) {
            return New-CostResponse -Columns @('CostUSD', 'UsageDate', 'ResourceId', 'MeterCategory', 'Currency') -Rows @(
                , @(30.0, 20261001, '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1', 'Virtual Machines', 'USD')
                , @(12.0, 20261001, '/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1', 'Bandwidth', 'USD')
                , @(5.0, 20261001, '', 'Support', 'USD'))
        }
        return New-CostResponse -Columns @('Cost', 'UsageDate', 'Currency') -Rows @(, @(330.0, 20261001, 'DKK'))
    }
    $r = & (Get-Module CostAnalysis) { param($s, $t) Get-SubscriptionDailyCost -SubscriptionId 'x' -MgmtToken 't' -From ([datetime]'2026-10-01') -To ([datetime]'2026-10-01') -CostType 'AmortizedCost' } 'x' 't'
    Assert-Equal 1 @($r.Rows).Count 'one resource row'
    Assert-Equal 42.0 @($r.Rows)[0].CostUsd 'meters summed per resource'
    Assert-Equal 'Virtual Machines' @($r.Rows)[0].Meter 'costliest meter as the label'
    Assert-Equal 47.0 $r.Days['2026-10-01'].Usd 'day total includes the unattributed 5'
    Assert-Equal 330.0 $r.Days['2026-10-01'].Billing 'billing currency from its own query'
    Assert-Equal 'DKK' $r.Currency 'currency'
}
Test-That 'throttling waits for the Cost Management QPU header, not a blind 20 seconds' {
    $h = @{ 'x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after' = '7'; 'Retry-After' = '3' }
    Assert-Equal 7 (& (Get-Module CostAnalysis) { param($x) Get-CostRetryAfterSeconds -Headers $x } $h) 'the QPU wait'
    Assert-Equal 20 (& (Get-Module CostAnalysis) { Get-CostRetryAfterSeconds -Headers @{} }) 'default when nothing is stated'
}

Write-Host "`nMonth overview budgets"
Test-That '300 resource-group budgets fit (own rows), shrink cleanly, and old inline lists still read' {
    Reset-State
    $items = @(1..300 | ForEach-Object { [PSCustomObject]@{ Name = "budget-$_"; Scope = "/subscriptions/$subA/resourceGroups/rg$_"; ResourceGroupId = "/subscriptions/$subA/resourcegroups/rg$_"; Amount = 100.0 + $_; Currency = 'DKK' } })
    $n = Save-MonthBudgetList -Kind Rg -Items $items -StorageToken 't'
    Assert-Equal 8 $n 'rows of 40'
    $max = (@($global:Store['CostSummary'].Values | Where-Object { $_.PartitionKey -eq 'monthbudgets' } | ForEach-Object { ([string]$_.ItemsJson).Length }) | Measure-Object -Maximum).Maximum
    Assert-True ($max -lt 32000) "each row well under the 64 KiB property limit ($max chars)"
    $ov = [PSCustomObject]@{ RgBudgetRows = $n; RgBudgetsJson = '' }
    Assert-Equal 300 @(Get-MonthBudgetList -Overview $ov -Kind Rg -StorageToken 't').Count 'all read back'
    $n2 = Save-MonthBudgetList -Kind Rg -Items @($items | Select-Object -First 10) -StorageToken 't'
    Assert-Equal 1 @($global:Store['CostSummary'].Values | Where-Object { $_.PartitionKey -eq 'monthbudgets' }).Count 'stale rows removed'
    Assert-Equal 10 @(Get-MonthBudgetList -Overview ([PSCustomObject]@{ RgBudgetRows = $n2 }) -Kind Rg -StorageToken 't').Count 'shorter list'
    $legacy = [PSCustomObject]@{ RgBudgetsJson = (@($items[0]) | ConvertTo-Json -Compress -AsArray) }
    Assert-Equal 1 @(Get-MonthBudgetList -Overview $legacy -Kind Rg -StorageToken 't').Count 'old inline property still read'
}

Write-Host "`nNo credentials in logs"
Test-That 'a failing web call drops the request (and its Authorization header) from the error' {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'https://acct.table.core.windows.net/CostSummary?sig=secret')
    $req.Headers.TryAddWithoutValidation('Authorization', 'Bearer super-secret') | Out-Null
    $rec = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Response status code does not indicate success: 400 (Bad Request).'), 'x', 'InvalidOperation', $req)
    $e = ConvertTo-SafeWebError -ErrorRecord $rec
    Assert-True ($e.Message -notmatch 'super-secret') 'no token'
    Assert-True ($e.Message -notmatch 'sig=') 'no query string'
    Assert-True ($e.Message -match 'acct\.table\.core\.windows\.net/CostSummary') 'still says where'
}

Write-Host ""
Write-Host "Cost ingest tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
