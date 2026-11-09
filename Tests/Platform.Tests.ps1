# Offline tests for the platform guarantees the rest of the app leans on: filter-injection
# rejection, table paging, the Ask query clamp, PATCH semantics on the settings endpoint,
# streaming cost-map equivalence, and the detection timer's retention pass.
# No Azure: everything goes through the stubs in TestKit.ps1. Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

function New-TablePage { param($Rows, [string]$NextPk, [string]$NextRk)
    $h = @{}
    if ($NextPk) { $h['x-ms-continuation-NextPartitionKey'] = @($NextPk) }
    if ($NextRk) { $h['x-ms-continuation-NextRowKey'] = @($NextRk) }
    return [PSCustomObject]@{ StatusCode = 200; Content = (@{ value = @($Rows) } | ConvertTo-Json -Depth 5); Headers = $h }
}

Write-Host "`nFilter injection"
Test-That 'OData literals double their quotes' {
    Assert-Equal "x'' or RowKey ne ''y" (ConvertTo-ODataLiteral -Value "x' or RowKey ne 'y") 'escaped'
    Assert-Equal '' (ConvertTo-ODataLiteral -Value $null) 'null'
}
Test-That 'ExplainSpike rejects a quote-bearing spikeId or period before touching storage' {
    Reset-State
    foreach ($b in @(
        [PSCustomObject]@{ spikeId = "x' or RowKey ne 'y" }
        [PSCustomObject]@{ spikeId = 'abcdef0123456789'; periodType = 'week'; period = "2026-09' or '1' eq '1" }
        [PSCustomObject]@{ spikeId = 'abcdef012345678' }
    )) {
        $r = Invoke-HttpFunction -Name 'ExplainSpike' -Body $b
        Assert-Equal 400 ([int]$r.StatusCode) "status for $($b | ConvertTo-Json -Compress)"
    }
    Assert-Equal 0 $global:TableReads.Count 'no table reads'
}
Test-That 'ExplainSpike with a valid id reads one point and returns 404 when absent' {
    Reset-State
    $r = Invoke-HttpFunction -Name 'ExplainSpike' -Body ([PSCustomObject]@{ spikeId = 'abcdef0123456789'; periodType = 'month'; period = '2026-08' })
    Assert-Equal 404 ([int]$r.StatusCode) 'not found'
    Assert-Equal "PartitionKey eq 'month|2026-08' and RowKey eq 'abcdef0123456789'" $global:TableReads[0].Filter 'point-read filter'
}
Test-That 'no principal and no public-mode opt-in: every endpoint is closed' {
    Reset-State
    $env:ALLOW_ANONYMOUS_ACCESS = 'false'
    $r = Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ costType = 'ActualCost' })
    Assert-Equal 403 ([int]$r.StatusCode) 'admin endpoint'
    $r = Invoke-HttpFunction -Name 'GetSavings'
    Assert-Equal 403 ([int]$r.StatusCode) 'read endpoint'
    Assert-True (-not $global:Store['PortalConfig']) 'nothing written'
}

