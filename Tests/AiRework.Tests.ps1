# Offline tests for the evidence-based AI layer: evidence first, explanation second.
# No Azure, no AI provider: table storage, Cost Management, Activity Log, Resource Graph and the
# provider's HTTP endpoint are all stubbed. Run via Tests/Invoke-OfflineTests.ps1.
#
# The stubs live in TestKit.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

Write-Host "`nVolume / rate split"
Test-That 'pure rate change (same quantity, double price)' {
    $r = Measure-VolumeRateEffect -CurrentCost 200 -BaselineCost 100 -CurrentQuantity 100 -BaselineQuantity 100
    Assert-Equal 0.0 $r.VolumeUsd 'volume'; Assert-Equal 100.0 $r.RateUsd 'rate'; Assert-Equal 100.0 $r.UnitPriceChangePct 'price %'
}
Test-That 'pure volume change (same price, triple quantity)' {
    $r = Measure-VolumeRateEffect -CurrentCost 300 -BaselineCost 100 -CurrentQuantity 150 -BaselineQuantity 50
    Assert-Equal 200.0 $r.VolumeUsd 'volume'; Assert-Equal 0.0 $r.RateUsd 'rate'; Assert-Equal 200.0 $r.QuantityChangePct 'qty %'
}
Test-That 'mixed change: effects add up to the cost change exactly' {
    $r = Measure-VolumeRateEffect -CurrentCost 537.25 -BaselineCost 212.4 -CurrentQuantity 731 -BaselineQuantity 480
    Assert-Equal (537.25 - 212.4) ($r.VolumeUsd + $r.RateUsd) 'volume + rate'
}
Test-That 'no split when a window has no quantity' {
    Assert-True ($null -eq (Measure-VolumeRateEffect -CurrentCost 10 -BaselineCost 0 -CurrentQuantity 5 -BaselineQuantity 0)) 'null for a new meter'
}

Write-Host "`nWindow totals and drivers"
$curStart = $today.AddDays(-8); $curEnd = $today.AddDays(-2)
$ranges = @(1..4 | ForEach-Object { $e = $curEnd.AddDays(-7 * $_); @{ Start = $e.AddDays(-6); End = $e } })
function New-DailyRows { param([string]$Key, [double]$BaselinePerDay, [double]$CurrentPerDay)
    $out = @()
    for ($d = $ranges[-1].Start; $d -le $curEnd; $d = $d.AddDays(1)) {
        $v = if ($d -ge $curStart) { $CurrentPerDay } else { $BaselinePerDay }
        $out += [PSCustomObject]@{ Key = $Key; Date = $d; Value = $v }
    }
    return $out
}
Test-That 'baseline is the average per baseline window; out-of-range rows ignored' {
    $rows = @(New-DailyRows 'Compute Hours' 10 30) + @([PSCustomObject]@{ Key = 'Compute Hours'; Date = $today.AddDays(-100); Value = 9999 })
    $t = Measure-WindowTotals -Rows $rows -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges
    Assert-Equal 210.0 $t['compute hours'].Current 'current'; Assert-Equal 70.0 $t['compute hours'].Baseline 'baseline per window'
}
Test-That 'drivers: shares of the gross rise, volume + rate + unsplit = net' {
    $cost = Measure-WindowTotals -Rows (@(New-DailyRows 'Compute Hours' 10 30) + @(New-DailyRows 'Premium SSD' 5 5) + @(New-DailyRows 'Egress' 0 3) + @(New-DailyRows 'Snapshots' 2 1)) `
        -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges
    $qty = Measure-WindowTotals -Rows (@(New-DailyRows 'Compute Hours' 24 24) + @(New-DailyRows 'Premium SSD' 1 1) + @(New-DailyRows 'Egress' 0 50) + @(New-DailyRows 'Snapshots' 10 5)) `
        -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges
    $d = Get-ChangeDrivers -Cost $cost -Quantity $qty
    Assert-Equal 'Compute Hours' $d.Increases[0].Key 'top driver'
    Assert-Equal 140.0 $d.Increases[0].DeltaUsd 'top delta'
    Assert-Equal 0.0 $d.Increases[0].QuantityChangePct 'compute quantity unchanged'
    Assert-Equal 200.0 $d.Increases[0].UnitPriceChangePct 'compute unit price tripled'
    Assert-True ($d.Increases[1].IsNew -and $d.Increases[1].Key -eq 'Egress') 'egress is new'
    Assert-Equal 'Snapshots' $d.Decreases[0].Key 'decrease listed'
    Assert-Equal ([double]$d.NetDeltaUsd) ([double]$d.VolumeUsd + [double]$d.RateUsd + [double]$d.UnsplitUsd) 'split sums to net'
    Assert-Equal 21.0 $d.UnsplitUsd 'unsplit = the new egress meter'
    Assert-Equal 100.0 ([double](@($d.Increases | Measure-Object SharePct -Sum).Sum)) 'shares of listed increases'
}

Write-Host "`nEvidence gathering (stubbed Azure)"
$global:CostResponder = {
    param($b, $uri)
    $groupBy = [string]$b.dataset.grouping[0].name
    $agg = [string]$b.dataset.aggregation.total.name
    $cols = @('UsageDate', $groupBy, $agg, 'Currency')
    $rows = @()
    $daily = @{
        Meter = @{ CostUSD = @{ 'D4s v5' = @(10, 0); 'D8s v5' = @(0, 20); 'P10 Disk' = @(2, 2) }; UsageQuantity = @{ 'D4s v5' = @(24, 0); 'D8s v5' = @(0, 24); 'P10 Disk' = @(1, 1) } }
    }
    foreach ($name in $daily[$groupBy][$agg].Keys) {
        $pair = $daily[$groupBy][$agg][$name]
        for ($d = $ranges[-1].Start; $d -le $curEnd; $d = $d.AddDays(1)) {
            $v = if ($d -ge $curStart) { $pair[1] } else { $pair[0] }
            if ($v -ne 0) { $rows += , @([int]$d.ToString('yyyyMMdd'), $name, $v, 'USD') }
        }
    }
    New-CostResponse -Columns $cols -Rows $rows
}
$global:RestResponder = {
    param($method, $uri, $body)
    if ($uri -like '*eventtypes/management/values*') {
        $t = $curStart.AddDays(1).AddHours(9).ToString('o')
        return [PSCustomObject]@{ nextLink = $null; value = @(
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Compute/virtualMachines/write' }; status = @{ value = 'Succeeded' }; caller = 'jane@contoso.com'; resourceId = $vm }
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Compute/virtualMachines/write' }; status = @{ value = 'Succeeded' }; caller = 'jane@contoso.com'; resourceId = $vm }
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Compute/virtualMachines/write' }; status = @{ value = 'Started' }; caller = 'jane@contoso.com'; resourceId = $vm }
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Compute/virtualMachines/read' }; status = @{ value = 'Succeeded' }; caller = 'x'; resourceId = $vm }
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Authorization/roleAssignments/write' }; status = @{ value = 'Succeeded' }; caller = 'x'; resourceId = $vm }
            [PSCustomObject]@{ eventTimestamp = $t; operationName = @{ value = 'Microsoft.Compute/virtualMachines/start/action' }; status = @{ value = 'Succeeded' }; caller = 'ops@contoso.com'; resourceId = $vm }
        ) }
    }
    if ($uri -like '*Microsoft.ResourceGraph*') {
        return [PSCustomObject]@{ data = @(
            [PSCustomObject]@{ ts = $curStart.AddDays(1).AddHours(9).ToString('o'); changeType = 'Update'; changes = [PSCustomObject]@{
                'properties.hardwareProfile.vmSize' = [PSCustomObject]@{ previousValue = 'Standard_D4s_v5'; newValue = 'Standard_D8s_v5' }
                'properties.provisioningState'      = [PSCustomObject]@{ previousValue = 'Updating'; newValue = 'Succeeded' }
                'tags.env'                          = [PSCustomObject]@{ previousValue = 'dev'; newValue = 'prod' } } }
        ) }
    }
    throw "unexpected REST call $uri"
}
$finding = [PSCustomObject]@{ Id = 'abcdef0123456789'; Dimension = 'resource'; Scope = $sub; ResourceId = $vm; Meter = 'Virtual Machines'; PeriodType = 'week'
    ResourceName = 'vm-app01'; ScopeName = 'Production'; BaselineUsd = 84; SpikeUsd = 154; DeltaUsd = 70; DeltaPct = 83.3; IsNew = $false }
$ctx = [PSCustomObject]@{ name = 'vm-app01'; type = 'microsoft.compute/virtualmachines'; sku = $null; location = 'westeurope'; tags = [PSCustomObject]@{ Owner = 'team-payments'; CostCenter = '4711'; Irrelevant = 'x' } }

