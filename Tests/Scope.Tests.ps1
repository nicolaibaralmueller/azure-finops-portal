# Offline tests for the operator's SUBSCRIPTION SCOPE (Setup/Set-SubscriptionScope.ps1 ->
# PortalConfig 'settings/scope'): excluded subscriptions are hidden at read time everywhere,
# tenant-wide aggregates are rebuilt by the next nightly run, and nothing is deleted.
# No Azure: everything goes through the stubs in TestKit.ps1. Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$subA = $sub                                        # included
$subB = '22222222-2222-3333-4444-555555555555'      # the one we exclude
$vmB  = "/subscriptions/$subB/resourcegroups/rg-sandbox/providers/microsoft.compute/virtualmachines/vm-sandbox01"
$stA  = "/subscriptions/$subA/resourcegroups/rg/providers/microsoft.storage/storageaccounts/steady"

function Set-Scope { param([string[]]$Ids)
    $json = if ($Ids -and $Ids.Count) { (@($Ids) | ConvertTo-Json -Compress -AsArray) } else { '' }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = $json; ScopeHash = (Get-SubscriptionScopeHash -Ids $Ids) }
}
function Read-Body { param($Response) [string]$Response.Body | ConvertFrom-Json }

# The subscription list ARM returns (the real Get-AccessibleSubscriptions calls Invoke-RestMethod).
$global:RestResponder = {
    param($Method, $Uri, $Body)
    if ($Uri -like '*management.azure.com/subscriptions?*') {
        return [PSCustomObject]@{ value = @(
            [PSCustomObject]@{ subscriptionId = $subA; displayName = 'Production'; state = 'Enabled' }
            [PSCustomObject]@{ subscriptionId = $subB; displayName = 'Sandbox'; state = 'Enabled' }
            [PSCustomObject]@{ subscriptionId = '33333333-2222-3333-4444-555555555555'; displayName = 'Old'; state = 'Disabled' }
        ); nextLink = $null }
    }
    throw "unexpected REST call: $Method $Uri"
}

Write-Host "`nScope helpers"
Test-That 'no scope row, an empty list or bad JSON all mean ALL' {
    Reset-State
    Assert-True ($null -eq (Get-SubscriptionScope -Token 't').Ids) 'no row'
    Assert-Equal 'all' (Get-SubscriptionScope -Token 't').Hash 'hash'
    Set-Scope @()
    Assert-True ($null -eq (Get-SubscriptionScope -Token 't').Ids) 'empty list'
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'settings'; RowKey = 'scope'; IncludedSubscriptionIds = 'not json' }
    Assert-True ($null -eq (Get-SubscriptionScope -Token 't').Ids) 'bad json'
}
Test-That 'a scope is a lower-cased set with an order-independent hash' {
    Reset-State
    Set-Scope @($subA.ToUpper(), $subB)
    $s = Get-SubscriptionScope -Token 't'
    Assert-Equal 2 $s.Count 'count'
    Assert-True ($s.Ids.Contains($subA)) 'lower-cased'
    Assert-Equal (Get-SubscriptionScopeHash -Ids @($subB, $subA)) $s.Hash 'hash ignores order and case'
    Assert-True ($s.Hash -ne 'all') 'not all'
}
Test-That 'rows are matched by SubscriptionId, Scope or ResourceId; tenant-level rows always pass' {
    Reset-State
    Set-Scope @($subA)
    $s = Get-SubscriptionScope -Token 't'
    Assert-True (Test-InSubscriptionScope -Scope $s -Value ([PSCustomObject]@{ SubscriptionId = $subA })) 'SubscriptionId'
    Assert-True (-not (Test-InSubscriptionScope -Scope $s -Value ([PSCustomObject]@{ Scope = $subB }))) 'Scope guid'
    Assert-True (-not (Test-InSubscriptionScope -Scope $s -Value ([PSCustomObject]@{ ResourceId = $vmB }))) 'ResourceId'
    Assert-True (-not (Test-InSubscriptionScope -Scope $s -Value "/subscriptions/$subB")) 'budget-style scope string'
    Assert-True (Test-InSubscriptionScope -Scope $s -Value ([PSCustomObject]@{ ResourceId = '/providers/Microsoft.Capacity/reservationOrders/x' })) 'tenant-level row kept'
    Assert-True (Test-InSubscriptionScope -Scope ([PSCustomObject]@{ Ids = $null; Hash = 'all' }) -Value $subB) 'ALL scope keeps everything'
}
Test-That 'Get-AccessibleSubscriptions applies the scope only when given a storage token' {
    Reset-State
    Set-Scope @($subA)
    Assert-Equal 2 @(Get-AccessibleSubscriptions -MgmtToken 't').Count 'unscoped: enabled only'
    $scoped = @(Get-AccessibleSubscriptions -MgmtToken 't' -StorageToken 't')
    Assert-Equal 1 $scoped.Count 'scoped'
    Assert-Equal $subA $scoped[0].Id 'the included one'
}
Test-That 'a pending rebuild is reported until the aggregate carries the current hash' {
    Reset-State
    $s = Get-SubscriptionScope -Token 't'
    Assert-True (-not (Test-ScopeHashPending -Scope $s -Stored $null)) 'all vs legacy row'
    Set-Scope @($subA)
    $s = Get-SubscriptionScope -Token 't'
    Assert-True (Test-ScopeHashPending -Scope $s -Stored '') 'legacy row was built for all'
    Assert-True (-not (Test-ScopeHashPending -Scope $s -Stored $s.Hash)) 'rebuilt'
}