Write-Host "`nTable paging"
$global:PageUris = [System.Collections.Generic.List[string]]::new()
$global:TableResponder = {
    param($Method, $Uri)
    $global:PageUris.Add($Uri)
    if ($Uri -notmatch 'NextPartitionKey') { return (New-TablePage -Rows @(@{ RowKey = 'a' }, @{ RowKey = 'b' }) -NextPk 'p 2' -NextRk 'r2') }
    if ($Uri -match 'NextPartitionKey=p%202') { return (New-TablePage -Rows @(@{ RowKey = 'c' }, @{ RowKey = 'd' }) -NextPk 'p3') }
    return (New-TablePage -Rows @(@{ RowKey = 'e' }, @{ RowKey = 'f' }))
}
Test-That 'without -Top every continuation page is followed' {
    $global:PageUris.Clear()
    $rows = @(& $global:Real.GetTableEntities -Table 'CostSpikes' -Filter "PartitionKey eq 'x'" -Token 't')
    Assert-Equal 'a,b,c,d,e,f' (($rows | ForEach-Object RowKey) -join ',') 'rows'
    Assert-Equal 3 $global:PageUris.Count 'requests'
    Assert-True ($global:PageUris[1] -like '*$filter=*&NextPartitionKey=p%202&NextRowKey=r2') "continuation keeps the filter: $($global:PageUris[1])"
    Assert-True ($global:PageUris[2] -like '*NextPartitionKey=p3' -and $global:PageUris[2] -notlike '*NextRowKey*') 'no empty row key'
}
Test-That '-Top stops paging once enough rows are in hand and trims the overshoot' {
    $global:PageUris.Clear()
    $rows = @(& $global:Real.GetTableEntities -Table 'CostSpikes' -Select 'PartitionKey,RowKey' -Top 3 -Token 't')
    Assert-Equal 'a,b,c' (($rows | ForEach-Object RowKey) -join ',') 'rows'
    Assert-Equal 2 $global:PageUris.Count 'requests'
    Assert-True ($global:PageUris[0] -like '*$top=3*') 'top sent'
}
Test-That 'a single entity comes back as one row, not a nested array' {
    $global:TableResponder = { param($Method, $Uri) New-TablePage -Rows @(@{ RowKey = 'only'; CostUsd = 4.5 }) }
    $rows = @(& $global:Real.GetTableEntities -Table 'CostSummary' -Token 't')
    Assert-Equal 1 $rows.Count 'count'
    Assert-Equal 4.5 $rows[0].CostUsd 'property reachable'
}

Write-Host "`nAsk query clamp"
$global:CostResponder = { param($b, $u) New-CostResponse -Columns @('Cost', 'Currency') -Rows @(, @(1.0, 'EUR')) }
function Invoke-Spec { param($Spec)
    $global:CostQueryBodies.Clear()
    $null = Invoke-CostQuery -Spec ([PSCustomObject]$Spec) -MgmtToken 't' -Scope "/subscriptions/$sub" -Interactive
    return $global:CostQueryBodies[0]
}
Test-That 'custom window: reversed, future and over-long ranges are clamped' {
    Reset-State
    $q = Invoke-Spec @{ timeframe = 'Custom'; from = $today.AddDays(30).ToString('yyyy-MM-dd'); to = $today.AddDays(-800).ToString('yyyy-MM-dd') }
    Assert-Equal 'Custom' $q.timeframe 'timeframe'
    Assert-Equal $today.ToString('yyyy-MM-dd') $q.timePeriod.to 'never the future'
    Assert-Equal $today.AddDays(-365).ToString('yyyy-MM-dd') $q.timePeriod.from 'at most a year'
}
Test-That 'custom window without usable dates falls back to month-to-date' {
    $q = Invoke-Spec @{ timeframe = 'Custom'; from = 'yesterday' }
    Assert-Equal 'MonthToDate' $q.timeframe 'fallback'
    Assert-True ($null -eq $q.timePeriod) 'no time period'
}
Test-That 'unknown timeframe, dimensions and granularity are dropped; lists are capped' {
    $vals = 1..30 | ForEach-Object { "v$_" }
    $q = Invoke-Spec @{
        timeframe = 'AllTime'; granularity = 'Hourly'
        groupBy = @('ServiceName', 'Password', 'ResourceGroupName', 'MeterCategory')
        filters = @(
            @{ dimension = 'ServiceName'; values = $vals }
            @{ dimension = 'Nope'; values = @('x') }
            @{ dimension = 'ResourceLocation'; values = @('westeurope') }
            @{ dimension = 'ChargeType'; values = @('Usage') }
            @{ dimension = 'PublisherType'; values = @('Azure') }
        )
    }
    Assert-Equal 'MonthToDate' $q.timeframe 'timeframe'
    Assert-Equal 'None' $q.dataset.granularity 'granularity'
    Assert-Equal 'ServiceName,ResourceGroupName' (($q.dataset.grouping | ForEach-Object name) -join ',') 'two allowed groupings'
    $and = @($q.dataset.filter.and)
    Assert-Equal 3 $and.Count 'three filters'
    Assert-Equal 'ServiceName,ResourceLocation,ChargeType' (($and | ForEach-Object { $_.dimensions.name }) -join ',') 'allowed filters, in order'
    Assert-Equal 20 @($and[0].dimensions.values).Count 'values capped'
}