Reset-State
$ev = Get-CostChangeEvidence -Finding $finding -MgmtToken 't' -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges -Granularity Daily -ResourceContext $ctx -Deadline ([datetime]::UtcNow.AddMinutes(1))
Test-That 'resource evidence: two single-aggregation cost queries, filtered to the resource' {
    Assert-Equal 2 $global:CostQueryBodies.Count 'query count'
    Assert-Equal 'ResourceId' $global:CostQueryBodies[0].dataset.filter.dimensions.name 'filter dimension'
    Assert-Equal $vm $global:CostQueryBodies[0].dataset.filter.dimensions.values[0] 'filter value'
    Assert-Equal 1 @($global:CostQueryBodies[0].dataset.aggregation.PSObject.Properties).Count 'one aggregation per request'
}
Test-That 'resource evidence: drivers, SKU change, deduped activity, owner tags' {
    Assert-True $ev.complete 'complete'
    $drivers = @($ev.facts | Where-Object kind -eq 'driver')
    Assert-Equal 'D8s v5' $drivers[0].name 'top meter'
    Assert-True $drivers[0].isNew 'new meter'
    Assert-Equal 'D4s v5' @($drivers | Where-Object direction -eq 'decrease')[0].name 'stopped meter listed as decrease'
    $prop = @($ev.facts | Where-Object kind -eq 'property-change')
    Assert-Equal 1 $prop.Count 'only cost-relevant property kept'
    Assert-Equal 'Standard_D8s_v5' $prop[0].to 'new size'
    $chg = @($ev.facts | Where-Object kind -eq 'change')
    Assert-Equal 2 $chg.Count 'write (deduped) + start action; reads, role writes, non-succeeded dropped'
    Assert-Equal 2 @($chg | Where-Object action -eq 'created or updated')[0].count 'duplicate count'
    Assert-True (@($chg).actor -notcontains 'jane@contoso.com' -and $chg[0].actor -like 'user_*') 'actor pseudonymised'
    $owner = @($ev.facts | Where-Object kind -eq 'owner')[0]
    Assert-Equal 'team-payments' $owner.tags.Owner 'owner tag'
    Assert-True (-not $owner.tags.PSObject.Properties['Irrelevant']) 'unrelated tag dropped'
    Assert-Equal 'F1' $ev.facts[0].id 'ids start at F1'
    Assert-Equal ("F$(@($ev.facts).Count)") $ev.facts[-1].id 'ids are sequential'
}
Test-That 'evidence round-trips through JSON without changing (reuse is safe)' {
    $j1 = $ev | ConvertTo-Json -Depth 10 -Compress
    $back = $j1 | ConvertFrom-Json
    $p1 = Build-CostChangePayload -Finding $finding -ResourceContext $ctx -Evidence $ev | ConvertTo-Json -Depth 10
    $p2 = Build-CostChangePayload -Finding $finding -ResourceContext $ctx -Evidence $back | ConvertTo-Json -Depth 10
    Assert-Equal $p1 $p2 'payload after round-trip'
}
Test-That 'a throttled cost query becomes a note, not an exception' {
    Reset-State
    $saved = $global:CostResponder
    $global:CostResponder = { param($b, $u) throw 'COST_QUERY_THROTTLED: still throttled' }
    try {
        $e2 = Get-CostChangeEvidence -Finding $finding -MgmtToken 't' -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges -ResourceContext $ctx -Deadline ([datetime]::UtcNow.AddMinutes(1))
    } finally { $global:CostResponder = $saved }
    Assert-True (-not $e2.complete) 'incomplete'
    Assert-True (@($e2.notes) -match 'rate-limiting') 'throttle note'
    Assert-True (@($e2.facts | Where-Object kind -eq 'property-change').Count -eq 1) 'other steps still ran'
}
Test-That 'an expired deadline skips the queries' {
    Reset-State
    $e3 = Get-CostChangeEvidence -Finding $finding -MgmtToken 't' -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges -Deadline ([datetime]::UtcNow.AddSeconds(-1))
    Assert-Equal 0 $global:CostQueryBodies.Count 'no queries'
    Assert-True (@($e3.notes) -match 'time budget') 'time note'
}
Test-That 'meter rollup: meters first, resources second, filtered to the meter category, new resources listed' {
    Reset-State
    $saved = $global:CostResponder
    $global:CostResponder = {
        param($b, $u)
        $groupBy = [string]$b.dataset.grouping[0].name
        $rows = @()
        for ($d = $ranges[-1].Start; $d -le $curEnd; $d = $d.AddDays(1)) {
            $cur = $d -ge $curStart
            $day = [int]$d.ToString('yyyyMMdd')
            if ($groupBy -eq 'Meter') {
                $rows += , @($day, 'P1v3', $(if ($cur) { 8 } else { 5 }), 'USD')
                if ($cur) { $rows += , @($day, 'P2v3', 6, 'USD') }
            } else {
                $rows += , @($day, "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.web/sites/app1", $(if ($cur) { 8 } else { 5 }), 'USD')
                if ($cur) { $rows += , @($day, "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.web/sites/app2", 6, 'USD') }
            }
        }
        New-CostResponse -Columns @('UsageDate', $groupBy, 'CostUSD', 'Currency') -Rows $rows
    }
    try {
        $mf = [PSCustomObject]@{ Id = '0123456789abcdef'; Dimension = 'meter'; Scope = $sub; ResourceId = ''; Meter = 'Azure App Service'; PeriodType = 'week' }
        $e4 = Get-CostChangeEvidence -Finding $mf -MgmtToken 't' -CurrentStart $curStart -CurrentEnd $curEnd -BaselineRanges $ranges -Deadline ([datetime]::UtcNow.AddMinutes(1))
    } finally { $global:CostResponder = $saved }
    Assert-Equal 2 $global:CostQueryBodies.Count 'meter + resource query'
    Assert-Equal 'Meter' $global:CostQueryBodies[0].dataset.grouping[0].name 'meters first'
    Assert-Equal 'MeterCategory' $global:CostQueryBodies[0].dataset.filter.dimensions.name 'meter filter'
    Assert-Equal 'MeterCategory' $global:CostQueryBodies[1].dataset.filter.dimensions.name 'meter filter on resources'
    $d1 = @($e4.facts | Where-Object kind -eq 'driver')[0]
    Assert-Equal 'meter' $d1.driverKind 'top driver is a meter'
    Assert-Equal 'P2v3' $d1.name 'new meter leads'
    Assert-True (@($e4.facts | Where-Object kind -eq 'new-resource').resourceId -like '*app2') 'new resource'
    $sp = @($e4.facts | Where-Object kind -eq 'spread')[0]
    Assert-Equal 2 $sp.resourceCount 'spread over two resources'
    Set-EvidenceResourceNames -Evidence $e4 -NameMap @{ "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.web/sites/app2" = 'Checkout API' }
    Assert-Equal 'Checkout API' @($e4.facts | Where-Object kind -eq 'new-resource')[0].name 'display name stamped'
}
Test-That 'meter rollup: a rise spread thinly lists no noise resources, only the spread' {
    $res = @{}
    for ($i = 0; $i -lt 50; $i++) { $res["/subscriptions/$sub/rg/vm$i"] = [PSCustomObject]@{ Key = "/subscriptions/$sub/rg/vm$i"; Current = 12.0; Baseline = 10.0 } }
    $res['/subscriptions/x/rg/plan'] = [PSCustomObject]@{ Key = '/subscriptions/x/rg/plan'; Current = 3.0; Baseline = 1.5 }
    $rd = Get-ChangeDrivers -Cost $res -TopIncreases 8 -TopDecreases 0
    $facts = @(New-EvidenceFacts -DriverKind 'meter' -Drivers $null -ResourceDrivers $rd -ResourceMinSharePct 10)
    Assert-Equal 0 @($facts | Where-Object kind -eq 'driver').Count 'no resource under 10% listed'
    $sp = @($facts | Where-Object kind -eq 'spread')[0]
    Assert-Equal 51 $sp.resourceCount 'all rising resources counted'
    Assert-True ($sp.topSharePct -lt 3) 'largest share is small'
}

Write-Host "`nExplanation + AI budget"
$global:AiResponder = { param($req) New-ChatResponse @{ headline = 'VM resized to a larger size'; cause = 'The VM was resized from D4s v5 to D8s v5 (F4), and the D8s v5 meter replaced the D4s v5 meter (F1, F2).'; citedFacts = @('F1', 'f2', 'F99', 'F4'); explained = $true; recommendation = 'Ask team-payments whether the larger size is still needed.' } }
Test-That 'no evidence -> no AI call' {
    Reset-State
    $x = Invoke-CostChangeExplanation -Finding $finding -Evidence $null
    Assert-Equal 'no-evidence' $x.Status 'status'; Assert-Equal 0 $global:WebCalls.Count 'calls'
}
Test-That 'explained: citations validated, usage counted, tokens recorded' {
    Reset-State
    $x = Invoke-CostChangeExplanation -Finding $finding -ResourceContext $ctx -Evidence $ev
    Assert-Equal 'explained' $x.Status 'status'
    Assert-Equal 'F1,F2,F4' (@($x.CitedFacts) -join ',') 'citations (unknown dropped, case normalised)'
    Assert-True $x.Explained 'explained'
    Assert-True $x.Grounded 'grounded'
    $usage = Get-AiUsageToday -StorageToken 't'
    Assert-Equal 1 $usage.Calls 'calls counted'; Assert-Equal 120 $usage.InputTokens 'input tokens'; Assert-Equal 40 $usage.OutputTokens 'output tokens'
    $sent = $global:WebCalls[0].Body | ConvertFrom-Json
    Assert-True ($sent.messages[1].content -like '*"facts"*') 'evidence sent to the model'
    Assert-True ($sent.messages[1].content -notlike '*jane@contoso.com*') 'no raw identities sent'
}
Test-That 'unchanged request reuses the stored explanation without a call' {
    Reset-State
    $x = Invoke-CostChangeExplanation -Finding $finding -ResourceContext $ctx -Evidence $ev
    $stored = [PSCustomObject]@{ NarrationKey = $x.NarrationKey; Headline = $x.Headline; Cause = $x.Cause; Recommendation = $x.Recommendation
                                 CitedFactsJson = (@($x.CitedFacts) | ConvertTo-Json -Compress -AsArray); Explained = $true; Grounded = $true }
    $global:WebCalls.Clear()
    $y = Invoke-CostChangeExplanation -Finding $finding -ResourceContext $ctx -Evidence ($ev | ConvertTo-Json -Depth 10 | ConvertFrom-Json) -StoredRow $stored
    Assert-Equal 'reused' $y.Status 'status'; Assert-Equal 0 $global:WebCalls.Count 'calls'
    Assert-Equal 'F1,F2,F4' (@($y.CitedFacts) -join ',') 'citations restored'
    $z = Invoke-CostChangeExplanation -Finding $finding -ResourceContext $ctx -Evidence $ev -StoredRow $stored -Force
    Assert-Equal 'explained' $z.Status '-Force calls again'
}
Test-That 'daily limit reached -> budget-exceeded, provider not called' {
    Reset-State
    Set-Setting @{ AiDailyCallLimit = 2 }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'aiusage'; RowKey = $today.ToString('yyyy-MM-dd'); Calls = 2 }
    $x = Invoke-CostChangeExplanation -Finding $finding -Evidence $ev
    Assert-Equal 'budget-exceeded' $x.Status 'status'; Assert-Equal 0 $global:WebCalls.Count 'calls'
    Assert-True ($x.Error -like 'AI_BUDGET_EXCEEDED*2 AI calls*') 'message names the limit'
}
Test-That 'limit 0 switches AI off; -ReuseOnly never calls' {
    Reset-State
    Set-Setting @{ AiDailyCallLimit = 0 }
    try { Invoke-AiCompletion -System 's' -User 'u' | Out-Null; throw 'expected refusal' }
    catch { Assert-True (Test-AiBudgetExceeded -ErrorRecord $_) 'budget error' }
    Reset-State
    $x = Invoke-CostChangeExplanation -Finding $finding -Evidence $ev -ReuseOnly
    Assert-Equal 'skipped' $x.Status 'reuse-only status'; Assert-Equal 0 $global:WebCalls.Count 'calls'
}
Test-That 'counter storage outage fails open (call proceeds)' {
    Reset-State
    $global:FailTableWrites = $true
    $x = Invoke-CostChangeExplanation -Finding $finding -Evidence $ev
    Assert-Equal 'explained' $x.Status 'status'
}
Test-That '"explained" without valid citations is downgraded; invented figures flagged' {
    Reset-State
    $saved = $global:AiResponder
    $global:AiResponder = { param($req) New-ChatResponse @{ headline = 'Costs rose by 4,975'; cause = 'Probably more traffic.'; citedFacts = @('F42'); explained = $true; recommendation = 'Check it.' } }
    try { $x = Invoke-CostChangeExplanation -Finding $finding -Evidence $ev } finally { $global:AiResponder = $saved }
    Assert-True (-not $x.Explained) 'not explained'
    Assert-True (-not $x.Grounded) 'ungrounded figure flagged'
}
Test-That 'prompt forbids amounts and guessing; schema lists every property as required' {
    $p = Get-CostChangeExplanationSystemPrompt
    Assert-True ($p -match 'Never write currency amounts') 'no amounts'
    Assert-True ($p -match 'do not guess') 'no guessing'
    $s = Get-CostChangeExplanationSchema
    Assert-Equal (@($s.properties.Keys | Sort-Object) -join ',') (@($s.required | Sort-Object) -join ',') 'required == properties'
    $b = Get-InsightSchema
    Assert-Equal (@($b.properties.Keys | Sort-Object) -join ',') (@($b.required | Sort-Object) -join ',') 'findings required == properties'
    $item = $b.properties.findings.items
    Assert-Equal (@($item.properties.Keys | Sort-Object) -join ',') (@($item.required | Sort-Object) -join ',') 'finding required == properties'
}