Write-Host "`nRead endpoints hide excluded subscriptions (nothing deleted)"
function Initialize-ReadStore {
    Reset-State
    $run = '2026-09-17T02:35:00Z'
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = $run }
    foreach ($f in @(@{ id = 'aaaaaaaaaaaaaaaa'; rid = $stA; usd = 40.0 }, @{ id = 'bbbbbbbbbbbbbbbb'; rid = $vmB; usd = 300.0 })) {
        Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = $f.id; RunId = $run; Category = 'orphaned'; Tier = 'certain'
            ResourceId = $f.rid; Title = 'x'; Detail = 'x'; EstMonthlySavingsUsd = $f.usd; Confidence = 'high' }
    }
    $month = [datetime]::UtcNow.ToString('yyyy-MM')
    Set-TableEntity -Table 'SavingsStatus' -Entity @{ PartitionKey = 'status'; RowKey = 'bbbbbbbbbbbbbbbb'; Status = 'done'; ResourceId = $vmB; RealisedUsd = 300.0; RealisedAt = "$month-10T00:00:00Z" }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'advisor-meta'; RowKey = 'latest'; LatestRunId = 'r1' }
    foreach ($r in @(@{ id = 'r-a'; rid = $stA }, @{ id = 'r-b'; rid = $vmB })) {
        Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = $r.id; RunId = 'r1'; ResourceId = $r.rid; Problem = 'p'; Solution = 's'
            SavingsAmount = 10.0; Currency = 'USD'; EstMonthlySavingsUsd = 10.0; SavingsConverted = $true }
    }
    foreach ($s in @($subA, $subB)) {
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'monthly-sub'; RowKey = "2026-08|$s"; SubscriptionId = $s; SubscriptionName = "n-$s"; Month = '2026-08'; CostUsd = 100.0 }
    }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'latestperiod'; RowKey = 'week'; Period = '2026-09-15'; PeriodStart = '2026-09-09'; PeriodEnd = '2026-09-15' }
    foreach ($c in @(@{ id = '1111111111111111'; scope = $subA; rid = $stA }, @{ id = '2222222222222222'; scope = $subB; rid = $vmB })) {
        Set-TableEntity -Table 'CostSpikes' -Entity @{ PartitionKey = 'week|2026-09-15'; RowKey = $c.id; PeriodType = 'week'; Period = '2026-09-15'
            Dimension = 'resource'; Scope = $c.scope; ResourceId = $c.rid; SpikeUsd = 900.0; BaselineUsd = 300.0; DeltaUsd = 600.0; DeltaPct = 200.0 }
    }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'analyzed'; RowKey = 'week|2026-09-15'; At = 'x' }
}
Test-That 'without a scope everything is visible (today''s behaviour)' {
    Initialize-ReadStore
    Assert-Equal 2 @((Read-Body (Invoke-HttpFunction -Name 'GetSavings')).findings).Count 'savings'
    Assert-Equal 2 @((Read-Body (Invoke-HttpFunction -Name 'GetRecommendations')).recommendations).Count 'advisor'
    Assert-Equal 2 (Read-Body (Invoke-HttpFunction -Name 'GetCostSpikes' -Query @{ periodType = 'week' })).count 'changes'
}
Test-That 'a link to an exact period serves that period (Overview -> Cost changes)' {
    Initialize-ReadStore
    $ch = Read-Body (Invoke-HttpFunction -Name 'GetCostSpikes' -Query @{ periodType = 'week'; key = '2026-09-15'; offset = '3' })
    Assert-Equal '2026-09-15' $ch.period 'the key wins over offset'
    Assert-Equal '2026-09-09' $ch.periodStart 'a 7-day window ending on the key'
    Assert-Equal 2 $ch.count 'its findings'
    $bad = Read-Body (Invoke-HttpFunction -Name 'GetCostSpikes' -Query @{ periodType = 'week'; key = "2026-09-15' or 1 eq 1" })
    Assert-True ($bad.period -ne "2026-09-15' or 1 eq 1") 'a malformed key is ignored'
}
Test-That 'excluding a subscription hides its rows at once, everywhere' {
    Initialize-ReadStore
    Set-Scope @($subA)
    $sv = Read-Body (Invoke-HttpFunction -Name 'GetSavings')
    Assert-Equal 'aaaaaaaaaaaaaaaa' ((@($sv.findings) | ForEach-Object id) -join ',') 'savings'
    Assert-Equal 0 ([double]$sv.realisedThisMonthUsd) 'realised of the excluded one not counted'
    $rec = Read-Body (Invoke-HttpFunction -Name 'GetRecommendations')
    Assert-Equal 'r-a' ((@($rec.recommendations) | ForEach-Object id) -join ',') 'advisor'
    $ch = Read-Body (Invoke-HttpFunction -Name 'GetCostSpikes' -Query @{ periodType = 'week' })
    Assert-Equal '1111111111111111' ((@($ch.spikes) | ForEach-Object id) -join ',') 'changes'
    Assert-Equal 2 @($global:Store['SavingsFindings'].Values | Where-Object PartitionKey -eq 'savings').Count 'nothing deleted'
    Assert-Equal 2 $global:Store['CostSpikes'].Count 'findings kept'
}
Test-That 'actions on an excluded subscription answer 404' {
    Initialize-ReadStore
    Set-Scope @($subA)
    Assert-Equal 404 ([int](Invoke-HttpFunction -Name 'ExplainSpike' -Body ([PSCustomObject]@{ spikeId = '2222222222222222'; periodType = 'week'; period = '2026-09-15' })).StatusCode) 'explain'
    Assert-Equal 404 ([int](Invoke-HttpFunction -Name 'SetSavingsStatus' -Body ([PSCustomObject]@{ id = 'bbbbbbbbbbbbbbbb'; status = 'dismissed' })).StatusCode) 'set status'
}
Test-That 're-adding the subscription brings everything back' {
    Initialize-ReadStore
    Set-Scope @($subA)
    Set-Scope @()
    Assert-Equal 2 @((Read-Body (Invoke-HttpFunction -Name 'GetSavings')).findings).Count 'savings back'
    Assert-Equal 2 (Read-Body (Invoke-HttpFunction -Name 'GetCostSpikes' -Query @{ periodType = 'week' })).count 'changes back'
}
Test-That 'GetPortalConfig reports the scope with names, and a pending rebuild' {
    Initialize-ReadStore
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'subscriptions'; RowKey = 'discovered'; Count = 2
        SubscriptionsJson = (@([ordered]@{ id = $subA; name = 'Production' }, [ordered]@{ id = $subB; name = 'Sandbox' }) | ConvertTo-Json -Compress -AsArray) }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'backfill'; RowKey = 'dailytotal90'; CostType = 'AmortizedCost'; IncludesBilling = $true }
    $cfg = Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')
    Assert-True ([bool]$cfg.subscriptionScope.all) 'all by default'
    Assert-True (-not [bool]$cfg.subscriptionScope.pending) 'nothing pending'
    Set-Scope @($subA)
    $cfg = Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')
    Assert-True (-not [bool]$cfg.subscriptionScope.all) 'scoped'
    Assert-Equal 'Production' (@($cfg.subscriptionScope.included)[0].name) 'names from the discovered list'
    Assert-Equal 2 $cfg.subscriptionScope.total 'of two'
    Set-Scope @($subA, '99999999-9999-9999-9999-999999999999')
    $cfg = Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')
    Assert-Equal $subA ((@($cfg.subscriptionScope.included) | ForEach-Object id) -join ',') 'a subscription the identity cannot read is not listed'
    Set-Scope @($subA)
    $cfg = Read-Body (Invoke-HttpFunction -Name 'GetPortalConfig')
    Assert-True ([bool]$cfg.subscriptionScope.pending) 'totals still include the old set'
    $trend = Read-Body (Invoke-HttpFunction -Name 'GetCostTrend')
    Assert-True ([bool]$trend.scopePending) 'trend says so too'
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'backfill'; RowKey = 'dailytotal90'; ScopeHash = (Get-SubscriptionScope -Token 't').Hash }
    Assert-True (-not [bool](Read-Body (Invoke-HttpFunction -Name 'GetCostTrend')).scopePending) 'cleared once rebuilt'
}