Write-Host "`nSettings are a PATCH"
function Get-StoredSettings { $global:Store['PortalConfig']['settings|current'] }
Test-That 'a partial POST changes only what it names' {
    Reset-State
    Set-Setting @{ MinDeltaUsd = 25.0; MinDeltaPct = 50.0; BaselineDays = 14; SnapshotRetentionDays = 365; CostType = 'AmortizedCost'; AiDailyCallLimit = 200; WeekMinDeltaUsd = 150.0 }
    $r = Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ costType = 'ActualCost' })
    Assert-Equal 200 ([int]$r.StatusCode) 'status'
    $s = Get-StoredSettings
    Assert-Equal 'ActualCost' $s.CostType 'changed'
    Assert-Equal 25.0 $s.MinDeltaUsd 'min delta kept'; Assert-Equal 14 $s.BaselineDays 'baseline kept'
    Assert-Equal 365 $s.SnapshotRetentionDays 'retention kept'; Assert-Equal 200 $s.AiDailyCallLimit 'AI limit kept'
    Assert-Equal 150.0 $s.WeekMinDeltaUsd 'period threshold kept'
    Assert-Equal 'CostType' ((($r.Body | ConvertFrom-Json).changed) -join ',') 'echo lists only the change'
    $audit = @($global:Store['AuditLog'].Values)
    Assert-Equal 1 $audit.Count 'audited'
}
Test-That 'zero is a value, not an omission' {
    $r = Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ aiDailyCallLimit = 0; snapshotRetentionDays = 0 })
    Assert-Equal 200 ([int]$r.StatusCode) 'status'
    Assert-Equal 0 (Get-StoredSettings).AiDailyCallLimit 'AI off stored'
    Assert-Equal 0 (Get-StoredSettings).SnapshotRetentionDays 'never prune stored'
}
Test-That 'one invalid field rejects the whole request and writes nothing' {
    $before = ((Get-StoredSettings) | ConvertTo-Json -Compress)
    foreach ($b in @(
        [PSCustomObject]@{ costType = 'ActualCost'; baselineDays = 1 }
        [PSCustomObject]@{ snapshotRetentionDays = 30 }
        [PSCustomObject]@{ aiDailyCallLimit = 'lots' }
        [PSCustomObject]@{ monthMinDeltaPct = -1 }
        [PSCustomObject]@{ costType = 'Invoice' }
    )) {
        $r = Invoke-HttpFunction -Name 'SavePortalConfig' -Body $b
        Assert-Equal 400 ([int]$r.StatusCode) "status for $($b | ConvertTo-Json -Compress)"
    }
    Assert-Equal $before ((Get-StoredSettings) | ConvertTo-Json -Compress) 'settings unchanged'
}
Test-That 'secrets are refused' {
    $r = Invoke-HttpFunction -Name 'SavePortalConfig' -Body ([PSCustomObject]@{ aiApiKey = 'sk-123' })
    Assert-Equal 400 ([int]$r.StatusCode) 'status'
    Assert-True (-not (Get-StoredSettings).ContainsKey('aiApiKey')) 'not stored'
}