Write-Host "`nExecutive brief"
function New-DayMap { param([datetime]$From, [datetime]$To, [double]$Usd, [switch]$NoBilling)
    $m = @{}
    for ($d = $From; $d -le $To; $d = $d.AddDays(1)) {
        $row = @{ PartitionKey = 'dailytotal'; RowKey = $d.ToString('yyyy-MM-dd'); TotalUsd = $Usd }
        if (-not $NoBilling) { $row.TotalBilling = $Usd * 7; $row.Currency = 'EUR' }
        $m[$d.ToString('yyyy-MM-dd')] = [PSCustomObject]$row
    }
    return $m
}
$fixedToday = [datetime]::new(2026, 3, 12, 0, 0, 0, [DateTimeKind]::Utc)
Test-That 'weekly spend: month-to-date vs same days last month, run-rate, billing currency' {
    $days = New-DayMap ([datetime]'2026-02-01') ([datetime]'2026-02-28') 100
    foreach ($kv in (New-DayMap ([datetime]'2026-03-01') ([datetime]'2026-03-10') 120).GetEnumerator()) { $days[$kv.Key] = $kv.Value }
    $s = Build-BriefSpend -Days $days -Grain week -Today $fixedToday
    Assert-Equal '2026-03' $s.month 'month'; Assert-Equal '2026-03-10' $s.throughDate 'settled D-2'
    Assert-Equal 1200.0 $s.current.usd 'mtd'; Assert-Equal 8400.0 $s.current.billing 'mtd billing'
    Assert-Equal 1000.0 $s.previousSamePeriod.usd 'same days last month'
    Assert-Equal 20.0 $s.changeVsPreviousPct 'change %'
    Assert-Equal 3720.0 $s.runRateUsd 'run-rate (120 x 31)'
    Assert-Equal 2800.0 $s.previousMonth.usd 'last month total'
}
Test-That 'missing day: marked incomplete, no run-rate, no billing sum' {
    $days = New-DayMap ([datetime]'2026-03-01') ([datetime]'2026-03-10') 120
    $days.Remove('2026-03-05')
    $s = Build-BriefSpend -Days $days -Grain week -Today $fixedToday
    Assert-True (-not $s.current.complete) 'incomplete'
    Assert-True ($null -eq $s.runRateUsd) 'no run-rate'
    Assert-True ($null -eq $s.current.billing) 'no partial billing sum'
}
Test-That 'monthly brief targets the last settled month (from the 2nd)' {
    Assert-Equal '2026-02' (Get-BriefTargetMonth -Today ([datetime]'2026-03-02')).ToString('yyyy-MM') 'on the 2nd'
    Assert-Equal '2026-01' (Get-BriefTargetMonth -Today ([datetime]'2026-03-01')).ToString('yyyy-MM') 'on the 1st'
    $days = New-DayMap ([datetime]'2026-01-01') ([datetime]'2026-02-28') 50
    $s = Build-BriefSpend -Days $days -Grain month -Today ([datetime]'2026-03-02')
    Assert-Equal 1400.0 $s.current.usd 'Feb total'; Assert-Equal 1550.0 $s.previousMonth.usd 'Jan total'
    Assert-Equal -9.7 $s.changeVsPreviousPct 'change %'
}
Test-That 'brief due rules' {
    $mon = [datetime]'2026-03-16'   # a Monday
    Assert-True (Test-BriefDue -Grain week -Stored $null -Today $mon) 'missing'
    Assert-True (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-15T03:15:00Z' }) -Today $mon) 'Monday'
    Assert-True (-not (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-16T03:15:00Z' }) -Today $mon)) 'already today'
    Assert-True (-not (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-16T03:15:00Z' }) -Today ([datetime]'2026-03-18'))) 'mid-week'
    Assert-True (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-02T03:15:00Z' }) -Today ([datetime]'2026-03-11')) 'older than a week'
    Assert-True (Test-BriefDue -Grain month -Stored ([PSCustomObject]@{ Subject = '2026-01'; GeneratedAt = '2026-02-02T03:15:00Z' }) -Today ([datetime]'2026-03-02')) 'new month settled'
    Assert-True (-not (Test-BriefDue -Grain month -Stored ([PSCustomObject]@{ Subject = '2026-02'; GeneratedAt = '2026-03-02T03:15:00Z' }) -Today ([datetime]'2026-03-20'))) 'same month'
    Assert-True (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-16T03:15:00Z'; BriefJson = '{"payload":{"version":2}}' }) -Today ([datetime]'2026-03-18')) 'built by an older version'
    Assert-True (-not (Test-BriefDue -Grain week -Stored ([PSCustomObject]@{ GeneratedAt = '2026-03-16T03:15:00Z'; BriefJson = '{"payload":{"version":3}}' }) -Today ([datetime]'2026-03-18'))) 'current version'
}

function Initialize-BriefStore {
    Reset-State
    $days = New-DayMap ([datetime]::UtcNow.Date.AddDays(-75)) ([datetime]::UtcNow.Date.AddDays(-1)) 100
    foreach ($r in $days.Values) { Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $r.RowKey; TotalUsd = $r.TotalUsd; TotalBilling = $r.TotalBilling; Currency = $r.Currency } }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'latestperiod'; RowKey = 'week'; Period = '2026-03-10'; PeriodStart = '2026-03-04'; PeriodEnd = '2026-03-10' }
    Set-TableEntity -Table 'CostSpikes' -Entity @{ PartitionKey = 'week|2026-03-10'; RowKey = 'abcdef0123456789'; Dimension = 'resource'; ResourceId = $vm; ResourceName = 'vm-app01'
        Scope = $sub; ScopeName = 'Production'; SpikeUsd = 154.0; BaselineUsd = 84.0; DeltaUsd = 70.0; DeltaPct = 83.3; IsNew = $false
        Explained = $true; Cause = 'Resized to D8s v5.'; EvidenceJson = ($ev | ConvertTo-Json -Depth 10 -Compress) }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = 'run2' }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 's1'; RunId = 'run2'; Category = 'orphaned'; Tier = 'certain'; Title = 'Unattached managed disk'; ResourceId = "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.compute/disks/d1"; EstMonthlySavingsUsd = 40.0 }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 's2'; RunId = 'run2'; Category = 'step-up'; Title = 'Sustained cost increase'; ResourceId = $vm; EstMonthlySavingsUsd = 900.0 }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 's3'; RunId = 'run2'; Category = 'low-utilization'; Tier = 'likely'; Title = 'VM averaging 3% CPU'; ResourceId = $vm; EstMonthlySavingsUsd = 120.0 }
    Set-TableEntity -Table 'SavingsFindings' -Entity @{ PartitionKey = 'savings'; RowKey = 's0'; RunId = 'run1'; Category = 'orphaned'; Title = 'old run'; ResourceId = 'x'; EstMonthlySavingsUsd = 999.0 }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'advisor-meta'; RowKey = 'latest'; LatestRunId = 'adv1' }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'a1'; RunId = 'adv1'; Solution = 'Right-size or shutdown underutilized virtual machines'; ResourceId = $vm; EstMonthlySavingsUsd = 300.0; SavingsConverted = $true; Impact = 'High' }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'a2'; RunId = 'adv1'; Solution = 'Buy a savings plan'; ResourceId = $sub; EstMonthlySavingsUsd = 500.0; SavingsConverted = $true; Impact = 'High' }
    Set-TableEntity -Table 'Recommendations' -Entity @{ PartitionKey = 'cost'; RowKey = 'a3'; RunId = 'adv1'; Solution = 'Unconvertible'; ResourceId = $sub; EstMonthlySavingsUsd = 0.0; SavingsConverted = $false }
}
Test-That 'savings: step-ups and stale runs excluded, one entry per resource (lowest), unconverted counted' {
    Initialize-BriefStore
    $s = Get-BriefSavings -Token 't'
    Assert-Equal 'A-a2,S-s3,S-s1' (@($s.items).id -join ',') 'items (sorted by amount)'
    Assert-Equal 660.0 $s.totalMonthlyUsd 'total (500 + 120 + 40)'
    Assert-Equal 1 $s.unconvertedCount 'unconverted'
}
Test-That 'brief without AI: stored with figures, changes carry facts and cause' {
    Initialize-BriefStore
    $env:AI_API_KEY = ''
    $doc = Update-PortfolioBrief -Grain week -Token 't'
    Assert-Equal 'not-configured' $doc.aiStatus 'status'
    Assert-Equal 'C-abcdef0123456789' $doc.payload.changes.items[0].id 'change id'
    Assert-Equal 'Resized to D8s v5.' $doc.payload.changes.items[0].cause 'cause carried'
    Assert-True (@($doc.payload.changes.items[0].facts).Count -gt 0) 'facts carried'
    $row = $global:Store['CostSummary']['brief|week']
    Assert-True ($row.BriefJson.Length -gt 100) 'stored'
    Assert-Equal 0 $global:WebCalls.Count 'no calls'
}
Test-That 'brief with AI: uncited findings dropped; reuse on unchanged payload; budget handled' {
    Initialize-BriefStore
    $saved = $global:AiResponder
    $global:AiResponder = { param($req) New-ChatResponse @{
        summary = 'Spend is running above last month, driven mainly by the resized vm-app01.'
        findings = @(
            @{ priority = 1; title = 'Buy a savings plan'; why = 'Advisor sizes it at 500 a month.'; owner = ''; monthlyCost = $null; estMonthlySavings = 500
               currency = 'USD'; action = 'Evaluate the savings plan.'; actionScript = ''; refs = @('A-a2') }
            @{ priority = 2; title = 'Invented'; why = 'x'; owner = ''; monthlyCost = $null; estMonthlySavings = $null
               currency = 'USD'; action = 'x'; actionScript = ''; refs = @('S-zzz') }) } }
    try {
        $doc = Update-PortfolioBrief -Grain week -Token 't'
        Assert-Equal 'explained' $doc.aiStatus 'status'
        Assert-Equal 1 @($doc.ai.findings).Count 'uncited finding dropped'
        Assert-Equal 'A-a2' $doc.ai.findings[0].refs[0] 'cited finding kept'
        Assert-True (-not $doc.grounded) 'a dropped finding is flagged'
        Assert-True (@($doc.ruleFindings).Count -gt 0) 'rule findings stored alongside'
        $calls = $global:WebCalls.Count
        $again = Update-PortfolioBrief -Grain week -Token 't'
        Assert-Equal 'reused' $again.aiStatus 'reused'
        Assert-Equal $calls $global:WebCalls.Count 'no extra call'
        Set-Setting @{ AiDailyCallLimit = 1 }
        & (Get-Module AiAdapter) { $script:AiLimitCache = @{ Value = $null; At = [datetime]::MinValue } }
        $forced = Update-PortfolioBrief -Grain week -Token 't' -Force
        Assert-Equal 'budget-exceeded' $forced.aiStatus 'budget'
        Assert-True ($global:Store['CostSummary']['brief|week'].AiError -like 'AI_BUDGET_EXCEEDED*') 'error stored'
    } finally { $global:AiResponder = $saved }
}

Write-Host "`nAsk: filters and comparison"
Test-That 'multi-filter spec builds an AND filter; window override forces Custom' {
    Reset-State
    $saved = $global:CostResponder
    $global:CostResponder = { param($b, $u) New-CostResponse -Columns @('Cost', 'ServiceName', 'Currency') -Rows @(, @(10.5, 'Storage', 'EUR')) }
    try {
        $spec = [PSCustomObject]@{ timeframe = 'MonthToDate'; granularity = 'Daily'; groupBy = @('ServiceName', 'Bogus')
            filters = @([PSCustomObject]@{ dimension = 'ResourceLocation'; values = @('westeurope') }, [PSCustomObject]@{ dimension = 'NotAllowed'; values = @('x') }, [PSCustomObject]@{ dimension = 'ResourceGroupName'; values = @('rg-a', 'rg-b') }) }
        $q = Invoke-CostQuery -Spec $spec -MgmtToken 't' -Scope "/subscriptions/$sub" -WindowFrom '2026-02-01' -WindowTo '2026-02-10' -Granularity None
    } finally { $global:CostResponder = $saved }
    $b = $global:CostQueryBodies[0]
    Assert-Equal 'Custom' $b.timeframe 'timeframe'
    Assert-Equal '2026-02-01' $b.timePeriod.from 'from'
    Assert-Equal 'None' $b.dataset.granularity 'granularity override'
    Assert-Equal 2 @($b.dataset.filter.and).Count 'two allowed filters ANDed'
    Assert-Equal 1 @($b.dataset.grouping).Count 'disallowed groupBy dropped'
    Assert-Equal 10.5 $q.rows[0].Cost 'row parsed'
}
Test-That 'previous windows: month-to-date clamps to the shorter month; custom shifts by its length' {
    $w = Resolve-QueryWindow -Spec ([PSCustomObject]@{ timeframe = 'MonthToDate' }) -Today ([datetime]'2026-03-31')
    $p = Get-PreviousQueryWindow -Window $w
    Assert-Equal '2026-02-01..2026-02-28' "$($p.From.ToString('yyyy-MM-dd'))..$($p.To.ToString('yyyy-MM-dd'))" 'MTD previous'
    $w2 = Resolve-QueryWindow -Spec ([PSCustomObject]@{ timeframe = 'TheLastMonth' }) -Today ([datetime]'2026-03-15')
    $p2 = Get-PreviousQueryWindow -Window $w2
    Assert-Equal '2026-01-01..2026-01-31' "$($p2.From.ToString('yyyy-MM-dd'))..$($p2.To.ToString('yyyy-MM-dd'))" 'last month previous'
    $w3 = Resolve-QueryWindow -Spec ([PSCustomObject]@{ timeframe = 'Custom'; from = '2026-03-01'; to = '2026-03-10' }) -Today ([datetime]'2026-03-15')
    $p3 = Get-PreviousQueryWindow -Window $w3
    Assert-Equal '2026-02-19..2026-02-28' "$($p3.From.ToString('yyyy-MM-dd'))..$($p3.To.ToString('yyyy-MM-dd'))" 'custom previous'
    $w4 = Resolve-QueryWindow -Spec ([PSCustomObject]@{ timeframe = 'BillingMonthToDate' }) -Today ([datetime]'2026-03-15')
    Assert-True $w4.Approximate 'billing month flagged approximate'
}
Test-That 'comparison rows merge on the grouping and include both-sided rows' {
    $cur = @([PSCustomObject]@{ ServiceName = 'Storage'; Cost = 150.0; Currency = 'EUR' }, [PSCustomObject]@{ ServiceName = 'Fabric'; Cost = 90.0; Currency = 'EUR' })
    $prev = @([PSCustomObject]@{ ServiceName = 'storage'; Cost = 100.0; Currency = 'EUR' }, [PSCustomObject]@{ ServiceName = 'Backup'; Cost = 20.0; Currency = 'EUR' })
    $rows = Merge-CostComparisonRows -CurrentRows $cur -PreviousRows $prev -GroupBy @('ServiceName')
    Assert-Equal 3 $rows.Count 'rows'
    Assert-Equal 50.0 $rows[0].Change 'storage change'; Assert-Equal 50.0 $rows[0].ChangePct 'storage %'
    Assert-True ($null -eq $rows[1].ChangePct) 'new service has no %'
    Assert-Equal -20.0 @($rows | Where-Object ServiceName -eq 'Backup')[0].Change 'gone service'
    $tot = Merge-CostComparisonRows -CurrentRows @([PSCustomObject]@{ Cost = 5.0; Currency = 'EUR' }) -PreviousRows @([PSCustomObject]@{ Cost = 4.0; Currency = 'EUR' }) -GroupBy @()
    Assert-Equal 1.0 $tot[0].Change 'ungrouped total'
}