Write-Host "`nNightly: stubs shared by the tests below"
$global:TotalsCalls = [System.Collections.Generic.List[object]]::new()
function global:Get-BillingCurrency { param($SubscriptionId, $MgmtToken, $CostType) 'EUR' }
function global:Get-DailyResourceCost { param($SubscriptionId, $MgmtToken, $From, $To, $CostType) @() }
function global:Get-CostTotalSeries {
    param($SubscriptionId, $MgmtToken, $From, $To, $Granularity, $CostType, [switch]$IncludeNative)
    $global:TotalsCalls.Add([PSCustomObject]@{ Sub = $SubscriptionId; From = $From })
    $perDay = if ($SubscriptionId -eq $subB) { 1000.0 } else { 10.0 }
    for ($d = $From.Date; $d -le $To.Date; $d = $d.AddDays(1)) {
        [PSCustomObject]@{ Period = $d.ToString('yyyy-MM-dd'); CostUsd = $perDay; CostBilling = $perDay * 7; Currency = 'EUR' }
    }
}
function global:Remove-TableEntityBatch { param($Table, $Entities, $Token) 0 }
# The ingest's own scope behaviour (queries only included subscriptions, re-totals on a scope change,
# fetches history for a subscription added back) is tested in CostIngest.Tests.ps1.

