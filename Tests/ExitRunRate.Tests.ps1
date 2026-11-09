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

Write-Host ""
Write-Host "Exit run-rate tests: $($script:Passed) passed, $($script:Failed.Count) failed" -ForegroundColor $(if ($script:Failed.Count) { 'Red' } else { 'Green' })
if ($PassThru) { return [PSCustomObject]@{ Passed = $script:Passed; Failed = @($script:Failed) } }
if ($script:Failed.Count) { exit 1 }