Write-Host "`nAsk: subscriptions one by one (CSP / MCA — no management-group queries)"
$dataSub = 'aaaaaaaa-0000-0000-0000-000000000001'; $desktopSub = 'aaaaaaaa-0000-0000-0000-000000000002'
$askSubs = @([PSCustomObject]@{ Id = $dataSub; Name = 'Production - Data' }, [PSCustomObject]@{ Id = $desktopSub; Name = 'Production - Desktops' })
Test-That 'a question that names a subscription is asked of that subscription, filter removed' {
    $spec = [PSCustomObject]@{ timeframe = 'MonthToDate'; groupBy = @('ResourceId'); filters = @([PSCustomObject]@{ dimension = 'SubscriptionName'; values = @('Production - Data') }, [PSCustomObject]@{ dimension = 'ServiceName'; values = @('Fabric') }) }
    $sel = Select-SpecSubscriptions -Spec $spec -Subscriptions $askSubs
    Assert-True $sel.Named 'named'
    Assert-Equal $dataSub (@($sel.Subscriptions).Id -join ',') 'that subscription only'
    Assert-Equal 'ServiceName' (@($sel.Spec.filters).dimension -join ',') 'subscription filter removed, the rest kept'
    Assert-Equal 2 @($spec.filters).Count 'original spec untouched'
    Assert-Equal 2 @((Select-SpecSubscriptions -Spec ([PSCustomObject]@{ filters = @([PSCustomObject]@{ dimension = 'SubscriptionName'; values = @('production') }) }) -Subscriptions $askSubs).Subscriptions).Count 'a partial name matches by contains'
    Assert-Equal 0 @((Select-SpecSubscriptions -Spec ([PSCustomObject]@{ filters = @([PSCustomObject]@{ dimension = 'SubscriptionName'; values = @('nope') }) }) -Subscriptions $askSubs).Subscriptions).Count 'no match'
    Assert-True (-not (Select-SpecSubscriptions -Spec ([PSCustomObject]@{ filters = @() }) -Subscriptions $askSubs).Named) 'no subscription named'
}
Test-That 'rows from several subscriptions add up per group; a comparison is recomputed' {
    $rows = Merge-SubscriptionCostRows -Rows @(
        [PSCustomObject]@{ Cost = 10.0; ResourceGroupName = 'rg-a'; Currency = 'EUR' }
        [PSCustomObject]@{ Cost = 5.0; ResourceGroupName = 'RG-A'; Currency = 'EUR' }
        [PSCustomObject]@{ Cost = 7.0; ResourceGroupName = 'rg-b'; Currency = 'EUR' })
    Assert-Equal 2 $rows.Count 'two groups'
    Assert-Equal 15.0 $rows[0].Cost 'rg-a summed across subscriptions'
    $cmp = Merge-SubscriptionCostRows -Rows @(
        [PSCustomObject]@{ ServiceName = 'Storage'; Cost = 30.0; PreviousCost = 20.0; Change = 10.0; ChangePct = 50.0; Currency = 'EUR' }
        [PSCustomObject]@{ ServiceName = 'Storage'; Cost = 10.0; PreviousCost = 20.0; Change = -10.0; ChangePct = -50.0; Currency = 'EUR' })
    Assert-Equal 0.0 $cmp[0].Change 'change recomputed'; Assert-Equal 0.0 $cmp[0].ChangePct 'percent recomputed'
}
Test-That 'Ask on a tenant with no usable management group asks every subscription and adds up' {
    Reset-State
    $env:AZURE_SUBSCRIPTION_ID = $sub
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'costscope'; RowKey = 'resolved'; Scope = ''; Source = 'insufficient'; Name = 'Contoso-Root'; CoveragePct = 20.0 }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'subscriptions'; RowKey = 'discovered'
        SubscriptionsJson = (@([ordered]@{ id = $dataSub; name = 'Production - Data' }, [ordered]@{ id = $desktopSub; name = 'Production - Desktops' }) | ConvertTo-Json -Compress -AsArray) }
    $savedAi = $global:AiResponder; $savedCost = $global:CostResponder
    $global:AskStep = 0
    $global:AiResponder = { param($req) $global:AskStep++
        if ($global:AskStep -eq 1) { return New-ChatResponse @{ timeframe = 'MonthToDate'; from = $null; to = $null; granularity = 'None'; groupBy = @('ResourceGroupName'); filters = $null; compareWithPrevious = $false; scopeToContextSubscription = $false } }
        New-ChatResponse @{ answer = 'shared-rg is the largest.' } }
    $global:CostResponder = { param($b, $uri)
        if ($uri -like "*$dataSub*") { New-CostResponse -Columns @('Cost', 'ResourceGroupName', 'Currency') -Rows @(@(100.0, 'data-rg', 'EUR'), @(40.0, 'shared-rg', 'EUR')) }
        else { New-CostResponse -Columns @('Cost', 'ResourceGroupName', 'Currency') -Rows @(, @(80.0, 'shared-rg', 'EUR')) } }
    try {
        $body = [string](Invoke-HttpFunction -Name 'QueryCosts' -Body ([PSCustomObject]@{ question = 'Top resource groups by cost this month' })).Body | ConvertFrom-Json
        Assert-Equal 2 @($global:CostQueryBodies).Count 'one query per subscription'
        Assert-Equal 'shared-rg' $body.rows[0].ResourceGroupName 'largest across both subscriptions first'
        Assert-Equal 120.0 $body.rows[0].Cost 'added up'
        Assert-True ($body.scope -like 'all 2 subscriptions*') "scope says so: $($body.scope)"
        Assert-Equal 0 @($body.missingSubscriptions).Count 'none missing'
    } finally { $global:AiResponder = $savedAi; $global:CostResponder = $savedCost; $env:AZURE_SUBSCRIPTION_ID = $null }
}

Write-Host "`nAsk: answered from the portal's own per-resource cost"
$platformOne = [PSCustomObject]@{ Id = 'aaaaaaaa-0000-0000-0000-000000000003'; Name = 'Production - Shared' }
$askSubs3 = @($askSubs) + @($platformOne)
Test-That 'subscription names are found in the question text, longest first' {
    $f = @(Find-SubscriptionsInText -Text 'Top 10 most expensive resources in Production - Data' -Subscriptions $askSubs3)
    Assert-Equal 'Production - Data' (($f | ForEach-Object Name) -join ',') 'only the named one'
    $f2 = @(Find-SubscriptionsInText -Text 'compare production - desktops with Production - Shared' -Subscriptions $askSubs3)
    Assert-Equal 2 $f2.Count 'two, case-insensitive'
    $spec = Set-SpecSubscriptions -Spec ([PSCustomObject]@{ filters = @([PSCustomObject]@{ dimension = 'ResourceGroupName'; values = @('Production - Data') }) }) -Named $f
    Assert-Equal 'SubscriptionName' (@($spec.filters).dimension -join ',') 'the name the model put in a resource-group filter moves to the subscription filter'
}
function Initialize-ResourceIndex {
    $per = @{
        "/subscriptions/$dataSub/resourcegroups/data-rg/providers/microsoft.fabric/capacities/cap1" = @{ Current = 300.0; PreviousSameDays = 200.0; PreviousMonth = 600.0 }
        "/subscriptions/$dataSub/resourcegroups/data-rg/providers/microsoft.storage/storageaccounts/lake" = @{ Current = 50.0; PreviousSameDays = 60.0; PreviousMonth = 120.0 }
        "/subscriptions/$desktopSub/resourcegroups/desktop-rg/providers/microsoft.compute/virtualmachines/vm01" = @{ Current = 400.0; PreviousSameDays = 380.0; PreviousMonth = 800.0 }
    }
    $mb = @{}; foreach ($k in $per.Keys) { $mb[$k] = @{ MonthBefore = 10.0 } }
    $idx = @{}; foreach ($k in $per.Keys) { $idx[$k] = @{ Tags = @{ owner = $(if ($k -like '*data-rg*') { 'data-team' } else { 'desktop-team' }) }; Exists = $true } }
    $null = Write-ResourceCostIndex -Token 't' -PerResource $per -MonthBefore $mb -Index $idx -OwnerKey 'owner' -Month ([datetime]'2026-10-01') `
        -SettledThrough ([datetime]'2026-10-10') -PreviousSameDaysThrough ([datetime]'2026-09-10') -ScopeHash 'all'
}
Test-That 'the index answers top resources in a subscription, by owner, and with a comparison; other questions go live' {
    Reset-State
    Initialize-ResourceIndex
    $index = Read-ResourceCostIndex -Token 't'
    Assert-Equal 3 $index.Rows.Count 'three resources read back'
    $spec = [PSCustomObject]@{ timeframe = 'MonthToDate'; granularity = 'None'; groupBy = @('ResourceId'); filters = @([PSCustomObject]@{ dimension = 'SubscriptionName'; values = @('Production - Data') }) }
    $r = Invoke-StoredCostQuery -Spec $spec -IndexData $index -Subscriptions $askSubs3 -Rate ([PSCustomObject]@{ Currency = 'EUR'; Rate = 7.0 })
    Assert-Equal 2 @($r.rows).Count 'the two data resources'
    Assert-True ($r.rows[0].ResourceId -like '*cap1') 'largest first'
    Assert-Equal 2100.0 $r.rows[0].Cost 'converted to the billing currency'
    Assert-Equal 'EUR' $r.rows[0].Currency 'currency'
    $own = Invoke-StoredCostQuery -Spec ([PSCustomObject]@{ timeframe = 'TheLastMonth'; groupBy = @(); groupByTag = 'owner' }) -IndexData $index -Subscriptions $askSubs3
    Assert-Equal 'desktop-team' $own.rows[0].TagValue 'owner grouping, last month'
    Assert-Equal 800.0 $own.rows[0].Cost 'last month figure'
    $cmp = Invoke-StoredCostQuery -Spec ([PSCustomObject]@{ timeframe = 'MonthToDate'; groupBy = @('ResourceGroupName') }) -IndexData $index -Subscriptions $askSubs3 -Compare
    Assert-Equal 20.0 @($cmp.rows | Where-Object ResourceGroupName -eq 'desktop-rg')[0].Change 'comparison against the same days last month (400 - 380)'
    Assert-Equal 90.0 @($cmp.rows | Where-Object ResourceGroupName -eq 'data-rg')[0].Change 'change (350 - 260)'
    Assert-True ($null -eq (Invoke-StoredCostQuery -Spec ([PSCustomObject]@{ timeframe = 'MonthToDate'; groupBy = @('ServiceName') }) -IndexData $index -Subscriptions $askSubs3)) 'service: not in the index'
    Assert-True ($null -eq (Invoke-StoredCostQuery -Spec ([PSCustomObject]@{ timeframe = 'MonthToDate'; granularity = 'Daily'; groupBy = @() }) -IndexData $index -Subscriptions $askSubs3)) 'daily trend: not in the index'
}
Test-That 'Ask: the screenshot question is answered from the index, with no Cost Management call' {
    Reset-State
    Initialize-ResourceIndex
    $env:AZURE_SUBSCRIPTION_ID = $sub
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'costscope'; RowKey = 'resolved'; Scope = ''; Source = 'insufficient'; Name = 'Contoso-Root'; CoveragePct = 20.0 }
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'subscriptions'; RowKey = 'discovered'
        SubscriptionsJson = (@($askSubs3 | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name } }) | ConvertTo-Json -Compress -AsArray) }
    $savedAi = $global:AiResponder
    $global:AskStep = 0
    # The model does not know the subscription names and files the name as a resource group.
    $global:AiResponder = { param($req) $global:AskStep++
        if ($global:AskStep -eq 1) { return New-ChatResponse @{ timeframe = 'MonthToDate'; from = $null; to = $null; granularity = 'None'; groupBy = @('ResourceId'); compareWithPrevious = $false; scopeToContextSubscription = $false
            filters = @(@{ dimension = 'ResourceGroupName'; values = @('Production - Data') }) } }
        New-ChatResponse @{ answer = 'cap1 is the most expensive.' } }
    try {
        $body = [string](Invoke-HttpFunction -Name 'QueryCosts' -Body ([PSCustomObject]@{ question = 'Top 10 most expensive resources in Production - Data' })).Body | ConvertFrom-Json
        Assert-Equal 0 @($global:CostQueryBodies).Count 'no Cost Management call'
        Assert-Equal 2 @($body.rows).Count 'both data resources'
        Assert-True ($body.scope -like 'Production - Data, *nightly cost data*') "scope: $($body.scope)"
    } finally { $global:AiResponder = $savedAi; $env:AZURE_SUBSCRIPTION_ID = $null }
}

Write-Host "`nIngest marker check"
Test-That 'MaxWaitMinutes 0 returns at once and reports whether today''s ingest ran' {
    Reset-State
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $none = Wait-ForIngestCompletion -Token 't' -MaxWaitMinutes 0
    Assert-True ($sw.Elapsed.TotalSeconds -lt 5) 'no sleeping'
    Assert-True (-not $none.Complete -and -not $none.Reported) 'no marker: not complete, not reported'
    Assert-True ($none.Reason -like '*not waiting*') "reason says it did not wait: $($none.Reason)"
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'ingest'; RowKey = 'lastrun'; At = [datetime]::UtcNow.AddDays(-1).ToString('o'); Complete = $true }
    $old = Wait-ForIngestCompletion -Token 't' -MaxWaitMinutes 0
    Assert-True (-not $old.Reported) "yesterday's marker is not today's"
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'ingest'; RowKey = 'lastrun'; At = [datetime]::UtcNow.ToString('o'); Complete = $false; SubscriptionsOk = 3; SubscriptionsTotal = 4 }
    $partial = Wait-ForIngestCompletion -Token 't' -MaxWaitMinutes 0
    Assert-True ($partial.Reported -and -not $partial.Complete) 'today, incomplete: reported'
}