Write-Host "`nNightly: detection ignores excluded subscriptions"
function global:Wait-ForIngestCompletion { param($Token, $MaxWaitMinutes, $PollSeconds) [PSCustomObject]@{ Complete = $true; Reported = $true; Reason = 'stub' } }
function global:Resolve-ResourceDisplayNames { param($ResourceIds, $MgmtToken) @{} }
function global:Get-ResourceContext { param($ResourceId, $MgmtToken) $null }
function Initialize-SnapshotsTwoSubs {
    Reset-State
    $env:AI_API_KEY = ''
    Set-Setting @{ EvidenceMaxFindings = 0 }
    $windowEnd = [datetime]::UtcNow.Date.AddDays(-2)
    for ($d = $windowEnd.AddDays(-40); $d -le $windowEnd; $d = $d.AddDays(1)) {
        $inCurrent = $d -gt $windowEnd.AddDays(-7)
        foreach ($r in @(
            @{ id = $vmB; scope = $subB; cost = $(if ($inCurrent) { 400.0 } else { 120.0 }) }
            @{ id = $stA; scope = $subA; cost = 50.0 }
        )) {
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $r.id)
                Date = $d.ToString('yyyy-MM-dd'); DimensionKey = $r.id; Scope = $r.scope; ResourceId = $r.id; Meter = 'Virtual Machines'; CostUsd = $r.cost }
        }
    }
}
$detect = Join-Path $fa 'DetectCostSpikes-Timer/run.ps1'
Test-That 'with every subscription in scope the sandbox VM is a weekly finding' {
    Initialize-SnapshotsTwoSubs
    & $detect -Timer $null *> $null
    $rows = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })
    Assert-True (@($rows | Where-Object { $_.Scope -eq $subB }).Count -ge 1) 'finding for the sandbox subscription'
}
Test-That 'excluded: no finding for it and no false drop' {
    Initialize-SnapshotsTwoSubs
    Set-Scope @($subA)
    & $detect -Timer $null *> $null
    $rows = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })
    Assert-Equal 0 @($rows | Where-Object { $_.Scope -eq $subB -or [string]$_.ResourceId -like "*$subB*" }).Count 'nothing from the excluded subscription'
    Assert-Equal 0 $rows.Count 'the steady subscription has no change'
    Assert-Equal 41 @($global:Store['CostSnapshots'].Values | Where-Object { $_.Scope -eq $subB }).Count 'its snapshots are kept'
}