Write-Host "`nStreaming cost map"
Test-That 'day-by-day accumulation equals the one-shot map' {
    $rows = foreach ($d in 1..5) {
        foreach ($id in @('/r/a', '/r/b', '')) {
            [PSCustomObject]@{ Date = "2026-09-0$d"; ResourceId = $id; CostUsd = ($d * 1.5); Scope = 's1'; Meter = 'm' }
        }
    }
    # A resource that only exists on some days, with two rows on one day.
    $rows = @($rows) + @([PSCustomObject]@{ Date = '2026-09-02'; ResourceId = '/r/c'; CostUsd = 2.0; Scope = 's2'; Meter = 'n' },
                         [PSCustomObject]@{ Date = '2026-09-02'; ResourceId = '/r/c'; CostUsd = 1.0; Scope = 's2'; Meter = 'n' })
    $oneShot = Get-ResourceCostMap -Rows $rows
    $acc = @{}
    foreach ($g in ($rows | Group-Object Date)) { Add-ResourceCostRows -Accumulator $acc -Rows $g.Group -Date $g.Name }
    $streamed = Complete-ResourceCostMap -Accumulator $acc
    Assert-Equal 3 $oneShot.Count 'blank resource ids skipped'
    foreach ($id in $oneShot.Keys) {
        Assert-Equal ($oneShot[$id] | ConvertTo-Json -Depth 5 -Compress) ($streamed[$id] | ConvertTo-Json -Depth 5 -Compress) "map entry $id"
    }
    Assert-Equal 3.0 $oneShot['/r/c'].Days[0].Usd 'same-day rows summed'
    Assert-Equal 4.5 $oneShot['/r/a'].AvgDaily 'average'
}
Test-That 'the queried day wins over the row''s own Date field' {
    $acc = @{}
    Add-ResourceCostRows -Accumulator $acc -Rows @([PSCustomObject]@{ Date = 'garbage'; ResourceId = '/r/a'; CostUsd = 1.0 }) -Date '2026-09-03'
    Assert-Equal '2026-09-03' (Complete-ResourceCostMap -Accumulator $acc)['/r/a'].Days[0].Date 'date'
    Assert-Equal 0 (Complete-ResourceCostMap -Accumulator $null).Count 'null accumulator'
}