Write-Host "`nDetection timer end-to-end (stubbed)"
$global:IngestState = [PSCustomObject]@{ Complete = $true; Reported = $true; Reason = 'stub' }
function global:Wait-ForIngestCompletion { param($Token, $MaxWaitMinutes, $PollSeconds) $global:IngestState }
function global:Get-AccessibleSubscriptions { param($MgmtToken) @([PSCustomObject]@{ Id = $sub; Name = 'Production' }) }
function global:Resolve-ResourceDisplayNames { param($ResourceIds, $MgmtToken) $m = @{}; foreach ($i in @($ResourceIds)) { if ($i) { $m[$i.ToLower()] = ($i -split '/')[-1] } }; $m }
# $global: — a bare $ctx would resolve dynamically to the timer's own $ctx variable.
$global:TestCtx = $ctx
function global:Get-ResourceContext { param($ResourceId, $MgmtToken) $global:TestCtx }
function global:Remove-TableEntityBatch { param($Table, $Entities, $Token) 0 }
function Initialize-SnapshotStore {
    Reset-State
    $windowEnd = [datetime]::UtcNow.Date.AddDays(-2)
    for ($d = $windowEnd.AddDays(-40); $d -le $windowEnd; $d = $d.AddDays(1)) {
        $inCurrent = $d -gt $windowEnd.AddDays(-7)
        foreach ($r in @(
            @{ id = $vm; cost = $(if ($inCurrent) { 40.0 } else { 12.0 }) }
            @{ id = "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.storage/storageaccounts/steady"; cost = 5.0 }
        )) {
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = (Get-ShortHash -Value $r.id)
                Date = $d.ToString('yyyy-MM-dd'); DimensionKey = $r.id; Scope = $sub; ResourceId = $r.id; Meter = 'Virtual Machines'; CostUsd = $r.cost }
        }
    }
}
$timer = Join-Path $fa 'DetectCostSpikes-Timer/run.ps1'
Test-That 'weekly finding gets evidence, a cited explanation, and no retired confidence' {
    Initialize-SnapshotStore
    & $timer -Timer $null *> $null
    $rows = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })
    Assert-Equal 1 $rows.Count 'one weekly finding'
    $r = $rows[0]
    Assert-Equal 'complete' $r.EvidenceStatus 'evidence status'
    Assert-Equal 'explained' $r.ExplanationStatus 'explanation status'
    Assert-True ($r.Explained -and $r.Headline) 'explained with text'
    Assert-True ((($r.CitedFactsJson | ConvertFrom-Json) -join ',') -eq 'F1,F2,F4') 'citations stored'
    Assert-Equal '' $r.Confidence 'confidence cleared'
    Assert-True (($r.EvidenceJson | ConvertFrom-Json).facts.Count -gt 3) 'evidence stored'
    Assert-Equal 1 $global:WebCalls.Count 'one AI call'
}
Test-That 'a rerun reuses evidence and explanation (no new queries, no new AI call)' {
    $queries = $global:CostQueryBodies.Count; $calls = $global:WebCalls.Count
    & $timer -Timer $null *> $null
    Assert-Equal $queries $global:CostQueryBodies.Count 'no new cost queries'
    Assert-Equal $calls $global:WebCalls.Count 'no new AI call'
    $r = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })[0]
    Assert-Equal 'reused' $r.ExplanationStatus 'reused'
}
Test-That 'without AI: evidence still stored, explanation fields cleared' {
    Initialize-SnapshotStore
    $env:AI_API_KEY = ''
    & $timer -Timer $null *> $null
    $r = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })[0]
    Assert-Equal 'complete' $r.EvidenceStatus 'evidence'
    Assert-Equal 'not-configured' $r.ExplanationStatus 'status'
    Assert-Equal '' $r.Headline 'no headline'
    Assert-Equal 0 $global:WebCalls.Count 'no calls'
}
Test-That 'EvidenceMaxFindings = 0 skips evidence and explanation' {
    Initialize-SnapshotStore
    Set-Setting @{ EvidenceMaxFindings = 0 }
    & $timer -Timer $null *> $null
    $r = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })[0]
    Assert-Equal 'skipped' $r.EvidenceStatus 'skipped'
    Assert-Equal 'no-evidence' $r.ExplanationStatus 'no explanation'
    Assert-Equal 0 $global:CostQueryBodies.Count 'no evidence queries'
}

Test-That 'the month rollup waits while the ingest may still rewrite the month''s last days' {
    Initialize-SnapshotStore
    $env:AI_API_KEY = ''
    # The unreported-ingest safety window is BaselineDays + 2 days back from today. With the
    # default 7, last month leaves that window on the 10th, so the result depended on the date
    # the tests ran. 40 keeps last month inside it on any day.
    Set-Setting @{ BaselineDays = 40 }
    $first = [datetime]::new([datetime]::UtcNow.Year, [datetime]::UtcNow.Month, 1).AddMonths(-1)
    for ($d = $first; $d -lt $first.AddMonths(1); $d = $d.AddDays(1)) {
        Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $d.ToString('yyyy-MM-dd'); RowKey = 'm1'
            Date = $d.ToString('yyyy-MM-dd'); DimensionKey = 'rollup-probe'; Scope = $sub; ResourceId = 'rollup-probe'; Meter = 'x'; CostUsd = 1.0 }
    }
    $monthRollups = { @($global:Store['PortalConfig'].Values | Where-Object { $_.PartitionKey -eq 'rollup' }).Count }
    $global:IngestState = [PSCustomObject]@{ Complete = $false; Reported = $false; Reason = 'stub: not yet' }
    try {
        & $timer -Timer $null *> $null
        Assert-Equal 0 (& $monthRollups) 'no rollup while the ingest may still run'
        Assert-True (@($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' }).Count -ge 1) 'detection still ran'
        $summary = @($global:Store['CostSummary'].Values | Where-Object { $_.PartitionKey -eq 'dashboard' })
        if ($summary.Count) { Assert-Equal $false $summary[0].DataComplete 'flagged incomplete' }
    } finally { $global:IngestState = [PSCustomObject]@{ Complete = $true; Reported = $true; Reason = 'stub' } }
    & $timer -Timer $null *> $null
    Assert-Equal 1 (& $monthRollups) 'rolled up once the ingest reported'
}

# Ten VMs, each mostly compute, each with a small Defender plan that rises in the current window.
# No VM moves enough to be a finding, and Defender is never any VM's largest category, so only
# the exact category totals can see the rise.
function Initialize-SpreadStore {
    param([switch]$WithCategories, [int]$CategoryDays = 999)
    Reset-State
    $env:AI_API_KEY = ''
    Set-Setting @{ EvidenceMaxFindings = 0 }
    $windowEnd = [datetime]::UtcNow.Date.AddDays(-2)
    $i = 0
    for ($d = $windowEnd.AddDays(-40); $d -le $windowEnd; $d = $d.AddDays(1)) {
        $inCurrent = $d -gt $windowEnd.AddDays(-7)
        $def = if ($inCurrent) { 4.0 } else { 0.5 }
        $day = $d.ToString('yyyy-MM-dd')
        foreach ($n in 1..10) {
            $id = "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm$n"
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $day; RowKey = (Get-ShortHash -Value $id)
                Date = $day; DimensionKey = $id; Scope = $sub; ResourceId = $id; Meter = 'Virtual Machines'; CostUsd = 100.0 + $def }
        }
        if ($WithCategories -and $i -lt $CategoryDays) {
            foreach ($c in @(@{ m = 'Virtual Machines'; v = 1000.0 }, @{ m = 'Microsoft Defender for Cloud'; v = 10 * $def })) {
                Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = "cat|$day"; RowKey = (Get-ShortHash -Value "$sub|$($c.m)"); Kind = 'category'
                    Date = $day; DimensionKey = (Get-DimensionKey -Dimension 'meter' -Scope $sub -Meter $c.m); Scope = $sub; ResourceId = ''; Meter = $c.m; CostUsd = $c.v }
            }
        }
        $i++
    }
}
Test-That 'meter grain: a rise spread thinly over many resources is found from the category totals' {
    Initialize-SpreadStore -WithCategories
    & $timer -Timer $null *> $null
    $rows = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' })
    Assert-Equal 1 $rows.Count 'one weekly finding'
    Assert-Equal 'meter' $rows[0].Dimension 'a meter finding'
    Assert-Equal 'Microsoft Defender for Cloud' $rows[0].Meter 'Defender'
    Assert-Equal 245.0 ([Math]::Round([double]$rows[0].DeltaUsd, 2)) 'the whole category rise: 10 VMs x 3.5 x 7'
    Assert-Equal 'open' $rows[0].State 'current level measured from the category totals'
}
Test-That 'monthly: category totals are rolled up beside the resource rows and drive the meter grain' {
    Reset-State
    $env:AI_API_KEY = ''
    Set-Setting @{ EvidenceMaxFindings = 0 }
    $m1 = [datetime]::new([datetime]::UtcNow.Year, [datetime]::UtcNow.Month, 1).AddMonths(-1)   # analysed
    for ($d = $m1.AddMonths(-2); $d -lt $m1.AddMonths(1); $d = $d.AddDays(1)) {
        $def = if ($d -ge $m1) { 4.0 } else { 0.5 }
        $day = $d.ToString('yyyy-MM-dd')
        foreach ($n in 1..10) {
            $id = "/subscriptions/$sub/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm$n"
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = $day; RowKey = (Get-ShortHash -Value $id)
                Date = $day; DimensionKey = $id; Scope = $sub; ResourceId = $id; Meter = 'Virtual Machines'; CostUsd = 100.0 + $def }
        }
        foreach ($c in @(@{ m = 'Virtual Machines'; v = 1000.0 }, @{ m = 'Microsoft Defender for Cloud'; v = 10 * $def })) {
            Set-TableEntity -Table 'CostSnapshots' -Entity @{ PartitionKey = "cat|$day"; RowKey = (Get-ShortHash -Value "$sub|$($c.m)"); Kind = 'category'
                Date = $day; DimensionKey = (Get-DimensionKey -Dimension 'meter' -Scope $sub -Meter $c.m); Scope = $sub; ResourceId = ''; Meter = $c.m; CostUsd = $c.v }
        }
    }
    & $timer -Timer $null *> $null
    $key = $m1.ToString('yyyy-MM')
    Assert-True ([bool]$global:Store['PortalConfig']["rollup|month|$key"].Categories) 'marker records the category rows'
    $cat = @($global:Store['CostPeriods'].Values | Where-Object { $_.PartitionKey -eq "month|$key" -and $_.Kind -eq 'category' })
    Assert-Equal 2 $cat.Count 'one row per category'
    Assert-Equal 10 @($global:Store['CostPeriods'].Values | Where-Object { $_.PartitionKey -eq "month|$key" -and $_.Kind -ne 'category' }).Count 'resource rows untouched'
    $f = @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -eq "month|$key" })
    Assert-Equal 1 $f.Count 'one monthly finding'
    Assert-Equal 'Microsoft Defender for Cloud' $f[0].Meter 'the Defender category'
    $days = [datetime]::DaysInMonth($m1.Year, $m1.Month)
    Assert-Equal (10 * 4.0 * $days) ([Math]::Round([double]$f[0].SpikeUsd, 2)) 'its exact month total'
}
Test-That 'meter grain: without category totals for every day it keeps the label basis (and misses it)' {
    Initialize-SpreadStore
    & $timer -Timer $null *> $null
    Assert-Equal 0 @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' }).Count 'nothing on the label basis'
    Initialize-SpreadStore -WithCategories -CategoryDays 20
    & $timer -Timer $null *> $null
    Assert-Equal 0 @($global:Store['CostSpikes'].Values | Where-Object { $_.PartitionKey -like 'week|*' }).Count 'partly covered: never mixes the two bases'
}