Write-Host "`nNightly: forecast, budgets and the brief"
Test-That 'a management-group forecast carries the subscription filter' {
    Reset-State
    Set-Scope @($subA)
    $global:CostResponder = { param($b, $u) New-CostResponse -Columns @('CostUSD', 'UsageDate', 'CostStatus', 'Currency') -Rows @(, @(10.0, 20260901, 'Actual', 'USD')) }
    $null = Get-CostForecast -Scope '/providers/Microsoft.Management/managementGroups/mg' -MgmtToken 't' -From ([datetime]'2026-09-01') -To ([datetime]'2026-09-30') -SubscriptionIds @($subA)
    $f = $global:CostQueryBodies[0].dataset.filter.dimensions
    Assert-Equal 'SubscriptionId' $f.name 'dimension'
    Assert-Equal $subA (@($f.values) -join ',') 'values'
    $global:CostQueryBodies.Clear()
    $null = Get-CostForecast -Scope "/subscriptions/$subA" -MgmtToken 't' -From ([datetime]'2026-09-01') -To ([datetime]'2026-09-30')
    Assert-True ($null -eq $global:CostQueryBodies[0].dataset.filter) 'no filter without a scope'
}
Test-That 'a brief built for another scope is due' {
    $stored = [PSCustomObject]@{ GeneratedAt = [datetime]::UtcNow.ToString('o'); Subject = (Get-BriefTargetMonth).ToString('yyyy-MM') }
    Assert-True (-not (Test-BriefDue -Grain 'month' -Stored $stored -ScopeHash 'all')) 'legacy brief, ALL scope: current'
    Assert-True (Test-BriefDue -Grain 'month' -Stored $stored -ScopeHash 'abc123') 'scope changed: due'
}
Test-That 'brief savings leave out excluded subscriptions' {
    Initialize-ReadStore
    Set-Scope @($subA)
    $s = Get-BriefSavings -Token 't'
    Assert-Equal 0 @($s.items | Where-Object { [string]$_.resourceId -like "*$subB*" }).Count 'nothing from the excluded subscription'
    # Both included items are the same storage account; the brief keeps the lower figure.
    Assert-Equal 10.0 $s.totalMonthlyUsd 'the excluded 300/month is not in the total'
}

Write-Host "`nAsk"
Test-That 'queries get the scope filter on top of the question''s own three' {
    Reset-State
    $global:CostResponder = { param($b, $u) New-CostResponse -Columns @('Cost', 'Currency') -Rows @(, @(1.0, 'EUR')) }
    $spec = [PSCustomObject]@{ timeframe = 'MonthToDate'; filters = @(
        @{ dimension = 'ServiceName'; values = @('a') }, @{ dimension = 'ResourceLocation'; values = @('b') }, @{ dimension = 'ChargeType'; values = @('c') }) }
    $null = Invoke-CostQuery -Spec $spec -MgmtToken 't' -Scope '/providers/Microsoft.Management/managementGroups/mg' -Interactive -SubscriptionIds @($subA)
    $and = @($global:CostQueryBodies[0].dataset.filter.and)
    Assert-Equal 4 $and.Count 'three from the question + the scope'
    Assert-Equal 'SubscriptionId' $and[3].dimensions.name 'scope filter last'
    $global:CostQueryBodies.Clear()
    $null = Invoke-CostQuery -Spec ([PSCustomObject]@{ timeframe = 'MonthToDate' }) -MgmtToken 't' -Scope '/providers/Microsoft.Management/managementGroups/mg' -Interactive -SubscriptionIds @($subA)
    Assert-Equal 'SubscriptionId' $global:CostQueryBodies[0].dataset.filter.dimensions.name 'alone it is the only filter'
}
Test-That 'Ask about an excluded subscription is refused before any AI call' {
    Reset-State
    Set-Scope @($subA)
    $env:COST_QUERY_SCOPE = '/providers/Microsoft.Management/managementGroups/mg'
    try {
        $r = Invoke-HttpFunction -Name 'QueryCosts' -Body ([PSCustomObject]@{ question = 'why did this go up?'; context = [PSCustomObject]@{ kind = 'subscription'; subscriptionId = $subB } })
        Assert-Equal 400 ([int]$r.StatusCode) 'status'
        Assert-Equal 0 $global:WebCalls.Count 'no AI call'
    } finally { $env:COST_QUERY_SCOPE = '' }
}

Write-Host ""
Write-Host "Scope tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
