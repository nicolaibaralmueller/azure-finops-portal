# Offline tests for the within-period shape of monthly findings: an increase that fell back
# before the month ended (a Defender plan switched off on the 12th) must be recognised as such,
# and the month rollup must not put a resource's whole month under its first day's meter label.
# Run via Tests/Invoke-OfflineTests.ps1.

param([switch]$PassThru)

. (Join-Path $PSScriptRoot 'TestKit.ps1')

$sub1 = '11111111-2222-3333-4444-555555555555'
$vm = "/subscriptions/$sub1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1"

# October 2026: 12 days at 90/day (Defender on), then 6/day.
$october = [double[]]@(@(1..12 | ForEach-Object { 90.0 }) + @(13..31 | ForEach-Object { 6.0 }))

Test-That 'step down mid-month: exit run-rate is the end level, step day found' {
    $m = Measure-ExitRunRate -Daily $october
    Assert-Equal 6.0 $m.ExitDailyUsd 'exit daily'
    Assert-Equal 186.0 $m.ExitRunRateUsd 'exit run-rate (6 x 31)'
    Assert-Equal 12 $m.StepDownIndex 'step index (day 13)'
    Assert-Equal 90.0 $m.BeforeDailyUsd 'before'
    Assert-Equal 6.0 $m.AfterDailyUsd 'after'
}

Test-That 'flat month: no step, exit equals the average' {
    $m = Measure-ExitRunRate -Daily ([double[]]@(1..30 | ForEach-Object { 20.0 }))
    Assert-Equal 600.0 $m.ExitRunRateUsd 'exit run-rate'
    Assert-True ($null -eq $m.StepDownIndex) 'no step down'
}

Test-That 'late step UP: no step down, exit run-rate above the total' {
    $d = [double[]]@(@(1..24 | ForEach-Object { 10.0 }) + @(25..31 | ForEach-Object { 50.0 }))
    $m = Measure-ExitRunRate -Daily $d
    Assert-True ($null -eq $m.StepDownIndex) 'no step down'
    Assert-Equal 1550.0 $m.ExitRunRateUsd 'exit run-rate (50 x 31)'
}