Write-Host "`nMonth overview (forecast, budgets, by service)"
Test-That 'forecast splits actual from projected and sums the month' {
    Reset-State
    $saved = $global:CostResponder
    $global:CostResponder = {
        param($b, $u)
        New-CostResponse -Columns @('CostUSD', 'UsageDate', 'CostStatus', 'Currency') -Rows @(
            , @(100.0, 20260901, 'Actual', 'USD')
            , @(120.0, 20260902, 'Actual', 'USD')
            , @(130.0, 20260903, 'Forecast', 'USD')
            , @(140.0, 20260904, 'Forecast', 'USD')
        )
    }
    try { $f = Get-CostForecast -Scope "/subscriptions/$sub" -MgmtToken 't' -From ([datetime]'2026-09-01') -To ([datetime]'2026-09-30') }
    finally { $global:CostResponder = $saved }
    Assert-Equal 220.0 $f.ActualAmount 'actual'
    Assert-Equal 270.0 $f.ForecastAmount 'forecast'
    Assert-Equal 490.0 $f.TotalAmount 'month-end total'
    $body = $global:CostQueryBodies[0]
    Assert-True ([bool]$body.includeActualCost) 'includeActualCost'
    Assert-True (-not $body.includeFreshPartialCost) 'partial days excluded'
    Assert-Equal 1 @($body.dataset.aggregation.PSObject.Properties).Count 'one aggregation'
}
Test-That 'budgets: cost-category only, expired dropped, never throws' {
    Reset-State
    $saved = $global:RestResponder
    $global:RestResponder = {
        param($method, $uri, $body)
        [PSCustomObject]@{ nextLink = $null; value = @(
            [PSCustomObject]@{ name = 'monthly-prod'; properties = [PSCustomObject]@{ category = 'Cost'; amount = 10000; timeGrain = 'Monthly'
                timePeriod = [PSCustomObject]@{ startDate = '2026-01-01T00:00:00Z'; endDate = '2027-01-01T00:00:00Z' }
                currentSpend = [PSCustomObject]@{ amount = 7400; unit = 'EUR' }; forecastSpend = [PSCustomObject]@{ amount = 11200; unit = 'EUR' } } }
            [PSCustomObject]@{ name = 'expired'; properties = [PSCustomObject]@{ category = 'Cost'; amount = 500; timeGrain = 'Monthly'
                timePeriod = [PSCustomObject]@{ startDate = '2025-01-01T00:00:00Z'; endDate = '2025-12-31T00:00:00Z' }
                currentSpend = [PSCustomObject]@{ amount = 500; unit = 'EUR' } } }
            [PSCustomObject]@{ name = 'usage-budget'; properties = [PSCustomObject]@{ category = 'Usage'; amount = 5; timeGrain = 'Monthly'
                currentSpend = [PSCustomObject]@{ amount = 1; unit = 'Hours' } } }
        ) }
    }
    try { $b = @(Get-ConsumptionBudgets -Scope "/subscriptions/$sub" -MgmtToken 't' -ScopeName 'Production') }
    finally { $global:RestResponder = $saved }
    Assert-Equal 1 $b.Count 'one live cost budget'
    Assert-Equal 'monthly-prod' $b[0].Name 'name'
    Assert-Equal 7400.0 $b[0].SpentAmount 'spend'
    Assert-Equal 'EUR' $b[0].Currency 'currency'
    Assert-Equal 11200.0 $b[0].ForecastAmount 'budget forecast'

    $global:RestResponder = { param($m, $u, $x) throw 'permission denied' }
    $none = @(Get-ConsumptionBudgets -Scope "/subscriptions/$sub" -MgmtToken 't')
    Assert-Equal 0 $none.Count 'a denied read is empty, not an exception'
    $global:RestResponder = $saved
}
# The month-to-date rows the cost ingest derives (CostIngest.psm1, Update-MonthlySubRows).
function Set-MonthToDate { param([string]$Month)
    foreach ($x in @(@{ id = $sub; usd = 600.0 }, @{ id = '22222222-2222-3333-4444-555555555555'; usd = 300.0 })) {
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'monthly-sub'; RowKey = "$Month|$($x.id)"; Month = $Month; SubscriptionId = $x.id; CostUsd = $x.usd }
    }
}
Test-That 'monthly sync writes the month overview: forecast across subscriptions and budgets' {
    Reset-State
    $settled = [datetime]::UtcNow.Date.AddDays(-2)
    $m0 = (Get-UtcMonthStart -Date $settled).ToString('yyyy-MM')
    $m1 = (Get-UtcMonthStart -Date $settled).AddMonths(-1).ToString('yyyy-MM')
    $m2 = (Get-UtcMonthStart -Date $settled).AddMonths(-2).ToString('yyyy-MM')
    # Month-to-date per subscription, as the cost ingest derives it ('monthly-sub'): 600 + 300.
    Set-MonthToDate -Month $m0
    function global:Get-AccessibleSubscriptions { param($MgmtToken) @(
        [PSCustomObject]@{ Id = $sub; Name = 'Production' }
        [PSCustomObject]@{ Id = '22222222-2222-3333-4444-555555555555'; Name = 'Data Platform' }
    ) }
    function global:Get-CostForecast { param($Scope, $MgmtToken, $From, $To, $Field, $CostType)
        if ($Field -eq 'Cost') { [PSCustomObject]@{ TotalAmount = 12900.0; Currency = 'EUR' } }
        else { [PSCustomObject]@{ TotalAmount = 2000.0; ActualAmount = 900.0; Currency = 'USD' } } }
    function global:Get-ConsumptionBudgets { param($Scope, $MgmtToken, $ScopeName)
        @([PSCustomObject]@{ Name = "budget-$ScopeName"; Scope = $Scope; ScopeName = $ScopeName; Amount = 10000; Currency = 'EUR'
            TimeGrain = 'Monthly'; SpentAmount = 7400; ForecastAmount = 11200; StartDate = ''; EndDate = ''; ResourceGroupId = '' }
          [PSCustomObject]@{ Name = "rg-budget-$ScopeName"; Scope = "$Scope/resourcegroups/rg-dev"; ScopeName = 'rg-dev'; Amount = 1300; Currency = 'EUR'
            TimeGrain = 'Monthly'; SpentAmount = 2176; ForecastAmount = 3000; StartDate = ''; EndDate = ''; ResourceGroupId = "$Scope/resourcegroups/rg-dev" }) }
    $env:AZURE_SUBSCRIPTION_ID = $sub
    $env:COST_QUERY_SCOPE = ''
    # Azure's own USD->EUR ratio, from the daily totals (6.45).
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $settled.ToString('yyyy-MM-dd'); TotalUsd = 100.0; TotalBilling = 645.0; Currency = 'EUR' }

    & (Join-Path $fa 'SyncMonthlyCosts-Timer/run.ps1') -Timer $null *> $null
    $row = $global:Store['CostSummary']['monthoverview|current']
    Assert-Equal $m0 $row.Month 'month is the settled day''s month'
    Assert-Equal 0 @(@($row.BudgetsJson | ConvertFrom-Json) | Where-Object CoversPortal).Count 'a subscription''s budget does not speak for a two-subscription month'
    Assert-True ([double]$row.ForecastUsd -ge 900) 'the forecast is not below month-to-date'
    # No management group covers both subscriptions (none can be listed here), so the forecast is
    # the sum of the two per-subscription forecasts — not the deployment subscription's alone,
    # which is what it silently was before 2026-09-18 while month-to-date covered both.
    Assert-Equal 4000.0 $row.ForecastUsd 'forecast covers both subscriptions'
    Assert-Equal 'per-subscription' $row.ForecastCoverage 'coverage recorded'
    Assert-Equal 25800.0 $row.ForecastBilling 'billing currency via Azure''s own ratio'
    Assert-True ($null -eq $row.ByServiceJson) 'no spend-by-service any more'
    Assert-Equal 2 @($row.BudgetsJson | ConvertFrom-Json).Count 'one budget per subscription'
    Assert-Equal 2 @(Get-MonthBudgetList -Overview $row -Kind Rg -StorageToken 't').Count 'group budgets kept apart, never the month''s budget'
    Assert-Equal '' $row.RgBudgetsJson 'not inline on the overview row (64 KiB limit)'
}
Test-That 'with a management-group scope the forecast is one query, filtered when needed' {
    $global:ForecastCalls = [System.Collections.Generic.List[object]]::new()
    function global:Get-CostForecast { param($Scope, $MgmtToken, $From, $To, $Field, $CostType, $SubscriptionIds)
        $global:ForecastCalls.Add([PSCustomObject]@{ Scope = $Scope; Subs = @($SubscriptionIds) })
        if ($Field -eq 'Cost') { [PSCustomObject]@{ TotalAmount = 12900.0; Currency = 'EUR' } }
        else { [PSCustomObject]@{ TotalAmount = 2000.0; ActualAmount = 900.0; Currency = 'USD' } } }
    $env:COST_QUERY_SCOPE = '/providers/Microsoft.Management/managementGroups/mg-finance'
    try {
        & (Join-Path $fa 'SyncMonthlyCosts-Timer/run.ps1') -Timer $null *> $null
        $row = $global:Store['CostSummary']['monthoverview|current']
        Assert-Equal 2000.0 $row.ForecastUsd 'the group''s own forecast'
        Assert-Equal 12900.0 $row.ForecastBilling 'billing currency from Azure'
        Assert-Equal 'scope' $row.ForecastCoverage 'coverage'
        Assert-Equal 2 $global:ForecastCalls.Count 'USD + billing, nothing per subscription'
        Assert-Equal 2 @($global:ForecastCalls[0].Subs).Count 'a configured group is filtered to the included subscriptions'
    } finally { $env:COST_QUERY_SCOPE = '' }
}
Test-That 'a management group that sees only part of the spend is not used for the forecast or for Ask' {
    Reset-State
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = [datetime]::UtcNow.Date.AddDays(-2).ToString('yyyy-MM-dd'); TotalUsd = 100.0; TotalBilling = 645.0; Currency = 'EUR' }
    $global:TestMonthKey = (Get-UtcMonthStart -Date ([datetime]::UtcNow.Date.AddDays(-2))).ToString('yyyy-MM')
    # Month-to-date per subscription: 600 + 300 = 900 USD.
    Set-MonthToDate -Month $global:TestMonthKey
    # The group's cost data shows 150 of the 900.
    function global:Get-CostForecast { param($Scope, $MgmtToken, $From, $To, $Field, $CostType, $SubscriptionIds)
        [PSCustomObject]@{ TotalAmount = 240.0; ActualAmount = 150.0; Currency = 'USD' } }
    # Discovery happens inside the module, so the group is planted there (and put back after).
    $cam = Get-Module CostAnalysis
    $orig = & $cam { ${function:Find-CoveringManagementGroup} }
    & $cam { ${function:script:Find-CoveringManagementGroup} = { param($MgmtToken, $SubscriptionIds)
        [PSCustomObject]@{ Scope = '/providers/Microsoft.Management/managementGroups/root'; Name = 'Tenant Root'; Extra = 0 } } }
    try { & (Join-Path $fa 'SyncMonthlyCosts-Timer/run.ps1') -Timer $null *> $null }
    finally { & $cam { param($f) ${function:script:Find-CoveringManagementGroup} = $f } $orig }
    $row = $global:Store['CostSummary']['monthoverview|current']
    Assert-Equal -1 $row.ForecastUsd 'the group''s forecast is not shown'
    Assert-True ([string]$row.ForecastNote -like '*sees only 17%*') "the note says why: $($row.ForecastNote)"
    $r = Get-ResolvedCostScope -StorageToken 't'
    Assert-Equal 'insufficient' $r.Source 'the group is marked as not seeing all the spend'
    Assert-Equal '' $r.Scope 'so live questions do not use it'
    $env:AZURE_SUBSCRIPTION_ID = $sub
    Assert-True ((Resolve-PortalQueryScope -StorageToken 't').Label -like '*Tenant Root shows only 17%*') 'Ask says why it covers less'
}
Test-That 'a forecast below what has already been spent is rejected' {
    Reset-State
    $global:TestMonthKey = (Get-UtcMonthStart -Date ([datetime]::UtcNow.Date.AddDays(-2))).ToString('yyyy-MM')
    # Month-to-date per subscription: 600 + 300 = 900 USD.
    Set-MonthToDate -Month $global:TestMonthKey
    function global:Get-CostForecast { param($Scope, $MgmtToken, $From, $To, $Field, $CostType, $SubscriptionIds)
        [PSCustomObject]@{ TotalAmount = 850.0; ActualAmount = 880.0; Currency = 'USD' } }
    $env:COST_QUERY_SCOPE = '/providers/Microsoft.Management/managementGroups/mg-finance'
    try {
        & (Join-Path $fa 'SyncMonthlyCosts-Timer/run.ps1') -Timer $null *> $null
        $row = $global:Store['CostSummary']['monthoverview|current']
        Assert-Equal -1 $row.ForecastUsd 'rejected'
        Assert-True ([string]$row.ForecastNote -like '*below what has already been spent*') 'said so'
        Assert-Equal 'configured' (Get-ResolvedCostScope -StorageToken 't').Source 'a configured scope is never overridden'
    } finally { $env:COST_QUERY_SCOPE = '' }
}
Test-That 'forecast unavailable is stored as -1, never left stale' {
    $global:Store['CostSummary'].Remove('monthoverview|current') | Out-Null
    function global:Get-CostForecast { param($Scope, $MgmtToken, $From, $To, $Field, $CostType) throw 'insufficient history' }
    & (Join-Path $fa 'SyncMonthlyCosts-Timer/run.ps1') -Timer $null *> $null
    $row = $global:Store['CostSummary']['monthoverview|current']
    Assert-Equal -1 $row.ForecastUsd 'sentinel, not null (a MERGE would keep the old figure)'
    Assert-True ([string]$row.ForecastNote -like '*could not produce a forecast*') 'note explains why'
}