Write-Host "`nDetection retention"
function global:Wait-ForIngestCompletion { param($Token, $MaxWaitMinutes, $PollSeconds) [PSCustomObject]@{ Complete = $true; Reported = $true; Reason = 'stub' } }
function global:Get-AccessibleSubscriptions { param($MgmtToken) @([PSCustomObject]@{ Id = $sub; Name = 'Production' }) }
function global:Resolve-ResourceDisplayNames { param($ResourceIds, $MgmtToken) @{} }
function global:Remove-TableEntityBatch {
    param($Table, $Entities, $Token)
    $n = 0
    foreach ($e in @($Entities)) { if ($global:Store[$Table].Remove("$($e.PartitionKey)|$($e.RowKey)") -ne $false) { $n++ } }
    return $n
}
Test-That 'old findings, markers and rollups go; recent and unrecognised keys stay' {
    Reset-State
    $env:AI_API_KEY = ''
    $oldWeek = $today.AddDays(-900).ToString('yyyy-MM-dd'); $newWeek = $today.AddDays(-9).ToString('yyyy-MM-dd')
    $oldMonth = $today.AddMonths(-30).ToString('yyyy-MM'); $newMonth = $today.AddMonths(-2).ToString('yyyy-MM')
    $keep = @("week|$newWeek", "month|$newMonth", 'week|2019-W03-legacy', 'custom|anything')
    $drop = @("week|$oldWeek", "month|$oldMonth", 'week|2023-W05')
    foreach ($pk in $keep + $drop) {
        Set-TableEntity -Table 'CostSpikes' -Entity @{ PartitionKey = $pk; RowKey = 'abcdef0123456789'; PeriodType = ($pk -split '\|')[0] }
        Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'analyzed'; RowKey = $pk; At = 'x' }
    }
    # Rollups: one month past the 180-day window, one inside it; both have their markers.
    $staleRollup = $today.AddMonths(-9).ToString('yyyy-MM'); $liveRollup = $today.AddMonths(-3).ToString('yyyy-MM')
    foreach ($m in @($staleRollup, $liveRollup)) {
        Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'rollup'; RowKey = "month|$m"; Period = $m }
        foreach ($i in 1..3) { Set-TableEntity -Table 'CostPeriods' -Entity @{ PartitionKey = "month|$m"; RowKey = "r$i"; CostUsd = 1.0 } }
    }

    & (Join-Path $fa 'DetectCostSpikes-Timer/run.ps1') -Timer $null *> $null

    $spikeParts = @($global:Store['CostSpikes'].Values | ForEach-Object PartitionKey)
    foreach ($pk in $keep) { Assert-True ($spikeParts -contains $pk) "finding kept: $pk" }
    foreach ($pk in $drop) { Assert-True ($spikeParts -notcontains $pk) "finding dropped: $pk" }
    $markers = @($global:Store['PortalConfig'].Values | Where-Object PartitionKey -eq 'analyzed' | ForEach-Object RowKey)
    foreach ($pk in $keep) { Assert-True ($markers -contains $pk) "marker kept: $pk" }
    foreach ($pk in $drop) { Assert-True ($markers -notcontains $pk) "marker dropped: $pk" }
    $periods = @($global:Store['CostPeriods'].Values | ForEach-Object PartitionKey)
    Assert-Equal 0 @($periods | Where-Object { $_ -eq "month|$staleRollup" }).Count 'stale rollup rows gone'
    Assert-Equal 3 @($periods | Where-Object { $_ -eq "month|$liveRollup" }).Count 'live rollup rows kept'
    Assert-True ($global:Store['PortalConfig'].ContainsKey("rollup|month|$staleRollup")) 'rollup marker itself is never pruned'
}
Test-That 'a longer snapshot retention keeps older rollups' {
    Set-Setting @{ SnapshotRetentionDays = 400 }
    $m = $today.AddMonths(-10).ToString('yyyy-MM')
    Set-TableEntity -Table 'PortalConfig' -Entity @{ PartitionKey = 'rollup'; RowKey = "month|$m"; Period = $m }
    Set-TableEntity -Table 'CostPeriods' -Entity @{ PartitionKey = "month|$m"; RowKey = 'r1'; CostUsd = 1.0 }
    & (Join-Path $fa 'DetectCostSpikes-Timer/run.ps1') -Timer $null *> $null
    Assert-True ($global:Store['CostPeriods'].ContainsKey("month|$m|r1")) 'kept under a 400-day retention'
}

Write-Host "`nSource hygiene"
Test-That 'no control characters in source files (a \b written as a backspace silently breaks a regex)' {
    $bad = @(Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'Setup'), (Join-Path $root 'Tests'), (Join-Path $root 'azResources') -Recurse -File -Include *.ps1, *.psm1, *.ts, *.tsx, *.bicep, *.json, *.mjs, *.css |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|dist)[\\/]' } |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -match '[\x00-\x08\x0B\x0C\x0E-\x1F]' } | ForEach-Object { $_.Name })
    $bad += @(Get-Item (Join-Path $root 'deploy.ps1') | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '[\x00-\x08\x0B\x0C\x0E-\x1F]' } | ForEach-Object { $_.Name })
    Assert-Equal '' ($bad -join ', ') 'files with control characters'
}
Test-That 'deploy.ps1 passes -Language to the template (it finds the portalLanguage parameter)' {
    $deploy = Get-Content (Join-Path $root 'deploy.ps1') -Raw
    $m = [regex]::Match($deploy, "-match '(\(\?m\)\^param portalLanguage[^']*)'")
    Assert-True $m.Success 'the check is there'
    Assert-True ((Get-Content (Join-Path $root 'azResources/main.bicep') -Raw) -match $m.Groups[1].Value) 'and it matches main.bicep'
}

Write-Host ""
Write-Host "Platform tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