Test-That 'resolved: month total flagged, month-end level is not' {
    # Typical month 470 (a partial earlier month); October total 1194.
    $total = ($october | Measure-Object -Sum).Sum
    $spike = @(Find-CostSpike -Current @([PSCustomObject]@{ Date = '2026-10'; DimensionKey = 'k'; Scope = $sub1; ResourceId = ''; Meter = 'Microsoft Defender for Cloud'; CostUsd = $total }) `
        -Baseline @{ k = 470.0 } -MinDeltaUsd 500 -MinDeltaPct 15 -Dimension 'meter')
    Assert-Equal 1 $spike.Count 'the month total is still a finding'
    $m = Measure-ExitRunRate -Daily $october
    Assert-True (Test-ExitRunRateResolved -ExitRunRateUsd $m.ExitRunRateUsd -BaselineUsd 470 -MinDeltaUsd 500 -MinDeltaPct 15) 'resolved'
}

Test-That 'not resolved: still running high at month end' {
    Assert-True (-not (Test-ExitRunRateResolved -ExitRunRateUsd 2000 -BaselineUsd 470 -MinDeltaUsd 500 -MinDeltaPct 15)) 'open'
    Assert-True (Test-ExitRunRateResolved -ExitRunRateUsd 100 -BaselineUsd 0 -MinDeltaUsd 500 -MinDeltaPct 15) 'new spend that stopped'
}

Test-That 'finding state: a drop 3 days ago resolves a weekly finding at once' {
    # Typical week 700 (100/day); this window 5 days at 300 then 2 days... the latest 3 days at 100.
    $week = [double[]]@(300, 300, 300, 300, 100, 100, 100)
    $total = ($week | Measure-Object -Sum).Sum   # 1500: still a finding for the window
    $recent = ($week[4..6] | Measure-Object -Average).Average
    Assert-Equal 'resolved' (Get-FindingState -RecentDailyUsd $recent -PeriodDays 7 -BaselineUsd 700 -SpikeUsd $total -MinDeltaUsd 150 -MinDeltaPct 25) 'resolved'
    $m = Measure-ExitRunRate -Daily $week -TailDays 3 -MinSegmentDays 2
    Assert-Equal 4 $m.StepDownIndex 'stepped down on day 5'
}

Test-That 'finding state: falling but still above the bar is decreasing; flat is open' {
    # Typical 700/week; window 2100 (300/day); recent 200/day = 1400/week — still +100%, but 2/3 of the window's average.
    Assert-Equal 'decreasing' (Get-FindingState -RecentDailyUsd 200 -PeriodDays 7 -BaselineUsd 700 -SpikeUsd 2100 -MinDeltaUsd 150 -MinDeltaPct 25) 'decreasing'
    Assert-Equal 'open' (Get-FindingState -RecentDailyUsd 300 -PeriodDays 7 -BaselineUsd 700 -SpikeUsd 2100 -MinDeltaUsd 150 -MinDeltaPct 25) 'open'
    Assert-Equal 'open' (Get-FindingState -RecentDailyUsd $null -PeriodDays 7 -BaselineUsd 700 -SpikeUsd 2100) 'unknown level stays open'
    Assert-Equal 'resolved' (Get-FindingState -RecentDailyUsd 0 -PeriodDays 31 -BaselineUsd 0 -SpikeUsd 900 -MinDeltaUsd 500 -MinDeltaPct 15) 'new spend that stopped'
}

Test-That 'finding state: a closed month fixed after it ended resolves from the days after it' {
    # October ran at 40/day all month (1240 vs typical 470). Fixed on 3 Nov; 6-8 Nov at 15/day.
    Assert-Equal 'resolved' (Get-FindingState -RecentDailyUsd 15 -PeriodDays 31 -BaselineUsd 470 -SpikeUsd 1240 -MinDeltaUsd 500 -MinDeltaPct 15) 'resolved'
}

Test-That 'creation period: a started-and-running key gets its span; gaps or a full period get 0' {
    $masks = @{}
    foreach ($i in 11..30) { Add-ActiveDay -Masks $masks -Key 'vm' -DayIndex $i }          # created on the 12th of a 31-day month
    Assert-Equal 20 (Get-StartedSpanDays -Mask $masks['vm'] -DayCount 31) 'created the 12th: 20 days'
    foreach ($i in @(2, 9, 16, 23, 30)) { Add-ActiveDay -Masks $masks -Key 'batch' -DayIndex $i }
    Assert-Equal 0 (Get-StartedSpanDays -Mask $masks['batch'] -DayCount 31) 'an intermittent job is not a creation period'
    foreach ($i in 0..30) { Add-ActiveDay -Masks $masks -Key 'full' -DayIndex $i }
    Assert-Equal 0 (Get-StartedSpanDays -Mask $masks['full'] -DayCount 31) 'a whole month is not'
    foreach ($i in 5..20) { Add-ActiveDay -Masks $masks -Key 'deleted' -DayIndex $i }
    Assert-Equal 0 (Get-StartedSpanDays -Mask $masks['deleted'] -DayCount 31) 'one that stopped before the end is not'
}

Test-That 'creation period in the baseline: scaled to a whole period; a 1-day start is left out' {
    # Created 12 Oct at 10/day, jumped to 100/day on 26 Oct. November (30 days) runs at 100/day.
    $vmId = "/subscriptions/$sub1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/new"
    $base = @([PSCustomObject]@{ Date = '2026-10'; DimensionKey = $vmId; Scope = $sub1; ResourceId = $vmId; Meter = 'Virtual Machines'
        CostUsd = (14 * 10 + 6 * 100); ResSpanDays = 20; MeterSpanDays = 0; SubSpanDays = 0 })
    $old = Measure-DimensionBaseline -Rows $base -Dimension 'resource'
    Assert-Equal 740.0 $old[$vmId] 'unscaled: the half month counts as a cheap month'
    $new = Measure-DimensionBaseline -Rows $base -Dimension 'resource' -ScaleStartedTo 30
    Assert-Equal 1110.0 $new[$vmId] 'scaled: 740 / 20 days x 30'
    $nov = @([PSCustomObject]@{ Date = '2026-11'; DimensionKey = $vmId; Scope = $sub1; ResourceId = $vmId; Meter = 'Virtual Machines'; CostUsd = 3000.0 })
    $cur = Measure-DailyDimensionCost -Rows $nov -Dimension 'resource'
    $f = @(Find-CostSpike -Current $cur -Baseline $new -MinDeltaUsd 500 -MinDeltaPct 15)
    Assert-Equal 170.3 ([Math]::Round($f[0].DeltaPct, 1)) 'November +170%, not +305% against the half month'

    # Weekly: a window the resource only existed in for its last day is left out.
    $w = @(
        [PSCustomObject]@{ Date = '2026-10-12'; DimensionKey = $vmId; Scope = $sub1; ResourceId = $vmId; Meter = 'VM'; CostUsd = 4.0; ResSpanDays = 1 }
        [PSCustomObject]@{ Date = '2026-10-19'; DimensionKey = $vmId; Scope = $sub1; ResourceId = $vmId; Meter = 'VM'; CostUsd = 70.0; ResSpanDays = 0 }
        [PSCustomObject]@{ Date = '2026-10-26'; DimensionKey = $vmId; Scope = $sub1; ResourceId = $vmId; Meter = 'VM'; CostUsd = 160.0; ResSpanDays = 0 })
    $b = Measure-DimensionBaseline -Rows $w -Dimension 'resource' -ScaleStartedTo 7
    Assert-Equal 115.0 $b[$vmId] 'median of the two real weeks, not of a 4-dollar day'
    Assert-Equal 2 (Measure-BaselineCoverage -Rows $w -Dimension 'resource' -MinStartedSpan 3)[$vmId] 'coverage skips it too'

    # An intermittent job keeps its real monthly cost.
    $batch = @([PSCustomObject]@{ Date = '2026-10'; DimensionKey = 'b'; Scope = $sub1; ResourceId = 'b'; Meter = 'x'; CostUsd = 500.0; ResSpanDays = 0 })
    Assert-Equal 500.0 (Measure-DimensionBaseline -Rows $batch -Dimension 'resource' -ScaleStartedTo 31)['b'] 'not scaled'
}

Test-That 'cost fall: measured from the step down, since its day; else against the period average' {
    $f = Get-CostFall -CurrentDailyUsd 201 -BeforeDailyUsd 349 -SteppedDownOn '2026-10-20' -SpikeUsd 10815 -PeriodDays 31
    Assert-Equal -42.4 $f.Pct 'fall % from the level before the step'
    Assert-Equal '2026-10-20' $f.Since 'since the step day'
    $f = Get-CostFall -CurrentDailyUsd 100 -BeforeDailyUsd $null -SteppedDownOn '' -SpikeUsd 2100 -PeriodDays 7
    Assert-Equal -66.7 $f.Pct 'against the average day (300)'
    Assert-Equal '' $f.Since 'no date without a step'
    Assert-True ($null -eq (Get-CostFall -CurrentDailyUsd 400 -BeforeDailyUsd 349 -SteppedDownOn '2026-10-20')) 'no fall when higher'
    Assert-True ($null -eq (Get-CostFall -CurrentDailyUsd $null -SpikeUsd 2100 -PeriodDays 7)) 'unknown level'
}

Test-That 'daily series: one day of rows feeds resource, meter and subscription keys' {
    $series = @{}
    $wanted = @{ $vm = $true; "meter:$sub1|Microsoft Defender for Cloud" = $true; "sub:$sub1" = $true }
    Add-DailySeriesRows -Series $series -Wanted $wanted -DayIndex 0 -DayCount 3 -Rows @(
        [PSCustomObject]@{ DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Microsoft Defender for Cloud'; CostUsd = 90.0 })
    Add-DailySeriesRows -Series $series -Wanted $wanted -DayIndex 2 -DayCount 3 -Rows @(
        [PSCustomObject]@{ DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Virtual Machines'; CostUsd = 6.0 })
    Assert-Equal '90 0 6' ($series[$vm] -join ' ') 'resource series'
    Assert-Equal '90 0 0' ($series["meter:$sub1|Microsoft Defender for Cloud"] -join ' ') 'meter series follows the day label'
    Assert-Equal '90 0 6' ($series["sub:$sub1"] -join ' ') 'subscription series'
}

Test-That 'baseline coverage: months a key appeared in' {
    $rows = @(
        [PSCustomObject]@{ Date = '2026-09'; DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Microsoft Defender for Cloud'; CostUsd = 470 }
        [PSCustomObject]@{ Date = '2026-08'; DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Virtual Machines'; CostUsd = 180 }
        [PSCustomObject]@{ Date = '2026-07'; DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Virtual Machines'; CostUsd = 180 }
    )
    $cov = Measure-BaselineCoverage -Rows $rows -Dimension 'meter'
    Assert-Equal 1 $cov["meter:$sub1|Microsoft Defender for Cloud"] 'Defender in 1 month'
    Assert-Equal 2 $cov["meter:$sub1|Virtual Machines"] 'VMs in 2 months'
    Assert-Equal 3 (Measure-BaselineCoverage -Rows $rows -Dimension 'resource')[$vm] 'resource in 3'
}

Test-That 'rollup rows per (resource, meter): each label keeps its own cost, resource label is the larger' {
    # What Update-PeriodRollup now writes for a VM relabelled mid-month.
    $rows = @(
        [PSCustomObject]@{ Date = '2026-10'; DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Microsoft Defender for Cloud'; CostUsd = 1080 }
        [PSCustomObject]@{ Date = '2026-10'; DimensionKey = $vm; Scope = $sub1; ResourceId = $vm; Meter = 'Virtual Machines'; CostUsd = 114 }
    )
    $meter = @(Measure-DailyDimensionCost -Rows $rows -Dimension 'meter')
    Assert-Equal 1080.0 (@($meter | Where-Object { $_.Meter -eq 'Microsoft Defender for Cloud' })[0].CostUsd) 'Defender rollup'
    Assert-Equal 114.0 (@($meter | Where-Object { $_.Meter -eq 'Virtual Machines' })[0].CostUsd) 'VM rollup'
    $res = @(Measure-DailyDimensionCost -Rows ([object[]]@($rows[1], $rows[0])) -Dimension 'resource')
    Assert-Equal 1 $res.Count 'one resource'
    Assert-Equal 1194.0 $res[0].CostUsd 'resource total'
    Assert-Equal 'Microsoft Defender for Cloud' $res[0].Meter 'label = largest meter'
}

Test-That 'evidence: daily-shape fact is added once and replaced, payload carries the end level' {
    $ev = [PSCustomObject]@{ facts = @([PSCustomObject]@{ id = 'F1'; kind = 'driver' }) }
    $f = [PSCustomObject]@{ ExitRunRateUsd = 186.0; SteppedDownOn = '2026-10-13'; DailyBeforeUsd = 90.0; DailyAfterUsd = 6.0; Resolved = $true
        PeriodType = 'month'; Dimension = 'meter'; Meter = 'Microsoft Defender for Cloud'; SpikeUsd = 1194; BaselineUsd = 470; DeltaUsd = 724; DeltaPct = 154; IsNew = $false }
    Set-EvidenceDailyShape -Evidence $ev -Finding $f
    Set-EvidenceDailyShape -Evidence $ev -Finding $f
    $shape = @($ev.facts | Where-Object { $_.kind -eq 'daily-shape' })
    Assert-Equal 1 $shape.Count 'one shape fact'
    Assert-Equal 'F2' $shape[0].id 'id'
    Assert-Equal '2026-10-13' $shape[0].steppedDownOn 'step day'
    Assert-True $shape[0].resolved 'resolved'
    $p = Build-CostChangePayload -Finding $f -Evidence ([PSCustomObject]@{ currentStart = '2026-10-01'; currentEnd = '2026-10-31'; basis = ''; complete = $true; notes = @(); facts = $ev.facts })
    Assert-True $p.change.already_fell_back 'payload flag'
    Assert-Equal '2026-10-13' $p.change.fell_on 'payload day'
}

Test-That 'evidence: daily-shape fact carries where the finding stands now' {
    $ev = [PSCustomObject]@{ facts = @() }
    $f = [PSCustomObject]@{ ExitRunRateUsd = 186.0; SteppedDownOn = '2026-10-13'; DailyBeforeUsd = 90.0; DailyAfterUsd = 6.0; Resolved = $true
        State = 'resolved'; CurrentDailyUsd = 6.2; CurrentAsOf = '2026-11-08' }
    Set-EvidenceDailyShape -Evidence $ev -Finding $f
    $shape = @($ev.facts)[0]
    Assert-Equal 'resolved' $shape.state 'state'
    Assert-Equal 6.2 $shape.currentDailyUsd 'current level'
    Assert-Equal '2026-11-08' $shape.currentAsOf 'as of'
    $f2 = [PSCustomObject]@{ ExitRunRateUsd = 186.0; SteppedDownOn = ''; Resolved = $false }
    $ev2 = [PSCustomObject]@{ facts = @() }
    Set-EvidenceDailyShape -Evidence $ev2 -Finding $f2
    Assert-True (-not @($ev2.facts)[0].PSObject.Properties['state']) 'no state without a current level'
}

Write-Host ""
Write-Host "Exit run-rate tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