Write-Host "`nSavings: priced, tiered, tracked"
Test-That 'next size down stays in the same family; odd shapes decline' {
    Assert-Equal 'Standard_D4s_v5' (Get-NextSmallerVmSize -VmSize 'Standard_D8s_v5') 'D8s v5'
    Assert-Equal 'Standard_E16as_v5' (Get-NextSmallerVmSize -VmSize 'Standard_E20as_v5') 'E20as v5'
    Assert-True ($null -eq (Get-NextSmallerVmSize -VmSize 'Standard_D1s_v5')) 'already smallest'
    Assert-True ($null -eq (Get-NextSmallerVmSize -VmSize 'Standard_E8-4s_v5')) 'constrained-core sizes are left alone'
    Assert-True ($null -eq (Get-NextSmallerVmSize -VmSize 'CustomSize')) 'unrecognised shape'
}
Test-That 'percentile interpolates' {
    Assert-Equal 5.0 (Get-Percentile -Values @(1, 2, 3, 4, 5) -Percentile 100) 'max'
    Assert-Equal 3.0 (Get-Percentile -Values @(1, 2, 3, 4, 5) -Percentile 50) 'median'
    Assert-Equal 4.6 (Get-Percentile -Values @(1, 2, 3, 4, 5) -Percentile 90) 'p90'
}
Test-That 'retail price: Spot and the wrong OS excluded, cheapest kept, cached' {
    Reset-State
    $script:priceCalls = 0
    $saved = $global:RestResponder
    $global:RestResponder = {
        param($method, $uri, $body)
        $script:priceCalls++
        [PSCustomObject]@{ Items = @(
            [PSCustomObject]@{ retailPrice = 0.096; skuName = 'D4s v5'; productName = 'Virtual Machines Dsv5 Series'; armSkuName = 'Standard_D4s_v5' }
            [PSCustomObject]@{ retailPrice = 0.088; skuName = 'D4s v5'; productName = 'Virtual Machines Dsv5 Series'; armSkuName = 'Standard_D4s_v5' }
            [PSCustomObject]@{ retailPrice = 0.011; skuName = 'D4s v5 Spot'; productName = 'Virtual Machines Dsv5 Series'; armSkuName = 'Standard_D4s_v5' }
            [PSCustomObject]@{ retailPrice = 0.284; skuName = 'D4s v5'; productName = 'Virtual Machines Dsv5 Series Windows'; armSkuName = 'Standard_D4s_v5' }
        ) }
    }
    try {
        $cache = @{}
        $linux = Get-VmHourlyPrice -VmSize 'Standard_D4s_v5' -Region 'westeurope' -OsType 'Linux' -Cache $cache
        $win = Get-VmHourlyPrice -VmSize 'Standard_D4s_v5' -Region 'westeurope' -OsType 'Windows' -Cache $cache
        $again = Get-VmHourlyPrice -VmSize 'Standard_D4s_v5' -Region 'westeurope' -OsType 'Linux' -Cache $cache
    } finally { $global:RestResponder = $saved }
    Assert-Equal 0.088 $linux 'cheapest non-Spot Linux meter'
    Assert-Equal 0.284 $win 'Windows priced separately'
    Assert-Equal 0.088 $again 'cached'
    Assert-Equal 2 $script:priceCalls 'one call per (size, region, OS)'
}

$vmIdle = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-idle"
function Set-VmResponders {
    param([double]$Cpu = 4, [double]$MemP5Ratio = 1.0, [switch]$NoMemory, [switch]$NoPrice)
    $global:RestResponder = {
        param($method, $uri, $body)
        if ($uri -like '*prices.azure.com*') {
            if ($NoPrice) { return [PSCustomObject]@{ Items = @() } }
            $price = if ($uri -match 'D8s_v5') { 0.192 } elseif ($uri -match 'D4s_v5') { 0.096 } else { 0 }
            return [PSCustomObject]@{ Items = @([PSCustomObject]@{ retailPrice = $price; skuName = 'x'; productName = 'Virtual Machines Dsv5 Series' }) }
        }
        if ($uri -like '*Available%20Memory%20Bytes*') {
            if ($NoMemory) { throw 'metric not found' }
            $data = @(1..48 | ForEach-Object { [PSCustomObject]@{ average = $(if ($_ -le 6) { 1000 * $MemP5Ratio } else { 1000 }) } })
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ timeseries = @([PSCustomObject]@{ data = $data }) }) }
        }
        if ($uri -like '*Percentage%20CPU*') {
            $data = @(1..48 | ForEach-Object { [PSCustomObject]@{ average = $Cpu } })
            return [PSCustomObject]@{ value = @([PSCustomObject]@{ timeseries = @([PSCustomObject]@{ data = $data }) }) }
        }
        if ($uri -like '*ResourceGraph*') {
            return [PSCustomObject]@{ data = @([PSCustomObject]@{ id = $vmIdle; name = 'vm-idle'; location = 'westeurope'; vmSize = 'Standard_D8s_v5'; osType = 'Linux' }) }
        }
        throw "unexpected $uri"
    }.GetNewClosure()
}
$idleCostMap = @{ $vmIdle = [PSCustomObject]@{ AvgDaily = 4.6; Days = @(); TotalDays = 14; Scope = $sub; Meter = 'Virtual Machines' } }

Test-That 'idle VM: saving is the real price difference, not a percentage of the bill' {
    Reset-State; Set-VmResponders -Cpu 4
    $f = @(Get-LowUtilizationVms -CostMap $idleCostMap -MgmtToken 't' -SubscriptionIds @($sub) -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow))
    Assert-Equal 1 $f.Count 'one finding'
    Assert-Equal 'likely' $f[0].Tier 'priced, so likely'
    # (0.192 - 0.096) x 730 = 70.08, capped by the VM's own monthly cost (4.6 x 30.4 = 139.84).
    Assert-Equal 70.08 $f[0].EstMonthlySavingsUsd 'price difference x 730'
    Assert-Equal 'Resize Standard_D8s_v5 to Standard_D4s_v5' $f[0].Title 'names the target size'
    Assert-Equal 'Standard_D4s_v5' $f[0].Evidence.targetSize 'target recorded'
    Assert-Equal 'high' $f[0].Confidence 'memory metric present raises confidence'
}
Test-That 'a busy VM is not a candidate, however cheap the downsize would be' {
    Reset-State; Set-VmResponders -Cpu 35
    $f = @(Get-LowUtilizationVms -CostMap $idleCostMap -MgmtToken 't' -SubscriptionIds @($sub) -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow))
    Assert-Equal 0 $f.Count 'no finding'
}
Test-That 'CPU-idle but memory-tight is dropped' {
    Reset-State; Set-VmResponders -Cpu 4 -MemP5Ratio 0.1
    $f = @(Get-LowUtilizationVms -CostMap $idleCostMap -MgmtToken 't' -SubscriptionIds @($sub) -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow))
    Assert-Equal 0 $f.Count 'memory pressure vetoes the resize'
}
Test-That 'no published price -> indicative, zero figure' {
    Reset-State; Set-VmResponders -Cpu 4 -NoPrice
    $f = @(Get-LowUtilizationVms -CostMap $idleCostMap -MgmtToken 't' -SubscriptionIds @($sub) -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow))
    Assert-Equal 'indicative' $f[0].Tier 'tier'
    Assert-Equal 0.0 $f[0].EstMonthlySavingsUsd 'no figure to claim'
}
Test-That 'a reservation-covered VM is never priced as a saving' {
    Reset-State; Set-VmResponders -Cpu 4
    $f = @(Get-LowUtilizationVms -CostMap $idleCostMap -MgmtToken 't' -SubscriptionIds @($sub) `
        -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow) -CoveredResourceIds @($vmIdle.ToLower()))
    Assert-Equal 'indicative' $f[0].Tier 'tier'
    Assert-Equal 0.0 $f[0].EstMonthlySavingsUsd 'zero'
    Assert-True ($f[0].Detail -like '*commitment*') 'says why'
    Assert-True ([bool]$f[0].Evidence.commitmentCovered) 'recorded in the evidence'
}
Test-That 'commitment coverage: only committed usage counts, failure is not fatal' {
    Reset-State
    $saved = $global:CostResponder
    $global:CostResponder = {
        param($b, $u)
        New-CostResponse -Columns @('CostUSD', 'ResourceId', 'Currency') -Rows @(
            , @(120.0, $vmIdle, 'USD')
            , @(0.0, "$vmIdle-other", 'USD')
        )
    }
    try { $covered = @(Get-CommitmentCoveredResources -SubscriptionId $sub -MgmtToken 't' -ResourceIds @($vmIdle, "$vmIdle-other")) }
    finally { $global:CostResponder = $saved }
    Assert-Equal 1 $covered.Count 'only the row with committed cost'
    Assert-Equal $vmIdle.ToLower() $covered[0] 'lower-cased id'
    $b = $global:CostQueryBodies[0]
    Assert-Equal 'PricingModel' $b.dataset.filter.and[0].dimensions.name 'filtered on PricingModel'

    $global:CostResponder = { param($b, $u) throw 'Cost Management said no' }
    Assert-Equal 0 @(Get-CommitmentCoveredResources -SubscriptionId $sub -MgmtToken 't' -ResourceIds @($vmIdle)).Count 'a failure is empty, not an exception'
    $global:CostResponder = $saved
}
Test-That 'step-ups are tiered as not-a-saving' {
    $map = @{ 'r1' = [PSCustomObject]@{ Days = @(0..13 | ForEach-Object { [PSCustomObject]@{ Date = "d$_"; Usd = $(if ($_ -lt 7) { 10 } else { 30 }) } }); AvgDaily = 20; TotalDays = 14 } }
    $f = @(Find-CostStepUp -CostMap $map)
    Assert-Equal 1 $f.Count 'detected'
    Assert-Equal 'not-a-saving' $f[0].Tier 'never counted as a saving'
    Assert-Equal 608.0 $f[0].EstMonthlySavingsUsd 'the sustained monthly delta is still reported'
}
Test-That 'orphans are certain' {
    Reset-State
    $disk = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/disks/d1"
    $global:RestResponder = { param($m, $u, $b) [PSCustomObject]@{ data = @([PSCustomObject]@{ id = $disk; type = 'microsoft.compute/disks'; name = 'd1'; location = 'westeurope'; sku = 'Premium_LRS' }) } }
    $f = @(Get-OrphanedResources -CostMap @{ $disk = [PSCustomObject]@{ AvgDaily = 1.5 } } -MgmtToken 't' -SubscriptionIds @($sub))
    Assert-Equal 'certain' $f[0].Tier 'tier'
    Assert-Equal 45.6 $f[0].EstMonthlySavingsUsd 'its own measured cost'
}
Test-That 'savings timer: tiers stored, realised settles only when the cost falls, and only once' {
    Reset-State
    $diskGone = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/disks/gone"
    $diskKept = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/disks/kept"
    $idGone = Get-ShortHash -Value "orphaned|$diskGone"
    $idKept = Get-ShortHash -Value "orphaned|$diskKept"
    # Both were marked done at 100/mo. Tonight 'gone' is no longer reported; 'kept' still is.
    Set-TableEntity -Table 'SavingsStatus' -Entity @{ PartitionKey = 'status'; RowKey = $idGone; Status = 'done'; AmountAtStatusUsd = 100.0 }
    Set-TableEntity -Table 'SavingsStatus' -Entity @{ PartitionKey = 'status'; RowKey = $idKept; Status = 'done'; AmountAtStatusUsd = 100.0 }

    function global:Get-OrphanedResources { param($CostMap, $MgmtToken, $SubscriptionIds)
        @([PSCustomObject]@{ Category = 'orphaned'; ResourceId = $diskKept; ResourceType = 'microsoft.compute/disks'; Sku = ''; Location = ''
            Title = 'Unattached managed disk'; Detail = 'x'; EstMonthlySavingsUsd = 95.0; Confidence = 'high'; Tier = 'certain'; Evidence = @{} }) }
    function global:Get-LowUtilizationVms { param($CostMap, $MgmtToken, $SubscriptionIds, $WindowStart, $WindowEnd, $MaxVms, $CoveredResourceIds)
        @([PSCustomObject]@{ Category = 'low-utilization'; ResourceId = $vmIdle; ResourceType = 'microsoft.compute/virtualmachines'; Sku = ''; Location = ''
            Title = 'Resize'; Detail = 'x'; EstMonthlySavingsUsd = 0.0; Confidence = 'low'; Tier = 'indicative'; Evidence = @{} }) }
    function global:Get-CommitmentCoveredResources { param($SubscriptionId, $MgmtToken, $ResourceIds, $Days, $CostType) @() }
    function global:Get-AccessibleSubscriptions { param($MgmtToken) @([PSCustomObject]@{ Id = $sub; Name = 'Production' }) }

    $timer = Join-Path $fa 'DetectSavings-Timer/run.ps1'
    & $timer -Timer $null *> $null

    $findings = @($global:Store['SavingsFindings'].Values | Where-Object { $_.PartitionKey -eq 'savings' })
    Assert-Equal 'certain' (@($findings | Where-Object Category -eq 'orphaned')[0].Tier) 'orphan tier stored'
    Assert-Equal 'indicative' (@($findings | Where-Object Category -eq 'low-utilization')[0].Tier) 'indicative tier stored'

    $gone = $global:Store['SavingsStatus']["status|$idGone"]
    $kept = $global:Store['SavingsStatus']["status|$idKept"]
    Assert-Equal 100.0 $gone.RealisedUsd 'vanished finding realised at the amount it had when marked done'
    Assert-True ([bool]$gone.RealisedAt) 'settled'
    Assert-True (-not $kept.RealisedAt) 'still costing 95 of 100: not realised'

    $firstAt = $gone.RealisedAt
    Start-Sleep -Milliseconds 20
    & $timer -Timer $null *> $null
    Assert-Equal $firstAt $global:Store['SavingsStatus']["status|$idGone"].RealisedAt 'settled once; a second run does not move it'
}
Write-Host "`nBilling currency"
Test-That "billing rate is Azure's own ratio from the stored daily totals" {
    Reset-State
    foreach ($i in 1..10) {
        $d = [datetime]::UtcNow.Date.AddDays(-$i).ToString('yyyy-MM-dd')
        Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = $d; TotalUsd = 100.0; TotalBilling = 645.0 + $i; Currency = 'EUR' }
    }
    # A day with no billing figure is ignored rather than dragging the ratio down.
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = [datetime]::UtcNow.Date.AddDays(-11).ToString('yyyy-MM-dd'); TotalUsd = 100.0 }
    $r = Get-BillingCurrencyRate -StorageToken 't'
    Assert-Equal 'EUR' $r.Currency 'currency'
    Assert-Equal 6.505 $r.Rate 'sum(billing) / sum(usd) = 6505 / 1000'
    Assert-Equal 10 $r.Days 'days used'
}
Test-That 'no single billing currency -> no rate' {
    Reset-State
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = [datetime]::UtcNow.Date.AddDays(-1).ToString('yyyy-MM-dd'); TotalUsd = 100.0; TotalBilling = 645.0; Currency = 'EUR' }
    Set-TableEntity -Table 'CostSummary' -Entity @{ PartitionKey = 'dailytotal'; RowKey = [datetime]::UtcNow.Date.AddDays(-2).ToString('yyyy-MM-dd'); TotalUsd = 100.0; TotalBilling = 86.0; Currency = 'GBP' }
    Assert-True ($null -eq (Get-BillingCurrencyRate -StorageToken 't')) 'mixed currencies'
    Reset-State
    Assert-True ($null -eq (Get-BillingCurrencyRate -StorageToken 't')) 'nothing stored yet'
}

Write-Host "`nRemoved rewording, audit"
Test-That 'savings and Advisor timers make no AI calls' {
    foreach ($f in @('DetectSavings-Timer', 'SyncAdvisor-Timer')) {
        $src = Get-Content (Join-Path $fa "$f/run.ps1") -Raw
        Assert-True ($src -notmatch 'Invoke-AiCompletion') "$f has no AI call"
    }
    Assert-True (-not (Get-Command Get-SavingsNarrationSystemPrompt -ErrorAction SilentlyContinue)) 'savings prompt removed'
}
Test-That 'audit writes never throw' {
    Reset-State
    $global:FailTableWrites = $true
    Write-AuditEntry -Caller ([PSCustomObject]@{ Upn = 'a@b.c' }) -Action 'Test' -StorageToken 't'
    $global:FailTableWrites = $false
    Write-AuditEntry -Caller ([PSCustomObject]@{ Upn = 'a@b.c' }) -Action 'Test' -Target 'x' -Details @{ n = 1 } -StorageToken 't'
    $row = @($global:Store['AuditLog'].Values)[0]
    Assert-Equal 'Test' $row.Action 'action'; Assert-Equal '{"n":1}' $row.Details 'details json'
}

Write-Host "`nAI authentication"
Test-That 'managed identity: Bearer token for Azure OpenAI, no api-key, no key needed' {
    Reset-State
    $env:AI_ENDPOINT = 'https://foundry-test.services.ai.azure.com'; $env:AI_MODEL = 'gpt-4o-mini'
    $env:AI_API_KEY = ''; $env:AI_AUTH_MODE = 'managedIdentity'
    try {
        Assert-True (Test-AiConfigured) 'configured without a key'
        $global:AiResponder = { param($b) New-ChatResponse @{ ok = $true } }
        $null = Invoke-AiCompletion -System 's' -User 'u' -Purpose 'test'
        $h = $global:WebCalls[-1].Headers
        Assert-Equal 'Bearer test-token' $h['Authorization'] 'bearer header'
        Assert-True (-not $h.ContainsKey('api-key')) 'no api-key header'
    } finally { $env:AI_AUTH_MODE = '' }
}
Test-That 'a model that refuses reasoning_effort with tools gets it as none, and keeps it' {
    $shape = @{ TokenParam = 'max_completion_tokens'; SendTemperature = $false; ReasoningEffort = 'low'; EffortRejected = $false; TokenBudget = 8000 }
    $err = "AI provider returned HTTP 400: Function tools with reasoning_effort are not supported for gpt-x in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."
    $changed = & (Get-Module AiAdapter) { param($s, $e) Update-OpenAiRequestShape -Shape $s -ErrorRecord $e } $shape $err
    Assert-True $changed 'retried'
    Assert-Equal 'none' $shape.ReasoningEffort 'sent as none, not dropped'
    # The same message again must not loop: nothing left to change.
    $again = & (Get-Module AiAdapter) { param($s, $e) Update-OpenAiRequestShape -Shape $s -ErrorRecord $e } $shape $err
    Assert-True (-not $again) 'no endless retry'
    # A later max_completion_tokens hint must not reset it to minimal.
    $shape.TokenParam = 'max_tokens'
    $null = & (Get-Module AiAdapter) { param($s) Update-OpenAiRequestShape -Shape $s -ErrorRecord "AI provider returned HTTP 400: use 'max_completion_tokens' instead" } $shape
    Assert-Equal 'none' $shape.ReasoningEffort 'still none'
}
Test-That 'managed identity is refused for a non-Azure endpoint' {
    Reset-State
    $env:AI_AUTH_MODE = 'managedIdentity'
    try {
        $threw = $false
        try { $null = Get-AiAuthHeaders -Provider 'openai' -Endpoint 'https://api.openai.com/v1' } catch { $threw = $true }
        Assert-True $threw 'throws'
    } finally { $env:AI_AUTH_MODE = '' }
}
Test-That 'api key mode: configured only with a key; Azure endpoint uses api-key header' {
    Reset-State
    Assert-True (Test-AiConfigured) 'key set'
    $env:AI_API_KEY = ''
    Assert-True (-not (Test-AiConfigured)) 'no key, no AI'
    $h = Get-AiAuthHeaders -Provider 'openai' -Endpoint 'https://x.openai.azure.com' -ApiKey 'k'
    Assert-Equal 'k' $h['api-key'] 'api-key header'
}

Write-Host ""
Write-Host "AI rework tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
