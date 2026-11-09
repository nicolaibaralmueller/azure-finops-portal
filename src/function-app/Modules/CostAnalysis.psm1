# ============================================================================
# CostAnalysis.psm1 — the deterministic cost engine.
#
# ALL arithmetic lives here. The AI layer (AiAdapter.psm1) only narrates the
# structured results these functions produce. Keeping the math out of the model is
# what makes the product trustworthy (no hallucinated dollar figures) and cheap
# (tiny token payloads).
#
# Pipeline (see docs/architecture.md), orchestrated by DetectCostSpikes-Timer:
#   2. DETECT    — ConvertTo-DimensionRows + Measure-DailyDimensionCost +
#                  Measure-DimensionBaseline + Find-CostSpike (+ Select-UnexplainedSpike)
#   3. LOCALIZE  — Get-ResourceContext: Resource Graph lookup for a flagged resource
#   4. EVIDENCE  — CostEvidence.psm1 Get-CostChangeEvidence: meter / resource / service
#                  drivers, volume-vs-rate split, recorded changes, new resources, owner
#   5. EXPLAIN   — CostEvidence.psm1 Invoke-CostChangeExplanation: the model explains the
#                  change from that evidence and must cite it
#   6. (verify)  — Test-NarrativeGrounding: soft check that the model invented no numbers
#
# Snapshot row shape (from the CostSnapshots table, written by the cost ingest (CostIngest.psm1)):
#   Date (yyyy-MM-dd) | DimensionKey | Scope | ResourceId | Meter | CostUsd
#
# DIMENSIONS. Detection runs over three re-keyings of the same rows (ConvertTo-DimensionRows):
#   resource      — one resource (DimensionKey = ResourceId). The precise case.
#   meter         — one meter category within one subscription. Catches a spike SPREAD across
#                   many resources (a scale-out, a meter price change) where no single
#                   resource clears the threshold.
#   subscription  — the subscription total. The backstop for diffuse growth.
# Rollup (meter/subscription) spikes are then filtered by Select-UnexplainedSpike so a
# rollup only surfaces when the resource-level spikes do NOT already account for it — the
# same spend is never reported twice.
# ============================================================================

# ----------------------------------------------------------------------------
# Private helpers
# ----------------------------------------------------------------------------

# Median of a numeric set (robust to a single outlier day, unlike the mean).
function Get-Median {
    param($Values)
    $a = @($Values | Sort-Object)
    if (-not $a.Count) { return 0.0 }
    if ($a.Count % 2 -eq 1) { return [double]$a[[int](($a.Count - 1) / 2)] }
    return ([double]$a[$a.Count / 2 - 1] + [double]$a[$a.Count / 2]) / 2
}

# The single definition of a dimension's key. Used both when re-keying rows and when
# working out which rollup a resource-level spike rolls up INTO — the two must agree.
function Get-DimensionKey {
    param([string]$Dimension, [string]$Scope, [string]$Meter, [string]$ResourceId)
    switch ($Dimension) {
        'meter'        { return "meter:$Scope|$Meter" }
        'subscription' { return "sub:$Scope" }
        default        { return $ResourceId }
    }
}

# Stable short id for a spike: hash of date + dimension key.
function Get-SpikeId {
    param([string]$Date, [string]$DimensionKey)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes("$Date|$DimensionKey"))
    return (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
}

# Never send raw identities to the model. Map a UPN to a stable opaque token.
function ConvertTo-PseudonymousActor {
    param([string]$Upn)
    if ([string]::IsNullOrWhiteSpace($Upn)) { return 'unknown' }
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Upn.ToLower()))
    return 'user_' + (-join ($bytes[0..1] | ForEach-Object { $_.ToString('x2') }))
}

# ============================================================================
# PERIODS — the grain detection runs at.
#
# Detection is WEEKLY and MONTHLY, not daily. A one-day spike is an alerting signal: it is
# over before anyone looks, and most of them are batch jobs or billing artefacts. The money
# is in sustained change — a resource that costs more every week than it used to. This is an
# analysis tool, so it reports on settled periods rather than chasing yesterday.
#
# COMPLETE PERIODS ONLY. A period is analysed only once it has ended. Comparing a
# part-finished week or month against a whole one makes everything look like a collapse, and
# it's the most common way period comparisons get built wrong. (The Subscriptions page
# already works this way — it compares the last two complete months and ignores month-to-date.)
#
# Baselines are the MEDIAN of the prior complete periods, so one unusual week or month can't
# both mask a real change and manufacture a fake one the period after.
#
# Data requirement: CostSnapshots retention has to cover the baseline. Monthly needs ~4
# complete months; the cost ingest (CostIngest.psm1) floors the retention accordingly so the prune can
# never delete the baseline out from under the detector.
# ============================================================================

# How many prior COMPLETE periods form the baseline, per grain.
# 4 weeks rather than 8: a 4-week median is still robust to one odd week, and it halves the
# rows a detection pass holds in memory — the B2 plan's 3.5 GB is shared with the portal site.
$script:PeriodBaselineCount = @{ week = 4; month = 3 }

# Days of CostSnapshots the longest detection window needs (month: 3 baseline months + the
# target month + slack for the current partial month). the cost ingest's retention floor
# uses this.
$script:PeriodRetentionFloorDays = 160

# ----------------------------------------------------------------------------
# ROLLING WINDOWS — the short grain.
#
# The weekly view is a TRAILING 7 days, not a calendar week. Calendar weeks are settled and
# comparable, but on a Friday the newest complete week ended the previous Sunday: a change
# starting on Monday waits until the following Monday to appear, up to 7 days late. A rolling
# window is always exactly 7 days long, so it is immune to the partial-period trap that makes
# "complete periods only" necessary for calendar grains, while staying current.
#
# Baseline windows are strictly NON-OVERLAPPING with the current one. If they overlapped, a
# change would leak into its own baseline and mute itself.
#
# Note the trade: a rolling window RAMPS. A change three days old is in the window at 3/7
# strength and grows daily until fully inside, so it can clear the threshold a day or two after
# the change rather than instantly — still far sooner than waiting for a week to close, and the
# signal only ever grows, so it can't flicker.
# ----------------------------------------------------------------------------

# The last day settled enough to analyse. Azure restates recent cost, and the pipeline runs two
# hours after midnight UTC, so the freshest day reads low and would mute a real change. D-2
# trades one day of latency for a figure that doesn't move under you.
$script:RollingSettlingDays = 2

function Get-RollingWindowEndDate {
    param([datetime]$Today = [datetime]::UtcNow.Date)
    return $Today.AddDays(-$script:RollingSettlingDays)
}

# Window 0 is the current trailing period; 1..N-1 are the baseline, each shifted a further
# WindowDays back. Returns objects with Index / Start / End (both inclusive) / Key.
function Get-RollingWindows {
    param(
        [Parameter(Mandatory)][datetime]$EndDate,
        [int]$WindowDays = 7,
        [int]$Count = 5
    )
    $out = foreach ($i in 0..($Count - 1)) {
        $end = $EndDate.AddDays(-1 * $WindowDays * $i)
        [PSCustomObject]@{
            Index = $i
            Start = $end.AddDays(-($WindowDays - 1))
            End   = $end
            Key   = $end.ToString('yyyy-MM-dd')   # the window's last day identifies it
        }
    }
    return @($out)
}

# How many prior complete periods make up the baseline for a grain.
function Get-PeriodBaselineCount {
    param([Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType)
    return [int]$script:PeriodBaselineCount[$PeriodType]
}

# Minimum days of CostSnapshots the detector needs kept. The retention prune floors on this
# so lowering SnapshotRetentionDays can never silently starve monthly detection.
function Get-PeriodRetentionFloorDays { return [int]$script:PeriodRetentionFloorDays }

# Period key for a date. Week keys are ISO-8601 (Monday-start), which is what a European
# business week means and is stable across year boundaries — '2026-W01' is unambiguous where
# 'week 1 of 2026' is not.
function Get-PeriodKey {
    param(
        [Parameter(Mandatory)][datetime]$Date,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType
    )
    if ($PeriodType -eq 'month') { return $Date.ToString('yyyy-MM') }
    $isoYear = [System.Globalization.ISOWeek]::GetYear($Date)
    $isoWeek = [System.Globalization.ISOWeek]::GetWeekOfYear($Date)
    return ('{0:D4}-W{1:D2}' -f $isoYear, $isoWeek)
}

# First and last DAY of a period key. Returns @{ Start; End } as dates (End inclusive).
function Get-PeriodBounds {
    param(
        [Parameter(Mandatory)][string]$PeriodKey,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType
    )
    if ($PeriodType -eq 'month') {
        $start = [datetime]::ParseExact("$PeriodKey-01", 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        return @{ Start = $start; End = $start.AddMonths(1).AddDays(-1) }
    }
    if ($PeriodKey -notmatch '^(\d{4})-W(\d{2})$') { throw "Not a week key: $PeriodKey" }
    $start = [System.Globalization.ISOWeek]::ToDateTime([int]$Matches[1], [int]$Matches[2], [System.DayOfWeek]::Monday)
    return @{ Start = $start; End = $start.AddDays(6) }
}

# First instant of a date's month, in UTC.
#
# Deliberately NOT `Get-Date -Year $d.Year -Month $d.Month -Day 1`, which is what the three
# callers of this used to do. That returns a LOCAL-kinded value carrying the current local
# time-of-day, which then gets mixed into arithmetic with the UtcNow-derived dates the rest of
# the pipeline runs on. It produces the right answer today only because every caller happens to
# discard the time component before use — replaying all three call sites across every UTC day
# from 2024-2027 against every time-of-day shows not one differing output.
#
# It is kept explicit anyway because that safety is accidental, not designed: it survives only
# for as long as nobody keeps the time component, compares against a timestamp, or hands the
# value to something that treats it as an instant. Constructing in UTC costs nothing and means
# the correctness no longer depends on the mistake cancelling out. Don't "simplify" it back.
function Get-UtcMonthStart {
    param([Parameter(Mandatory)][datetime]$Date)
    return [datetime]::new($Date.Year, $Date.Month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
}

# Is the period finished? Only complete periods are analysed.
function Test-PeriodComplete {
    param(
        [Parameter(Mandatory)][string]$PeriodKey,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType,
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    return ((Get-PeriodBounds -PeriodKey $PeriodKey -PeriodType $PeriodType).End -lt $Today)
}

# The complete period keys present in a set of snapshot rows, oldest first.
function Get-CompletePeriodKeys {
    param(
        $Rows,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType,
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    if (-not $Rows) { return @() }
    $seen = @{}
    foreach ($r in $Rows) {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$r.Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
            $seen[(Get-PeriodKey -Date $d -PeriodType $PeriodType)] = $true
        }
    }
    return @($seen.Keys | Where-Object { Test-PeriodComplete -PeriodKey $_ -PeriodType $PeriodType -Today $Today } | Sort-Object)
}

# ----------------------------------------------------------------------------
# ConvertTo-PeriodRows — re-stamp daily snapshot rows onto a period grain by replacing
# Date with the period key. Everything downstream (ConvertTo-DimensionRows,
# Measure-DailyDimensionCost, Measure-DimensionBaseline, Find-CostSpike,
# Select-UnexplainedSpike) buckets on Date and is otherwise grain-agnostic, so the entire
# existing detection pipeline works on periods unchanged — no second implementation to keep
# in sync, and the same unit tests cover both.
# ----------------------------------------------------------------------------
function ConvertTo-PeriodRows {
    param(
        $Rows,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType
    )
    if (-not $Rows) { return @() }
    $out = foreach ($r in $Rows) {
        $d = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$r.Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { continue }
        [PSCustomObject]@{
            Date         = (Get-PeriodKey -Date $d -PeriodType $PeriodType)   # period key, not a day
            DimensionKey = $r.DimensionKey
            Scope        = $r.Scope
            ResourceId   = $r.ResourceId
            Meter        = $r.Meter
            CostUsd      = $r.CostUsd
        }
    }
    return @($out)
}

# ----------------------------------------------------------------------------
# ConvertTo-DimensionRows — STEP 2 (pre). Re-key snapshot rows onto one of the three
# analysis dimensions. Pure. The rows themselves are untouched apart from DimensionKey and
# the labels that no longer apply at that grain (a meter rollup has no single ResourceId).
#   resource     -> DimensionKey = ResourceId                (as ingested)
#   meter        -> DimensionKey = "meter:<subscription>|<meter>"
#   subscription -> DimensionKey = "sub:<subscription>"
# ----------------------------------------------------------------------------
function ConvertTo-DimensionRows {
    param(
        $Rows,
        [ValidateSet('resource', 'meter', 'subscription')][string]$Dimension = 'resource'
    )
    if (-not $Rows) { return @() }
    if ($Dimension -eq 'resource') { return @($Rows) }

    $out = foreach ($r in $Rows) {
        [PSCustomObject]@{
            Date         = $r.Date
            DimensionKey = (Get-DimensionKey -Dimension $Dimension -Scope ([string]$r.Scope) -Meter ([string]$r.Meter) -ResourceId ([string]$r.ResourceId))
            Scope        = $r.Scope
            ResourceId   = ''                                                     # no single resource at this grain
            Meter        = if ($Dimension -eq 'meter') { $r.Meter } else { '' }
            CostUsd      = $r.CostUsd
        }
    }
    return @($out)
}

# ----------------------------------------------------------------------------
# Measure-DailyDimensionCost — STEP 2a. Aggregate one day's raw rows to per-dimension
# totals. Pure; no AI, no I/O. Returns array of { Date, DimensionKey, Scope, ResourceId,
# Meter, CostUsd }.
# ----------------------------------------------------------------------------
# -Dimension re-keys inline instead of requiring ConvertTo-DimensionRows first. That matters
# for memory, not tidiness: the old path built a full re-keyed copy of every row and then
# called Group-Object, which holds all of them again. A detection pass does this for three
# dimensions over several periods, so on a large tenant the copies dominated. This streams
# each row straight into an accumulator — O(distinct keys) memory instead of O(rows).
function Measure-DailyDimensionCost {
    param(
        $Rows,
        [ValidateSet('resource', 'meter', 'subscription')][string]$Dimension = 'resource'
    )
    if (-not $Rows) { return @() }
    $acc = [ordered]@{}
    # Month rollups hold one row per (resource, meter label), so a resource whose largest meter
    # changed during the month has several rows. Its label is the one carrying the most cost.
    $topMeterCost = @{}
    foreach ($r in $Rows) {
        $key = if ($Dimension -eq 'resource') { [string]$r.DimensionKey }
               else { Get-DimensionKey -Dimension $Dimension -Scope ([string]$r.Scope) -Meter ([string]$r.Meter) -ResourceId ([string]$r.ResourceId) }
        if ($Dimension -eq 'resource') {
            if (-not $topMeterCost.ContainsKey($key) -or [double]$r.CostUsd -gt $topMeterCost[$key]) {
                $topMeterCost[$key] = [double]$r.CostUsd
                if ($acc.Contains($key)) { $acc[$key].Meter = $r.Meter }
            }
        }
        if (-not $acc.Contains($key)) {
            $acc[$key] = [PSCustomObject]@{
                Date         = $r.Date
                DimensionKey = $key
                Scope        = $r.Scope
                ResourceId   = if ($Dimension -eq 'resource') { $r.ResourceId } else { '' }
                Meter        = if ($Dimension -eq 'subscription') { '' } else { $r.Meter }
                CostUsd      = 0.0
            }
        }
        $acc[$key].CostUsd += [double]$r.CostUsd
    }
    return @($acc.Values)
}

# ----------------------------------------------------------------------------
# Measure-DimensionBaseline — STEP 2b. Trailing baseline per dimension over the days the
# dimension actually appeared (observed days only, so normal intermittent workloads aren't
# flagged as spikes). Returns hashtable dim -> baseline.
#
# MEDIAN by default: the baseline window is short (7 days), so with a mean ONE unusual day
# inside the window drags the baseline up and masks the next day's spike — and a monthly
# reservation installment inside the window inflates it enormously. The median ignores that
# day. -Statistic Mean restores the old behaviour.
# ----------------------------------------------------------------------------
function Measure-DimensionBaseline {
    param(
        $Rows,
        [ValidateSet('Median', 'Mean')][string]$Statistic = 'Median',
        [ValidateSet('resource', 'meter', 'subscription')][string]$Dimension = 'resource'
    )
    $baseline = @{}
    if (-not $Rows) { return $baseline }
    # Single streaming pass: key -> (period -> total). No Group-Object, no re-keyed copy.
    $byKey = @{}
    foreach ($r in $Rows) {
        $key = if ($Dimension -eq 'resource') { [string]$r.DimensionKey }
               else { Get-DimensionKey -Dimension $Dimension -Scope ([string]$r.Scope) -Meter ([string]$r.Meter) -ResourceId ([string]$r.ResourceId) }
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = @{} }
        $d = [string]$r.Date
        if (-not $byKey[$key].ContainsKey($d)) { $byKey[$key][$d] = 0.0 }
        $byKey[$key][$d] += [double]$r.CostUsd
    }
    foreach ($key in $byKey.Keys) {
        $perDay = $byKey[$key]
        if ($Statistic -eq 'Mean') {
            $dayCount = [Math]::Max(1, $perDay.Keys.Count)
            $total = 0.0
            foreach ($v in $perDay.Values) { $total += $v }
            $baseline[$key] = $total / $dayCount
        } else {
            $baseline[$key] = Get-Median @($perDay.Values)
        }
    }
    return $baseline
}

# ----------------------------------------------------------------------------
# Find-CostSpike — STEP 2c. Flag dimensions whose current-day cost exceeds baseline by
# BOTH an absolute ($MinDeltaUsd) and relative ($MinDeltaPct) margin. Brand-new spend
# (no baseline) is flagged on the absolute margin alone and marked IsNew. Ranked by $.
#   -Current  : output of Measure-DailyDimensionCost (per-dimension totals for the day)
#   -Baseline : output of Measure-DimensionBaseline (dim -> baseline)
#   -Dimension: which grain these rows represent; stamped onto every spike.
# Returns array of spike objects.
# ----------------------------------------------------------------------------
function Find-CostSpike {
    param(
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Baseline,
        [double]$MinDeltaUsd = 25,
        [double]$MinDeltaPct = 50,
        [ValidateSet('resource', 'meter', 'subscription')][string]$Dimension = 'resource'
    )
    $spikes = foreach ($c in $Current) {
        $base = if ($Baseline.ContainsKey($c.DimensionKey)) { [double]$Baseline[$c.DimensionKey] } else { 0.0 }
        $spend = [double]$c.CostUsd
        $deltaUsd = $spend - $base
        if ($deltaUsd -lt $MinDeltaUsd) { continue }

        $isNew = $base -le 0
        $deltaPct = if ($isNew) { $null } else { ($deltaUsd / $base) * 100 }
        if (-not $isNew -and $deltaPct -lt $MinDeltaPct) { continue }

        [PSCustomObject]@{
            Id           = (Get-SpikeId -Date $c.Date -DimensionKey $c.DimensionKey)
            Date         = $c.Date
            Dimension    = $Dimension
            DimensionKey = $c.DimensionKey
            Scope        = $c.Scope
            ResourceId   = $c.ResourceId
            Meter        = $c.Meter
            BaselineUsd  = $base
            SpikeUsd     = $spend
            DeltaUsd     = $deltaUsd
            DeltaPct     = $deltaPct
            IsNew        = $isNew
        }
    }
    return @($spikes | Sort-Object -Property DeltaUsd -Descending)
}

# ----------------------------------------------------------------------------
# Select-UnexplainedSpike — STEP 2d. Keep only the rollup (meter / subscription) spikes
# that the resource-level spikes do NOT already account for. Pure.
#
# One GPU VM jumping $400 makes its meter AND its subscription jump $400 too; reporting all
# three would triple-count the same event. So a rollup survives only when the increase left
# over after subtracting the resource spikes underneath it is still material — which is
# exactly the diffuse case single-resource detection cannot see (50 resources at +$20 each:
# no resource spike, $1,000 unexplained at the meter).
#
# The surviving spike carries UnexplainedUsd (what is NOT attributable to a flagged resource).
# ----------------------------------------------------------------------------
function Select-UnexplainedSpike {
    param(
        [Parameter(Mandatory)]$RollupSpikes,
        $ResourceSpikes,
        [double]$MinDeltaUsd = 25
    )
    $explained = @{}
    foreach ($rs in @($ResourceSpikes)) {
        foreach ($dim in @('meter', 'subscription')) {
            $k = Get-DimensionKey -Dimension $dim -Scope ([string]$rs.Scope) -Meter ([string]$rs.Meter) -ResourceId ([string]$rs.ResourceId)
            if (-not $explained.ContainsKey($k)) { $explained[$k] = 0.0 }
            $explained[$k] += [double]$rs.DeltaUsd
        }
    }
    $out = foreach ($s in @($RollupSpikes)) {
        $already = if ($explained.ContainsKey([string]$s.DimensionKey)) { [double]$explained[[string]$s.DimensionKey] } else { 0.0 }
        $unexplained = [double]$s.DeltaUsd - $already
        if ($unexplained -lt $MinDeltaUsd) { continue }
        $s | Add-Member -NotePropertyName UnexplainedUsd -NotePropertyValue ([Math]::Round($unexplained, 2)) -Force -PassThru
    }
    return @($out | Sort-Object -Property DeltaUsd -Descending)
}

# ----------------------------------------------------------------------------
# Measure-ExitRunRate — STEP 2e. Where did the period END? Pure.
#
# A month is compared as one summed number, so a service that ran at full cost for twelve days
# and was then switched off still adds up to "more than a typical month". That is true of the
# month and misleading as a finding: it looks like an open increase when the cost has already
# fallen. This looks at the period's DAILY shape:
#   ExitDailyUsd    mean of the last -TailDays days (the level the period ended at)
#   ExitRunRateUsd  ExitDailyUsd x the period's length (same footing as the period total)
#   StepDownIndex   0-based index of the first day after the largest sustained drop, or $null.
#                   A drop counts when the median after it is at most -StepRatio x the median
#                   before it, both sides at least -MinSegmentDays long.
#   BeforeDailyUsd / AfterDailyUsd  the two medians around that drop.
# -Daily is one value per day of the period, oldest first, 0 for a day with no cost.
# ----------------------------------------------------------------------------
function Measure-ExitRunRate {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Daily,
        [int]$TailDays = 7,
        [double]$StepRatio = 0.5,
        [int]$MinSegmentDays = 3
    )
    $n = $Daily.Count
    if ($n -eq 0) { return $null }
    $tail = [Math]::Min([Math]::Max(1, $TailDays), $n)
    $sum = 0.0
    for ($i = $n - $tail; $i -lt $n; $i++) { $sum += $Daily[$i] }
    $exitDaily = $sum / $tail

    # The split is the one that fits the series best as two flat levels (least absolute deviation
    # from each side's median) — the largest drop in medians alone ties across every split that
    # leaves both medians unchanged, and would put the step on day 4 of a 12-day plateau.
    $stepIndex = $null; $before = $null; $after = $null; $bestFit = [double]::MaxValue
    for ($k = $MinSegmentDays; $k -le $n - $MinSegmentDays; $k++) {
        $mb = Get-Median @($Daily[0..($k - 1)])
        $ma = Get-Median @($Daily[$k..($n - 1)])
        if ($mb -le 0 -or $ma -gt $mb * $StepRatio) { continue }
        $fit = 0.0
        for ($i = 0; $i -lt $n; $i++) { $fit += [Math]::Abs($Daily[$i] - $(if ($i -lt $k) { $mb } else { $ma })) }
        if ($fit -lt $bestFit) { $bestFit = $fit; $stepIndex = $k; $before = $mb; $after = $ma }
    }
    return [PSCustomObject]@{
        ExitDailyUsd   = $exitDaily
        ExitRunRateUsd = $exitDaily * $n
        StepDownIndex  = $stepIndex
        BeforeDailyUsd = $before
        AfterDailyUsd  = $after
    }
}

# ----------------------------------------------------------------------------
# Add-DailySeriesRows — accumulate ONE day of snapshot rows into per-key daily series. Pure.
# -Series  hashtable key -> double[DayCount], filled in place
# -Wanted  hashtable of the keys to track (resource ids, 'meter:..' and 'sub:..' keys alike)
# Each row counts toward its resource, its meter rollup (that day's label) and its subscription,
# keyed exactly as detection keys them.
# ----------------------------------------------------------------------------
function Add-DailySeriesRows {
    param(
        [Parameter(Mandatory)][hashtable]$Series,
        [Parameter(Mandatory)][hashtable]$Wanted,
        $Rows,
        [Parameter(Mandatory)][int]$DayIndex,
        [Parameter(Mandatory)][int]$DayCount
    )
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $scope = [string]$r.Scope
        foreach ($k in @([string]$r.DimensionKey,
                         (Get-DimensionKey -Dimension 'meter' -Scope $scope -Meter ([string]$r.Meter)),
                         (Get-DimensionKey -Dimension 'subscription' -Scope $scope))) {
            if (-not $k -or -not $Wanted.ContainsKey($k)) { continue }
            if (-not $Series.ContainsKey($k)) { $Series[$k] = [double[]]::new($DayCount) }
            $Series[$k][$DayIndex] += [double]$r.CostUsd
        }
    }
}

# ----------------------------------------------------------------------------
# Test-ExitRunRateResolved — would the level a period ENDED at still be flagged? Pure.
# Same gates as Find-CostSpike, applied to the exit run-rate instead of the period total: when
# the period closed at a level that would not clear them, the increase has already fallen back
# and the finding is shown as such rather than as an open increase.
# ----------------------------------------------------------------------------
function Test-ExitRunRateResolved {
    param(
        [Parameter(Mandatory)][double]$ExitRunRateUsd,
        [Parameter(Mandatory)][double]$BaselineUsd,
        [double]$MinDeltaUsd = 25,
        [double]$MinDeltaPct = 50
    )
    $delta = $ExitRunRateUsd - $BaselineUsd
    if ($delta -lt $MinDeltaUsd) { return $true }
    if ($BaselineUsd -gt 0 -and (($delta / $BaselineUsd) * 100) -lt $MinDeltaPct) { return $true }
    return $false
}

# ----------------------------------------------------------------------------
# Measure-BaselineCoverage — in how many baseline periods did each key appear? Pure.
# Measure-DimensionBaseline skips periods where a key had no cost (so intermittent workloads are
# not flagged), which means a "typical" figure can rest on one period out of three. This says
# how many, so the page can show it. Keyed exactly like Measure-DimensionBaseline.
# ----------------------------------------------------------------------------
function Measure-BaselineCoverage {
    param(
        $Rows,
        [ValidateSet('resource', 'meter', 'subscription')][string]$Dimension = 'resource'
    )
    $byKey = @{}
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $key = if ($Dimension -eq 'resource') { [string]$r.DimensionKey }
               else { Get-DimensionKey -Dimension $Dimension -Scope ([string]$r.Scope) -Meter ([string]$r.Meter) -ResourceId ([string]$r.ResourceId) }
        if (-not $byKey.ContainsKey($key)) { $byKey[$key] = @{} }
        $byKey[$key][[string]$r.Date] = $true
    }
    $out = @{}
    foreach ($k in $byKey.Keys) { $out[$k] = $byKey[$k].Count }
    return $out
}

# ----------------------------------------------------------------------------
# Get-ResourceContext — STEP 3. Azure Resource Graph lookup for one resource.
# Returns { name, type, location, sku, tags } or $null. Best-effort: never throws.
# ----------------------------------------------------------------------------
function Get-ResourceContext {
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string]$MgmtToken)
    if ([string]::IsNullOrWhiteSpace($ResourceId)) { return $null }
    $query = "resources | where id =~ '$ResourceId' | project name, type, location, sku = tostring(sku.name), tags | take 1"
    try {
        $resp = Invoke-RestMethod -Method POST `
            -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
            -Headers @{ Authorization = "Bearer $MgmtToken" } `
            -Body (@{ query = $query } | ConvertTo-Json) -ContentType 'application/json'
        $row = @($resp.data) | Select-Object -First 1
        if (-not $row) { return $null }
        return [PSCustomObject]@{ name = $row.name; type = $row.type; location = $row.location; sku = $row.sku; tags = $row.tags }
    } catch {
        Write-Host "Get-ResourceContext failed for ${ResourceId}: $($_.Exception.Message)"
        return $null
    }
}

# ----------------------------------------------------------------------------
# Get-NarrationKey — the identity of a narration REQUEST, stored alongside the narrative it
# produced so an unchanged finding is never explained twice.
#
# This matters because a period is re-analysed on EVERY nightly run for as long as it is the
# newest one of its grain: the latest complete month is re-analysed every night until the next
# month closes, so a finding that appeared on the 2nd was being re-narrated ~29 more times, on
# the customer's own AI key, to produce the same paragraph from byte-identical inputs.
#
# The key covers everything the answer depends on — the system prompt, the payload, and the
# model — so it is safe in BOTH directions: a hit means a second call could only return what
# we already stored, and editing the prompt, changing the model, or any movement in the figures
# misses and re-narrates automatically. There is no staleness window to reason about and no
# cache to invalidate by hand.
#
# Shared by DetectCostSpikes-Timer and ExplainSpike so the two can't drift, the same reason the
# prompt and schema above are defined here rather than in either caller.
# ----------------------------------------------------------------------------
function Get-NarrationKey {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SystemPrompt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PayloadJson,
        [string]$Model
    )
    $bytes = [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes("$SystemPrompt`n$PayloadJson`n$Model"))
    return (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
}

# ----------------------------------------------------------------------------
# Test-NarrativeGrounding — STEP 6. Soft guardrail: every figure the model states should be
# one we handed it. Returns $true/$false; callers store the flag but still persist the text
# (it's a signal for the reader, not a hard gate).
#
# Works for ANY narration payload, not just spikes — savings findings, Advisor
# recommendations, and the Ask answer all run through it.
#
# Two rules keep it from crying wolf, which is what made the first version unusable:
#   1. Allowed = EVERY number anywhere in the payload we sent (not just the four headline
#      figures). Dates, event times, counts and SKU digits are all legitimately quotable.
#   2. A number is only a candidate if it stands alone. Digits glued to letters are part of
#      an identifier — "Standard_NC24ads_A100_v4" is a SKU name, not a claim that something
#      costs 24. The old version flagged every narrative that named a VM size.
# Values below -IgnoreBelow are skipped as incidental ("2 VMs", "3 events"); a fabricated
# COST is what matters here, and detection thresholds put those far above it.
# ----------------------------------------------------------------------------
function Test-NarrativeGrounding {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Narrative,
        [Parameter(Mandatory)]$Payload,
        [double]$IgnoreBelow = 10
    )
    if ([string]::IsNullOrWhiteSpace($Narrative)) { return $true }

    $payloadText = if ($Payload -is [string]) { $Payload } else { ($Payload | ConvertTo-Json -Depth 12 -Compress) }
    $allowed = @()
    foreach ($m in [regex]::Matches($payloadText, '\d+(?:\.\d+)?')) { $allowed += [double]$m.Value }

    # Standalone numbers only: not preceded by a letter/digit/underscore/decimal point, and
    # not followed by a letter/digit/underscore. Thousands separators are consumed and stripped.
    # A Danish text (PORTAL_LANGUAGE=da) writes 1.234,5: dot for thousands, comma for decimals.
    $danish = ((Get-PortalLanguage) -eq 'da')
    $pattern = if ($danish) { '(?<![A-Za-z0-9_.,])\d{1,3}(?:\.\d{3})+(?:,\d+)?(?![A-Za-z0-9_])|(?<![A-Za-z0-9_.,])\d+(?:,\d+)?(?![A-Za-z0-9_]|[.,]\d)' }
               else { '(?<![A-Za-z0-9_.])\d[\d,]*(?:\.\d+)?(?![A-Za-z0-9_])' }
    foreach ($m in [regex]::Matches($Narrative, $pattern)) {
        $raw = if ($danish) { ($m.Value -replace '\.', '') -replace ',', '.' } else { ($m.Value -replace ',', '').TrimEnd('.') }
        $v = 0.0
        if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { continue }
        if ([Math]::Abs($v) -lt $IgnoreBelow) { continue }
        $ok = $false
        foreach ($a in $allowed) {
            $tol = [Math]::Max(1.0, [Math]::Abs($a) * 0.02)   # tolerate the model rounding
            if ([Math]::Abs($a - $v) -le $tol) { $ok = $true; break }
        }
        if (-not $ok) { return $false }
    }
    return $true
}

# ----------------------------------------------------------------------------
# QueryCosts support — the NL→query feature is SAFE BY CONSTRUCTION: the model emits a
# small structured spec (not query text), which we validate against an allowlist and
# translate into a read-only Cost Management Query API call. There is no imperative query
# language to sanitize, and the Query API only aggregates cost (it cannot mutate anything).
# ----------------------------------------------------------------------------

# The dimensions the model is allowed to group/filter by. Used both to build the
# generation prompt/schema and to validate the returned spec.
function Get-CostQueryDimensions {
    return @('ResourceGroupName', 'ServiceName', 'MeterCategory', 'MeterSubCategory',
        'ResourceLocation', 'ResourceId', 'SubscriptionName', 'ChargeType', 'PublisherType')
}

# ----------------------------------------------------------------------------
# COST TYPE — ActualCost vs AmortizedCost. This changes what every number means.
#
#   ActualCost     what was BILLED on a day. A reservation or savings-plan purchase lands as
#                  a single lump on its billing date, and the usage it covers shows as $0.
#                  Ties to the invoice.
#   AmortizedCost  the purchase spread across its term and attributed to the resources that
#                  consumed it. No lump, no free-looking usage.
#
# The app analyses spend — trends, anomalies, per-resource savings, allocation — and for all
# of that AmortizedCost is the correct view: a reservation purchase is not a spend anomaly,
# and a reservation-covered VM is not free. ActualCost made a $30k purchase look like a spike
# (which is why spike detection carries a reservation-installment classification at all) and
# made covered resources look cheaper than they are.
#
# So analysis defaults to AmortizedCost, overridable per deployment via PortalConfig
# 'CostType' for operators who need invoice tie-out instead.
#
# ONE EXCEPTION, deliberately not configurable: reservation display-name resolution in
# ResourceNames.psm1 must stay ActualCost, because it reads the purchase rows that
# AmortizedCost does not produce.
$script:DefaultCostType = 'AmortizedCost'

# Read the configured cost type. Falls back to the default when unset or unreadable, so a
# storage hiccup can never silently change what the numbers mean.
function Get-CostTypeSetting {
    param([Parameter(Mandatory)][string]$StorageToken)
    try {
        $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1
        if ($row -and $row.CostType -in @('ActualCost', 'AmortizedCost')) { return [string]$row.CostType }
    } catch { Write-Host "CostType read failed, using $($script:DefaultCostType): $($_.Exception.Message)" }
    return $script:DefaultCostType
}

# Marker prefix on the exception a throttled query throws, so HTTP endpoints can answer 429
# with a useful message instead of a generic gateway failure. Test-CostQueryThrottled reads it.
$script:ThrottleMarker = 'COST_QUERY_THROTTLED'

# The wall-clock budget an INTERACTIVE (HTTP-triggered) cost query gets, backoff included.
# Azure's App Service front end aborts any HTTP response at 230 seconds, so a request that
# keeps retrying past that point cannot succeed — it only burns time and returns 502 to a
# caller who has already been disconnected. 100s leaves room for token acquisition, table
# reads and serialization inside the same request.
$script:InteractiveQueryBudgetSeconds = 100

# Retry policy for interactive callers: few attempts, short backoff, short per-request
# timeout. Timers keep the patient defaults below — 20 minutes of backoff is correct for a
# nightly job and catastrophic for a page load.
function Get-InteractiveQueryPolicy {
    param([double]$RemainingSeconds)
    return @{ MaxAttempts = 3; MaxWaitSeconds = 15; TimeoutSec = 45; BudgetSeconds = [Math]::Max(1, $RemainingSeconds) }
}

# Which response column holds the amount — and is it actually USD?
#
# The queries ask for 'CostUSD', the USD figure Azure normalises itself. The old code fell back
# to 'Cost' with no comment when that column was absent, and 'Cost' is the **billing currency**.
# On a tenant billed in anything but USD that silently stored (say) EUR in a field named
# CostUsd, which the portal then multiplied by the USD→EUR rate a second time at display —
# off by the whole exchange rate, with nothing anywhere to indicate it.
#
# The fallback stays (a figure on the wrong basis beats no figure, and it is recoverable), but
# it now announces itself and reports the basis so callers can record it instead of guessing.
function Resolve-CostColumn {
    param($Columns, [string]$Context = 'cost query')
    $i = [array]::IndexOf($Columns, 'CostUSD')
    if ($i -ge 0) { return [PSCustomObject]@{ Index = $i; IsUsd = $true } }
    $i = [array]::IndexOf($Columns, 'Cost')
    if ($i -ge 0) {
        Write-Host ("  WARNING ${Context}: no 'CostUSD' column in the response — falling back to 'Cost', which is the " +
                    "BILLING CURRENCY, not USD. Stored figures will be on the wrong basis until this is resolved. " +
                    "Columns: [$($Columns -join ', ')]")
        return [PSCustomObject]@{ Index = $i; IsUsd = $false }
    }
    Write-Host "  WARNING ${Context}: the response has no cost column at all. Columns: [$($Columns -join ', ')]"
    return [PSCustomObject]@{ Index = -1; IsUsd = $false }
}

# The tenant's billing currency, probed with one cheap ungrouped query.
#
# Needed because "no currency supplied" cannot safely be read as "USD": Advisor omits the
# currency on some recommendation types, and assuming USD for a non-USD tenant skews the
# converted figure by the whole exchange rate. Returns e.g. 'EUR', or $null when it can't be
# determined (callers must then decline to convert rather than guess).
function Get-BillingCurrency {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType
    )
    # 'Cost' (not CostUSD) is what carries a Currency column, and MonthToDate/None is the
    # smallest question that returns one.
    $body = @{
        type      = $CostType
        timeframe = 'MonthToDate'
        dataset   = @{ granularity = 'None'; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } }
    } | ConvertTo-Json -Depth 10
    try {
        $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body `
            -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        $cols = @($resp.properties.columns.name)
        $iCur = [array]::IndexOf($cols, 'Currency')
        if ($iCur -lt 0) { return $null }
        foreach ($r in $resp.properties.rows) {
            $c = [string]$r[$iCur]
            if (-not [string]::IsNullOrWhiteSpace($c)) { return $c.Trim().ToUpper() }
        }
    } catch { Write-Host "billing-currency probe failed (non-fatal): $($_.Exception.Message)" }
    return $null
}

# Private: how long Cost Management asked us to wait. The Query API's own budget is in query
# processing units (QPU) per TENANT — 12 per 10 s, 60 per minute, 600 per hour, one QPU per month
# of data queried — and a QPU throttle names its wait in x-ms-ratelimit-microsoft.costmanagement-
# qpu-retry-after, NOT in Retry-After. Reading only Retry-After meant a blind 20 s guess on every
# 429. The longest of the stated waits wins; none stated -> -Default.
# https://learn.microsoft.com/azure/cost-management-billing/costs/manage-automation#data-latency-and-rate-limits
function Get-CostRetryAfterSeconds {
    param($Headers, [int]$Default = 20)
    $best = -1
    foreach ($name in @('x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after',
                        'x-ms-ratelimit-microsoft.costmanagement-entity-retry-after',
                        'x-ms-ratelimit-microsoft.costmanagement-tenant-retry-after',
                        'x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after',
                        'Retry-After')) {
        $v = $null
        try { $v = $Headers[$name] } catch { $v = $null }
        if ($v -is [array]) { $v = $v[0] }
        $parsed = 0
        if ($v -and [int]::TryParse([string]$v, [ref]$parsed) -and $parsed -gt $best) { $best = $parsed }
    }
    if ($best -lt 0) { return $Default }
    return $best
}

# Private: POST to the Cost Management Query API with 429/5xx retry that honours the
# server's stated wait (Get-CostRetryAfterSeconds). This API is aggressively rate-limited (especially across many
# subscriptions), so backing off on the server-specified delay is required. Returns parsed
# JSON; throws on non-retryable errors or exhausted retries.
#
# -BudgetSeconds caps the TOTAL wall clock for this call, backoff included (0 = uncapped,
# for timers). It is enforced twice: the per-request timeout is clamped to what's left, and
# a backoff that would overrun the budget aborts instead of sleeping. That guarantees an
# interactive caller fails fast and legibly rather than being cut off mid-retry by the
# platform. Defaults reproduce the previous behaviour exactly (6 attempts, ≤90s backoff,
# 120s per request ≈ 19.5 minutes worst case) for the nightly timers.
function Invoke-CostQueryRest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Body,
        [int]$MaxAttempts = 6,
        [int]$MaxWaitSeconds = 90,
        [int]$TimeoutSec = 120,
        [double]$BudgetSeconds = 0
    )
    $headers = @{ Authorization = "Bearer $Token" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # -TimeoutSec: without it a stalled connection hangs the whole timer forever with
        # no log output; a thrown timeout is caught per-subscription and the run moves on.
        $timeout = $TimeoutSec
        if ($BudgetSeconds -gt 0) {
            $remaining = $BudgetSeconds - $sw.Elapsed.TotalSeconds
            if ($remaining -le 1) {
                throw "$($script:ThrottleMarker): Cost Management did not answer within the $([int]$BudgetSeconds)s budget for an interactive query."
            }
            $timeout = [int][Math]::Max(5, [Math]::Min($TimeoutSec, $remaining))
        }

        $resp = Invoke-WebRequest -Method POST -Uri $Uri -Headers $headers -Body $Body -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec $timeout
        $code = [int]$resp.StatusCode

        if ($code -eq 429 -or $code -ge 500) {
            if ($attempt -ge $MaxAttempts) { break }
            $wait = Get-CostRetryAfterSeconds -Headers $resp.Headers -Default 20
            $wait = [Math]::Min([Math]::Max($wait, 5), $MaxWaitSeconds)
            # Don't start a sleep we can't finish inside the budget — fail now, with a reason.
            if ($BudgetSeconds -gt 0 -and ($sw.Elapsed.TotalSeconds + $wait) -ge $BudgetSeconds) {
                throw "$($script:ThrottleMarker): Cost Management is rate-limiting this query (HTTP $code). Stopped after $([int]$sw.Elapsed.TotalSeconds)s rather than retry past the request budget."
            }
            Write-Host "  Cost Management API $code — waiting ${wait}s then retrying (attempt $attempt/$MaxAttempts)"
            Start-Sleep -Seconds $wait
            continue
        }
        if ($code -ge 400) { throw "Cost Management query returned HTTP ${code}: $($resp.Content)" }
        return ($resp.Content | ConvertFrom-Json)
    }
    throw "$($script:ThrottleMarker): Cost Management is rate-limiting this query — still throttled after $MaxAttempts attempt(s) over $([int]$sw.Elapsed.TotalSeconds)s."
}

# True when an error came from Cost Management throttling (as opposed to a real failure), so
# an endpoint can answer 429 "try again shortly" instead of a generic 502.
function Test-CostQueryThrottled {
    param($ErrorRecord)
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    return $msg -like "$($script:ThrottleMarker)*"
}

# Validate a model-produced query spec against the allowlists, build the Cost Management
# QueryDefinition, execute it (read-only), and parse columns/rows into objects.
# Returns { query = <built definition, for transparency>; columns; rows }. Throws on API error.
function Invoke-CostQuery {
    # $Scope is a full ARM scope path: /subscriptions/<id> or
    # /providers/Microsoft.Management/managementGroups/<id> (tenant-wide).
    # -Interactive bounds the retry budget so an HTTP caller gets a fast, explicit throttle
    # error instead of being cut off by the platform's 230s limit mid-retry.
    # -WindowFrom/-WindowTo ('yyyy-MM-dd') replace the spec's timeframe with an explicit Custom
    # window (used by Invoke-CostComparison); -Granularity overrides the spec's granularity.
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string]$Scope,
        [switch]$Interactive,
        [double]$InteractiveBudgetSeconds = 60,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType,
        [string]$WindowFrom,
        [string]$WindowTo,
        [ValidateSet('None', 'Daily', 'Monthly')][string]$Granularity,
        # The operator's subscription scope. Added as its own ANDed filter (not one of the three
        # the question may use), so a management-group query never counts excluded subscriptions.
        [string[]]$SubscriptionIds
    )

    $allowedDims = Get-CostQueryDimensions
    $allowedTf   = @('MonthToDate', 'BillingMonthToDate', 'TheLastMonth', 'TheLastBillingMonth', 'WeekToDate', 'Custom')
    $allowedGran = @('None', 'Daily', 'Monthly')

    $tf   = if ($Spec.timeframe -and ($allowedTf -contains $Spec.timeframe)) { $Spec.timeframe } else { 'MonthToDate' }
    $gran = if ($Granularity) { $Granularity } elseif ($Spec.granularity -and ($allowedGran -contains $Spec.granularity)) { $Spec.granularity } else { 'None' }
    $specFrom = $Spec.from; $specTo = $Spec.to
    if ($WindowFrom -and $WindowTo) { $tf = 'Custom'; $specFrom = $WindowFrom; $specTo = $WindowTo }
    $groupBy = @()
    if ($Spec.groupBy) { $groupBy = @($Spec.groupBy | Where-Object { $allowedDims -contains $_ } | Select-Object -Unique -First 2) }

    $dataset = @{ granularity = $gran; aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } } }
    $groupings = @($groupBy | ForEach-Object { @{ type = 'Dimension'; name = $_ } })
    # Group by a tag (the explorer's "by owner", "by cost centre"). Cost Management returns it as
    # two columns, TagKey and TagValue. It takes one of the two grouping slots.
    $tagPattern = '^[A-Za-z0-9 _.:\-]{1,64}$'
    if ($Spec.groupByTag -and [string]$Spec.groupByTag -match $tagPattern) {
        $groupings = @(@{ type = 'TagKey'; name = [string]$Spec.groupByTag }) + @($groupings | Select-Object -First 1)
    }
    if ($groupings.Count) { $dataset.grouping = @($groupings) }

    # Up to three dimension filters, ANDed. 'filters' is the current spec shape;
    # filterDimension/filterValues is the original single-filter shape, still accepted.
    $filters = @()
    if ($Spec.filters) {
        foreach ($f in @($Spec.filters)) {
            if (-not $f -or -not ($allowedDims -contains [string]$f.dimension)) { continue }
            $vals = @(@($f.values) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 20)
            if ($vals.Count) { $filters += @{ dimensions = @{ name = [string]$f.dimension; operator = 'In'; values = $vals } } }
        }
    } elseif ($Spec.filterDimension -and ($allowedDims -contains $Spec.filterDimension) -and $Spec.filterValues) {
        $vals = @($Spec.filterValues | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 20)
        if ($vals.Count) { $filters += @{ dimensions = @{ name = $Spec.filterDimension; operator = 'In'; values = $vals } } }
    }
    # Tag filters ({ tag, values }) share the three-filter budget with the dimension filters.
    foreach ($tagF in @($Spec.tagFilters)) {
        if (-not $tagF -or [string]$tagF.tag -notmatch $tagPattern) { continue }
        $vals = @(@($tagF.values) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 20)
        if ($vals.Count) { $filters += @{ tags = @{ name = [string]$tagF.tag; operator = 'In'; values = $vals } } }
    }
    $filters = @($filters | Select-Object -First 3)
    if ($SubscriptionIds -and $SubscriptionIds.Count) {
        $filters += @{ dimensions = @{ name = 'SubscriptionId'; operator = 'In'; values = @($SubscriptionIds) } }
    }
    if ($filters.Count -eq 1) { $dataset.filter = $filters[0] }
    elseif ($filters.Count -gt 1) { $dataset.filter = @{ and = $filters } }

    # CUSTOM TIMEFRAMES ARE MODEL-CHOSEN, so treat them as untrusted input.
    #
    # Azure rejects timeframe 'Custom' with no timePeriod, and the model can emit exactly that —
    # nothing in the schema ties the dates to the timeframe. The old code just omitted
    # timePeriod and let the request 400, which reached the user as a bare "cost query failed".
    # Falling back to a named timeframe answers the question approximately instead of not at all.
    #
    # The bounds are clamped too: a window ending in the future returns nothing (and looks like
    # "we have no data"), and an open-ended one is a needlessly expensive query against an API
    # that is already the tightest rate limit in the app.
    $customFrom = $null; $customTo = $null
    if ($tf -eq 'Custom') {
        $todayUtc = [datetime]::UtcNow.Date
        $f = [datetime]::MinValue; $t = [datetime]::MinValue
        $okF = $specFrom -and [datetime]::TryParse([string]$specFrom, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$f)
        $okT = $specTo   -and [datetime]::TryParse([string]$specTo,   [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)
        if (-not $okF -or -not $okT) {
            Write-Host "  cost query: 'Custom' timeframe without usable from/to — falling back to MonthToDate."
            $tf = 'MonthToDate'
        } else {
            $f = $f.Date; $t = $t.Date
            if ($f -gt $t) { $swap = $f; $f = $t; $t = $swap }        # reversed range
            if ($t -gt $todayUtc) { $t = $todayUtc }                  # never ask for the future
            if ($f -gt $t) { $f = $t }
            if (($t - $f).TotalDays -gt 365) { $f = $t.AddDays(-365) } # bound the span
            $customFrom = $f.ToString('yyyy-MM-dd'); $customTo = $t.ToString('yyyy-MM-dd')
        }
    }

    # The type is returned to the UI with the rest of the definition, so the user can see
    # whether they're looking at amortized or billed figures.
    $definition = @{ type = $CostType; timeframe = $tf; dataset = $dataset }
    if ($tf -eq 'Custom') { $definition.timePeriod = @{ from = $customFrom; to = $customTo } }

    # The Ask flow also spends time on two AI calls in the same request, so give the cost
    # query a smaller slice of the budget than a plain drill-down gets.
    $policy = if ($Interactive) { Get-InteractiveQueryPolicy -RemainingSeconds $InteractiveBudgetSeconds } else { @{} }
    $resp = Invoke-CostQueryRest `
        -Uri "https://management.azure.com$Scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01" `
        -Token $MgmtToken -Body ($definition | ConvertTo-Json -Depth 10) @policy

    $cols = @($resp.properties.columns.name)
    $rows = foreach ($r in $resp.properties.rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $r[$i] }
        [PSCustomObject]$o
    }
    return [PSCustomObject]@{ query = $definition; columns = $cols; rows = @($rows) }
}

# ----------------------------------------------------------------------------
# PERIOD COMPARISON for Ask ("…compared with last month?").
#
# Resolve-QueryWindow turns a spec's timeframe into explicit dates; Get-PreviousQueryWindow
# gives the equivalent earlier window. Both pure. Month-aligned timeframes compare against the
# same days of the previous month (not the previous N days), because that is what people mean
# by "this month vs last month". Billing-month timeframes are approximated by calendar months
# for the comparison — flagged as Approximate so the answer can say so.
# ----------------------------------------------------------------------------
function Resolve-QueryWindow {
    param([Parameter(Mandatory)]$Spec, [datetime]$Today = [datetime]::UtcNow.Date)
    $tf = [string]$Spec.timeframe
    $monthStart = Get-UtcMonthStart -Date $Today
    switch ($tf) {
        'TheLastMonth'        { $s = $monthStart.AddMonths(-1); return [PSCustomObject]@{ From = $s; To = $monthStart.AddDays(-1); Aligned = 'month-full'; Approximate = $false } }
        'TheLastBillingMonth' { $s = $monthStart.AddMonths(-1); return [PSCustomObject]@{ From = $s; To = $monthStart.AddDays(-1); Aligned = 'month-full'; Approximate = $true } }
        'WeekToDate' {
            $offset = (([int]$Today.DayOfWeek) + 6) % 7   # Monday = 0
            return [PSCustomObject]@{ From = $Today.AddDays(-$offset); To = $Today; Aligned = 'none'; Approximate = $false }
        }
        'Custom' {
            $f = [datetime]::MinValue; $t = [datetime]::MinValue
            $okF = $Spec.from -and [datetime]::TryParse([string]$Spec.from, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$f)
            $okT = $Spec.to -and [datetime]::TryParse([string]$Spec.to, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)
            if ($okF -and $okT) {
                $f = $f.Date; $t = $t.Date
                if ($f -gt $t) { $x = $f; $f = $t; $t = $x }
                if ($t -gt $Today) { $t = $Today }
                if ($f -gt $t) { $f = $t }
                if (($t - $f).TotalDays -gt 365) { $f = $t.AddDays(-365) }
                return [PSCustomObject]@{ From = $f; To = $t; Aligned = 'none'; Approximate = $false }
            }
        }
    }
    # MonthToDate, BillingMonthToDate, and anything unusable.
    return [PSCustomObject]@{ From = $monthStart; To = $Today; Aligned = 'month-to-date'; Approximate = ($tf -eq 'BillingMonthToDate') }
}

function Get-PreviousQueryWindow {
    param([Parameter(Mandatory)]$Window)
    switch ($Window.Aligned) {
        'month-full' {
            $s = $Window.From.AddMonths(-1)
            return [PSCustomObject]@{ From = $s; To = $Window.From.AddDays(-1) }
        }
        'month-to-date' {
            $s = $Window.From.AddMonths(-1)
            $monthEnd = $Window.From.AddDays(-1)
            $to = $s.AddDays(($Window.To - $Window.From).Days)
            if ($to -gt $monthEnd) { $to = $monthEnd }
            return [PSCustomObject]@{ From = $s; To = $to }
        }
        default {
            $len = ($Window.To - $Window.From).Days + 1
            return [PSCustomObject]@{ From = $Window.From.AddDays(-$len); To = $Window.From.AddDays(-1) }
        }
    }
}

# Merge a current and a previous result on their grouping columns. Pure.
# Rows come back as { <group cols>; Cost; PreviousCost; Change; ChangePct; Currency }, largest
# current cost first.
function Merge-CostComparisonRows {
    param($CurrentRows, $PreviousRows, [string[]]$GroupBy)
    $keyOf = {
        param($r)
        if (-not $GroupBy -or -not $GroupBy.Count) { return '(total)' }
        return (@($GroupBy | ForEach-Object { [string]$r.$_ }) -join '|').ToLowerInvariant()
    }
    $merged = [ordered]@{}
    foreach ($r in @($CurrentRows)) {
        if ($null -eq $r) { continue }
        $k = & $keyOf $r
        if (-not $merged.Contains($k)) {
            $o = [ordered]@{}
            foreach ($g in @($GroupBy)) { $o[$g] = $r.$g }
            $o.Cost = 0.0; $o.PreviousCost = 0.0; $o.Currency = [string]$r.Currency
            $merged[$k] = $o
        }
        $merged[$k].Cost += [double]$r.Cost
    }
    foreach ($r in @($PreviousRows)) {
        if ($null -eq $r) { continue }
        $k = & $keyOf $r
        if (-not $merged.Contains($k)) {
            $o = [ordered]@{}
            foreach ($g in @($GroupBy)) { $o[$g] = $r.$g }
            $o.Cost = 0.0; $o.PreviousCost = 0.0; $o.Currency = [string]$r.Currency
            $merged[$k] = $o
        }
        $merged[$k].PreviousCost += [double]$r.Cost
        if (-not $merged[$k].Currency) { $merged[$k].Currency = [string]$r.Currency }
    }
    $out = foreach ($o in $merged.Values) {
        $row = [ordered]@{}
        foreach ($g in @($GroupBy)) { $row[$g] = $o[$g] }
        $row.Cost = [Math]::Round([double]$o.Cost, 2)
        $row.PreviousCost = [Math]::Round([double]$o.PreviousCost, 2)
        $row.Change = [Math]::Round([double]$o.Cost - [double]$o.PreviousCost, 2)
        $row.ChangePct = if ([double]$o.PreviousCost -gt 0) { [Math]::Round((([double]$o.Cost - [double]$o.PreviousCost) / [double]$o.PreviousCost) * 100, 1) } else { $null }
        $row.Currency = $o.Currency
        [PSCustomObject]$row
    }
    return @($out | Sort-Object Cost -Descending)
}

# Run a spec for its own window and the previous equivalent one, then merge. Granularity is
# forced to None: a trend and a comparison in one table does not read well.
function Invoke-CostComparison {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string]$Scope,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType,
        [datetime]$Today = [datetime]::UtcNow.Date,
        [string[]]$SubscriptionIds
    )
    $cur = Resolve-QueryWindow -Spec $Spec -Today $Today
    $prev = Get-PreviousQueryWindow -Window $cur
    $common = @{ Spec = $Spec; MgmtToken = $MgmtToken; Scope = $Scope; Interactive = $true; InteractiveBudgetSeconds = 40; CostType = $CostType; Granularity = 'None'; SubscriptionIds = $SubscriptionIds }
    $q1 = Invoke-CostQuery @common -WindowFrom $cur.From.ToString('yyyy-MM-dd') -WindowTo $cur.To.ToString('yyyy-MM-dd')
    $q2 = Invoke-CostQuery @common -WindowFrom $prev.From.ToString('yyyy-MM-dd') -WindowTo $prev.To.ToString('yyyy-MM-dd')
    $groupBy = @()
    # A tag grouping comes back as TagKey + TagValue columns; the value is what rows differ by.
    if ($q1.query.dataset.grouping) { $groupBy = @($q1.query.dataset.grouping | ForEach-Object { if ([string]$_.type -eq 'TagKey') { 'TagValue' } else { [string]$_.name } }) }
    $rows = Merge-CostComparisonRows -CurrentRows $q1.rows -PreviousRows $q2.rows -GroupBy $groupBy
    $cols = @($groupBy) + @('Cost', 'PreviousCost', 'Change', 'ChangePct', 'Currency')
    return [PSCustomObject]@{
        query      = [PSCustomObject]@{ current = $q1.query; previous = $q2.query }
        columns    = $cols
        rows       = $rows
        comparison = [PSCustomObject]@{
            currentFrom  = $cur.From.ToString('yyyy-MM-dd'); currentTo  = $cur.To.ToString('yyyy-MM-dd')
            previousFrom = $prev.From.ToString('yyyy-MM-dd'); previousTo = $prev.To.ToString('yyyy-MM-dd')
            approximate  = [bool]$cur.Approximate
        }
    }
}

# ----------------------------------------------------------------------------
# ASKING MANY SUBSCRIPTIONS AS ONE.
#
# Cost Management does not answer management-group queries for CSP / Microsoft Customer
# Agreement subscriptions ("Management group … does not have any valid subscriptions"), so on
# such a tenant a portal-wide question has to be asked of every subscription and the rows added
# up. Select-SpecSubscriptions picks which ones: the subscriptions a question names (a
# SubscriptionName / SubscriptionId filter), else all of them.
# ----------------------------------------------------------------------------

# Pure. -Subscriptions: [{ Id; Name }]. Returns { Subscriptions; Spec (the subscription filter
# removed when it was resolved); Named (bool); Unmatched (names that matched nothing) }.
function Select-SpecSubscriptions {
    param([Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Subscriptions)
    $wanted = @(); $rest = @()
    foreach ($f in @($Spec.filters)) {
        if ($f -and [string]$f.dimension -in @('SubscriptionName', 'SubscriptionId')) { $wanted += @($f.values | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
        elseif ($f) { $rest += $f }
    }
    if (-not $wanted.Count) { return [PSCustomObject]@{ Subscriptions = @($Subscriptions); Spec = $Spec; Named = $false; Unmatched = @() } }
    $picked = [System.Collections.Generic.List[object]]::new(); $unmatched = @()
    foreach ($w in $wanted) {
        $wl = $w.ToLowerInvariant()
        $hit = @($Subscriptions | Where-Object { $_.Id -eq $wl -or ([string]$_.Name).ToLowerInvariant() -eq $wl })
        if (-not $hit.Count) { $hit = @($Subscriptions | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains($wl) }) }
        if (-not $hit.Count) { $unmatched += $w; continue }
        foreach ($h in $hit) { if (-not @($picked | Where-Object { $_.Id -eq $h.Id }).Count) { $picked.Add($h) } }
    }
    if (-not $picked.Count) { return [PSCustomObject]@{ Subscriptions = @(); Spec = $Spec; Named = $true; Unmatched = $unmatched } }
    $copy = $Spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $copy.filters = @($rest)
    return [PSCustomObject]@{ Subscriptions = @($picked); Spec = $copy; Named = $true; Unmatched = $unmatched }
}

# The subscriptions a question names in its own words, found in the text (longest names first,
# case-insensitive). Done here, not by the model, so the model never needs the list of names.
function Find-SubscriptionsInText {
    param([string]$Text, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Subscriptions)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = $Text.ToLowerInvariant()
    $found = @()
    foreach ($s in @($Subscriptions | Where-Object { ([string]$_.Name).Length -ge 4 } | Sort-Object { ([string]$_.Name).Length } -Descending)) {
        $n = ([string]$s.Name).ToLowerInvariant()
        $i = $t.IndexOf($n)
        if ($i -lt 0) { continue }
        $found += $s
        $t = $t.Remove($i, $n.Length).Insert($i, (' ' * $n.Length))   # so a shorter name inside it does not match again
    }
    return @($found)
}

# Make the spec ask about the subscriptions the question names: put them in one SubscriptionName
# filter, and drop any other filter the model put the same name in (e.g. as a resource group).
function Set-SpecSubscriptions {
    param([Parameter(Mandatory)]$Spec, [object[]]$Named)
    if (-not @($Named).Count) { return $Spec }
    $names = @($Named | ForEach-Object { [string]$_.Name })
    $copy = $Spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $keep = @(@($copy.filters) | Where-Object { $_ -and [string]$_.dimension -notin @('SubscriptionName', 'SubscriptionId') -and
        -not @(@($_.values) | Where-Object { $names -contains [string]$_ }).Count })
    $copy.filters = @($keep) + @([PSCustomObject]@{ dimension = 'SubscriptionName'; values = $names })
    return $copy
}

# ----------------------------------------------------------------------------
# Answer a spec from the portal's own per-resource cost (Read-ResourceCostIndex) when it can:
# this month so far or last month, grouped by resource / resource group / subscription / owner,
# filtered by those. Instant and covers every subscription; resource-attributed cost only.
# Returns $null when the question needs something the index doesn't hold (service, region,
# meter, a daily trend, other periods) — the caller then asks Cost Management.
# Rows come back in the billing currency when -Rate is given ({ Currency; Rate }), else USD.
# ----------------------------------------------------------------------------
function Invoke-StoredCostQuery {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)]$IndexData,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Subscriptions,
        $Rate,
        [switch]$Compare
    )
    if (-not $IndexData -or -not $IndexData.Meta) { return $null }
    $tf = [string]$Spec.timeframe
    $period = if ($tf -in @('MonthToDate', 'BillingMonthToDate', '')) { 'current' } elseif ($tf -in @('TheLastMonth', 'TheLastBillingMonth')) { 'last' } else { return $null }
    if (-not $Compare -and [string]$Spec.granularity -and [string]$Spec.granularity -ne 'None') { return $null }
    if ($Compare -and $period -eq 'last' -and -not [bool]$IndexData.Meta.MonthBeforeKnown) { return $null }
    $dimMap = @{ ResourceId = 'Id'; ResourceGroupName = 'Rg'; SubscriptionName = 'SubName' }
    $groupBy = @(@($Spec.groupBy) | Where-Object { $_ })
    foreach ($g in $groupBy) { if (-not $dimMap.ContainsKey([string]$g)) { return $null } }
    $byOwner = [bool]$Spec.groupByTag
    $filters = @(@($Spec.filters) | Where-Object { $_ })
    foreach ($f in $filters) { if ([string]$f.dimension -notin @('ResourceId', 'ResourceGroupName', 'SubscriptionName', 'SubscriptionId')) { return $null } }
    if (@($Spec.tagFilters | Where-Object { $_ }).Count) { return $null }

    $subName = @{}; foreach ($s in @($Subscriptions)) { $subName[[string]$s.Id] = [string]$s.Name }
    $rows = @($IndexData.Rows | Where-Object { $subName.ContainsKey([string]$_.Sub) })
    foreach ($f in $filters) {
        $vals = @(@($f.values) | ForEach-Object { ([string]$_).ToLowerInvariant() })
        switch ([string]$f.dimension) {
            'ResourceId'        { $rows = @($rows | Where-Object { $vals -contains $_.Id.ToLowerInvariant() -or $vals -contains $_.Name.ToLowerInvariant() }) }
            'ResourceGroupName' { $rows = @($rows | Where-Object { $vals -contains $_.Rg.ToLowerInvariant() }) }
            'SubscriptionId'    { $rows = @($rows | Where-Object { $vals -contains $_.Sub }) }
            'SubscriptionName'  {
                $ids = @((Select-SpecSubscriptions -Spec ([PSCustomObject]@{ filters = @($f) }) -Subscriptions $Subscriptions).Subscriptions | ForEach-Object { $_.Id })
                $rows = @($rows | Where-Object { $ids -contains $_.Sub })
            }
        }
    }
    $mult = if ($Rate -and $Rate.Rate) { [double]$Rate.Rate } else { 1.0 }
    $cur = if ($Rate -and $Rate.Currency) { [string]$Rate.Currency } else { 'USD' }
    $groups = [ordered]@{}
    foreach ($r in $rows) {
        $amount = if ($period -eq 'current') { $r.Current } else { $r.PrevMonth }
        $prevAmount = if ($period -eq 'current') { $r.PrevSame } else { [double]($r.MonthBefore ?? 0) }
        if ($amount -eq 0 -and (-not $Compare -or $prevAmount -eq 0)) { continue }
        $o = [ordered]@{}
        foreach ($g in $groupBy) {
            $o[$g] = switch ($g) { 'ResourceId' { $r.Id } 'ResourceGroupName' { $r.Rg } 'SubscriptionName' { $subName[[string]$r.Sub] } }
        }
        if ($byOwner) { $o['TagKey'] = [string]$IndexData.Meta.OwnerKey; $o['TagValue'] = if ($r.Owner) { $r.Owner } else { '(untagged)' } }
        $k = (@($o.Values) -join '|').ToLowerInvariant()
        if (-not $groups.Contains($k)) { $o['Cost'] = 0.0; if ($Compare) { $o['PreviousCost'] = 0.0 }; $o['Currency'] = $cur; $groups[$k] = $o }
        $groups[$k].Cost += $amount * $mult
        if ($Compare) { $groups[$k].PreviousCost += $prevAmount * $mult }
    }
    $out = @(foreach ($o in $groups.Values) {
        $o.Cost = [Math]::Round([double]$o.Cost, 2)
        if ($Compare) {
            $o.PreviousCost = [Math]::Round([double]$o.PreviousCost, 2)
            $o['Change'] = [Math]::Round($o.Cost - $o.PreviousCost, 2)
            $o['ChangePct'] = if ($o.PreviousCost -gt 0) { [Math]::Round((($o.Cost - $o.PreviousCost) / $o.PreviousCost) * 100, 1) } else { $null }
        }
        [PSCustomObject]$o
    }) | Sort-Object { [double]$_.Cost } -Descending
    $m = $IndexData.Meta
    $periodText = if ($period -eq 'current') { "$($m.Month) to $($m.SettledThrough)" } else { [string]$m.PreviousMonth }
    $cols = @($groupBy) + @($(if ($byOwner) { 'TagKey', 'TagValue' })) + @('Cost') + @($(if ($Compare) { 'PreviousCost', 'Change', 'ChangePct' })) + @('Currency')
    return [PSCustomObject]@{
        query      = [PSCustomObject]@{ source = "the portal's nightly per-resource cost data"; period = $periodText; groupBy = $groupBy; filters = $filters
                       note = 'Resource-attributed cost only: purchases and charges not tied to a resource are not included.' }
        columns    = $cols
        rows       = @($out)
        comparison = if ($Compare) {
            [PSCustomObject]@{ currentFrom = $(if ($period -eq 'current') { "$($m.Month)-01" } else { "$($m.PreviousMonth)-01" }); currentTo = $(if ($period -eq 'current') { [string]$m.SettledThrough } else { 'end of month' })
                previousFrom = $(if ($period -eq 'current') { "$($m.PreviousMonth)-01" } else { 'the month before' }); previousTo = $(if ($period -eq 'current') { [string]$m.PreviousSameDaysThrough } else { '' }); approximate = $false }
        } else { $null }
        periodText = $periodText
    }
}

# Add up rows from several subscriptions: rows that agree on every column except the amounts
# are one row. Pure. Amount columns: Cost, PreviousCost (Change and ChangePct are recomputed).
function Merge-SubscriptionCostRows {
    param([object[]]$Rows)
    $amounts = @('Cost', 'PreviousCost', 'Change', 'ChangePct')
    $merged = [ordered]@{}
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $keyCols = @($r.PSObject.Properties.Name | Where-Object { $amounts -notcontains $_ })
        $k = (@($keyCols | ForEach-Object { "$_=$([string]$r.$_)".ToLowerInvariant() }) -join '|')
        if (-not $merged.Contains($k)) {
            $o = [ordered]@{}
            foreach ($c in $keyCols) { $o[$c] = $r.$c }
            $o.Cost = 0.0
            if ($r.PSObject.Properties['PreviousCost']) { $o.PreviousCost = 0.0 }
            $merged[$k] = $o
        }
        $merged[$k].Cost += [double]$r.Cost
        if ($r.PSObject.Properties['PreviousCost']) { $merged[$k].PreviousCost += [double]$r.PreviousCost }
    }
    $out = foreach ($o in $merged.Values) {
        $o.Cost = [Math]::Round([double]$o.Cost, 2)
        if ($o.Contains('PreviousCost')) {
            $o.PreviousCost = [Math]::Round([double]$o.PreviousCost, 2)
            $o.Change = [Math]::Round([double]$o.Cost - [double]$o.PreviousCost, 2)
            $o.ChangePct = if ([double]$o.PreviousCost -gt 0) { [Math]::Round((([double]$o.Cost - [double]$o.PreviousCost) / [double]$o.PreviousCost) * 100, 1) } else { $null }
        }
        [PSCustomObject]$o
    }
    return @($out | Sort-Object { [double]$_.Cost } -Descending)
}

# Run one spec against each subscription and add the rows up. Stops starting new subscriptions
# when -BudgetSeconds is spent (an HTTP request has 230 s in all), and reports which ones were
# not answered rather than presenting a short total as complete.
# Returns { query; columns; rows; comparison; answered = [names]; missing = [names] }.
function Invoke-CostQueryAcrossSubscriptions {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Subscriptions,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType,
        [switch]$Compare,
        [double]$BudgetSeconds = 120
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $all = [System.Collections.Generic.List[object]]::new()
    $answered = @(); $missing = @(); $first = $null; $comparison = $null
    foreach ($s in @($Subscriptions)) {
        $left = $BudgetSeconds - $sw.Elapsed.TotalSeconds
        if ($left -lt 8) { $missing += $s.Name; continue }
        try {
            $q = if ($Compare) {
                Invoke-CostComparison -Spec $Spec -MgmtToken $MgmtToken -Scope "/subscriptions/$($s.Id)" -CostType $CostType
            } else {
                Invoke-CostQuery -Spec $Spec -MgmtToken $MgmtToken -Scope "/subscriptions/$($s.Id)" -Interactive -InteractiveBudgetSeconds ([Math]::Min(30, $left)) -CostType $CostType
            }
            if (-not $first) { $first = $q }
            if ($q.comparison) { $comparison = $q.comparison }
            foreach ($r in @($q.rows)) { $all.Add($r) }
            $answered += $s.Name
        } catch {
            Write-Host "  cost query for $($s.Name) failed: $($_.Exception.Message)"
            $missing += $s.Name
        }
    }
    $rows = @(Merge-SubscriptionCostRows -Rows @($all))
    $cols = if ($first) { @($first.columns) } else { @() }
    return [PSCustomObject]@{
        query      = if ($first) { [PSCustomObject]@{ perSubscription = $first.query; subscriptions = $answered.Count } } else { $null }
        columns    = $cols
        rows       = $rows
        comparison = $comparison
        answered   = @($answered)
        missing    = @($missing)
    }
}

# ----------------------------------------------------------------------------
# Get-DailyResourceCost — STEP 1 (INGEST). Pull daily per-resource cost (in USD) for ONE
# subscription over a date window via the read-only Cost Management Query API, and
# aggregate to one row per (date, resource) keeping the top-cost meter category as a label.
# Returns CostSnapshots-ready rows: { Date, ResourceId, Scope, Meter, CostUsd }.
# This replaces the old blob-CSV export ingest — the app now self-serves cost data.
# ----------------------------------------------------------------------------
function Get-DailyResourceCost {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType
    )
    return @((Read-DailyResourceCost -SubscriptionId $SubscriptionId -MgmtToken $MgmtToken -From $From -To $To -CostType $CostType).Rows)
}

# Private: the per-resource query behind Get-DailyResourceCost and Get-SubscriptionDailyCost.
# Returns @{ Rows = CostSnapshots-ready rows; UsdByDate = @{ 'yyyy-MM-dd' -> USD } }.
#
# UsdByDate is the subscription's COMPLETE daily total: it also counts the rows Azure attributes
# to no resource (marketplace, support, most reservation/savings-plan charges), which Rows leaves
# out. Grouping only splits cost rows, it never drops any, so this sum equals the ungrouped
# total (checked against a live tenant, 2026-11-06) — and saves a second query per subscription.
function Read-DailyResourceCost {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType
    )

    $body = @{
        type       = $CostType
        timeframe  = 'Custom'
        timePeriod = @{ from = $From.ToString('yyyy-MM-dd'); to = $To.ToString('yyyy-MM-dd') }
        dataset    = @{
            granularity = 'Daily'
            aggregation = @{ totalCost = @{ name = 'CostUSD'; function = 'Sum' } }  # normalized USD
            grouping    = @(
                @{ type = 'Dimension'; name = 'ResourceId' }
                @{ type = 'Dimension'; name = 'MeterCategory' }
            )
        }
    } | ConvertTo-Json -Depth 10

    # Aggregate across meter categories to (date, resource): sum cost, remember the meter
    # that contributed the most (a useful label without exploding row count).
    $agg = @{}          # "date|resourceId" -> { Date; ResourceId; CostUsd; TopMeter; TopMeterCost }
    $usdByDate = @{}    # 'yyyy-MM-dd' -> every row's cost, resource or not
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    do {
        $resp = Invoke-CostQueryRest -Uri $uri -Token $MgmtToken -Body $body
        $cols  = @($resp.properties.columns.name)
        $costCol = Resolve-CostColumn -Columns $cols -Context "per-resource ingest [$SubscriptionId]"
        $iCost = $costCol.Index
        $iDate = [array]::IndexOf($cols, 'UsageDate')
        $iRes  = [array]::IndexOf($cols, 'ResourceId')
        $iMet  = [array]::IndexOf($cols, 'MeterCategory')

        $rowsSeen = 0; $rowsParsed = 0; $rowsNoResource = 0
        foreach ($r in $resp.properties.rows) {
            $rowsSeen++
            $resId = if ($iRes -ge 0) { [string]$r[$iRes] } else { '' }
            # UsageDate is normally yyyyMMdd, but accept an ISO date too rather than dropping
            # the row — a silent drop here empties CostSnapshots and everything downstream.
            $dRaw = if ($iDate -ge 0) { [string]$r[$iDate] } else { '' }
            $date = $null
            if ($dRaw -match '^\d{8}$') {
                $date = [datetime]::ParseExact($dRaw, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
            } elseif ($dRaw) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse($dRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                    $date = $parsed.ToString('yyyy-MM-dd')
                }
            }
            if (-not $date) { continue }
            $cost = if ($iCost -ge 0) { [double]$r[$iCost] } else { 0.0 }
            if (-not $usdByDate.ContainsKey($date)) { $usdByDate[$date] = 0.0 }
            $usdByDate[$date] += $cost
            # Expected: charges Azure attributes to no resource (marketplace, support, tax). They
            # count in the day's total above, but are no resource's cost.
            if ([string]::IsNullOrWhiteSpace($resId)) { $rowsNoResource++; continue }
            $rowsParsed++
            $meter = if ($iMet -ge 0) { [string]$r[$iMet] } else { '' }

            $key = "$date|$resId"
            if (-not $agg.ContainsKey($key)) {
                $agg[$key] = [PSCustomObject]@{ Date = $date; ResourceId = $resId; CostUsd = 0.0; TopMeter = $meter; TopMeterCost = 0.0 }
            }
            $e = $agg[$key]
            $e.CostUsd += $cost
            if ($cost -gt $e.TopMeterCost) { $e.TopMeterCost = $cost; $e.TopMeter = $meter }
        }
        # A page of rows that yields nothing usable is a parsing mismatch, not an empty tenant.
        # Say so, with the column names — that is the fact that identifies it.
        if ($rowsSeen -gt 0 -and $rowsParsed -eq 0) {
            Write-Host "  ingest: $rowsSeen row(s) returned but NONE were usable ($rowsNoResource had no resource id). Columns: [$($cols -join ', ')]"
        }
        $uri = $resp.properties.nextLink   # cost-query pagination: re-POST the same body to nextLink
    } while ($uri)

    $out = foreach ($e in $agg.Values) {
        [PSCustomObject]@{ Date = $e.Date; ResourceId = $e.ResourceId; Scope = $SubscriptionId; Meter = $e.TopMeter; CostUsd = $e.CostUsd }
    }
    return @{ Rows = @($out); UsdByDate = $usdByDate }
}

# ----------------------------------------------------------------------------
# Get-SubscriptionDailyCost — everything the ingest needs from ONE subscription for a date range,
# in two queries: the per-resource rows (CostSnapshots) and the complete daily total in USD and in
# the billing currency (CostSummary 'dailysub'). The old ingest spent a third query per
# subscription on the USD total; it comes from the per-resource query now (Read-DailyResourceCost).
#
# Returns @{ Rows; Days = @{ 'yyyy-MM-dd' -> @{ Usd; Billing; Currency } }; Currency }.
# A day Azure returns nothing for is absent from Days (the caller decides whether that is a zero).
# Keep the range inside one calendar month where possible: the Query API charges one QPU per
# month of data a request touches.
# ----------------------------------------------------------------------------
function Get-SubscriptionDailyCost {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType
    )
    $res = Read-DailyResourceCost -SubscriptionId $SubscriptionId -MgmtToken $MgmtToken -From $From -To $To -CostType $CostType
    # The billing-currency figure needs its own single-aggregation query (see Get-CostTotalsByPeriod).
    $native = Get-CostTotalsByPeriod -SubscriptionId $SubscriptionId -MgmtToken $MgmtToken -From $From -To $To `
        -Granularity 'Daily' -CostType $CostType -Field 'Cost'
    $days = @{}
    foreach ($d in @(@($res.UsdByDate.Keys) + @($native.Totals.Keys) | Sort-Object -Unique)) {
        $days[$d] = @{
            Usd      = if ($res.UsdByDate.ContainsKey($d)) { [double]$res.UsdByDate[$d] } else { 0.0 }
            Billing  = if ($native.Totals.ContainsKey($d)) { [double]$native.Totals[$d] } else { $null }
            Currency = $native.Currency
        }
    }
    return @{ Rows = @($res.Rows); Days = $days; Currency = $native.Currency }
}

# ----------------------------------------------------------------------------
# Get-CostTotalSeries — TOTALS-ONLY cost series for one subscription (no grouping, so it
# is far lighter on the rate limit than the per-resource ingest query). Daily granularity
# feeds the trend backfill; Monthly feeds the subscription scorecard. Returns array of
# { Period ('yyyy-MM-dd' or 'yyyy-MM'); CostUsd }. Throws on API errors (callers decide
# whether a failure aborts or is tolerated).
# ----------------------------------------------------------------------------
# Private: paginated period->total read for ONE aggregation field ('CostUSD' or 'Cost').
#
# ONE aggregation per request, deliberately. The Query API *will* accept two, and returns both
# columns — but verified against a live tenant, the response labels the columns in the request's
# aggregation order while ordering the row VALUES differently, so the column named 'CostUSD' can
# hold the billing-currency figure. Trusting the name there is a silent exchange-rate-sized error on a
# non-USD tenant. With a single aggregation the name is unambiguous, and these are the cheap
# ungrouped/monthly-grain queries where a second round trip costs almost nothing.
# Returns @{ Totals = @{ period -> amount }; Currency = '<code>' }.
function Get-CostTotalsByPeriod {
    param(
        [string]$SubscriptionId, [string]$MgmtToken, [datetime]$From, [datetime]$To,
        [string]$Granularity, [string]$CostType, [string]$Field
    )
    $body = @{
        type       = $CostType
        timeframe  = 'Custom'
        timePeriod = @{ from = $From.ToString('yyyy-MM-dd'); to = $To.ToString('yyyy-MM-dd') }
        dataset    = @{
            granularity = $Granularity
            aggregation = @{ totalCost = @{ name = $Field; function = 'Sum' } }
        }
    } | ConvertTo-Json -Depth 10

    $out = @{}; $currency = $null
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    do {
        $resp = Invoke-CostQueryRest -Uri $uri -Token $MgmtToken -Body $body
        $cols = @($resp.properties.columns.name)
        $iVal = [array]::IndexOf($cols, $Field)
        if ($iVal -lt 0) {
            Write-Host "  WARNING cost totals [$SubscriptionId]: no '$Field' column in the response. Columns: [$($cols -join ', ')]"
        }
        # Daily rows carry UsageDate (yyyyMMdd); Monthly rows carry BillingMonth (ISO datetime).
        $iDay   = [array]::IndexOf($cols, 'UsageDate')
        $iMonth = [array]::IndexOf($cols, 'BillingMonth')
        $iCur   = [array]::IndexOf($cols, 'Currency')
        foreach ($r in $resp.properties.rows) {
            $period = $null
            if ($iDay -ge 0 -and ([string]$r[$iDay]) -match '^\d{8}$') {
                $period = [datetime]::ParseExact([string]$r[$iDay], 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
            } elseif ($iMonth -ge 0 -and $r[$iMonth]) {
                $period = ([datetime]$r[$iMonth]).ToString('yyyy-MM')
            }
            if (-not $period) { continue }
            if (-not $currency -and $iCur -ge 0 -and $r[$iCur]) { $currency = ([string]$r[$iCur]).Trim().ToUpper() }
            $cost = if ($iVal -ge 0) { [double]$r[$iVal] } else { 0.0 }
            if (-not $out.ContainsKey($period)) { $out[$period] = 0.0 }
            $out[$period] += $cost
        }
        $uri = $resp.properties.nextLink
    } while ($uri)
    return @{ Totals = $out; Currency = $currency }
}

function Get-CostTotalSeries {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('Daily', 'Monthly')][string]$Granularity = 'Daily',
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType,
        # Also fetch the BILLING-CURRENCY amount, in a second single-aggregation query.
        #
        # Worth the extra round trip wherever a figure is one a human reconciles against the
        # Azure blade or an invoice. Storing only CostUSD means the portal must convert at
        # display time with ECB rates, and Azure normalised to USD with its own — measured at
        # -1.37% against a live non-USD tenant, and drifting daily with the currency market even
        # for closed months. The native figure needs no conversion at all.
        [switch]$IncludeNative
    )
    # NOT $args — that is an automatic variable and assigning to it is asking for trouble.
    $common = @{ SubscriptionId = $SubscriptionId; MgmtToken = $MgmtToken; From = $From; To = $To
                 Granularity = $Granularity; CostType = $CostType }
    $usd    = Get-CostTotalsByPeriod @common -Field 'CostUSD'
    $native = if ($IncludeNative) { Get-CostTotalsByPeriod @common -Field 'Cost' } else { $null }

    return @($usd.Totals.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $p = [string]$_.Key
        [PSCustomObject]@{
            Period      = $p
            CostUsd     = [double]$_.Value
            # $null (not 0) when not requested or absent, so a caller can tell "no native
            # figure" from "a native figure that happens to be zero".
            CostBilling = if ($native -and $native.Totals.ContainsKey($p)) { [double]$native.Totals[$p] } else { $null }
            Currency    = if ($native) { $native.Currency } else { $null }
        }
    })
}

# ----------------------------------------------------------------------------
# Get-CommitmentCoveredResources — resources whose usage a reservation or savings plan is
# already paying for, in one subscription over the last -Days days.
#
# This is what keeps the savings total honest about right-sizing. Downsizing a VM that a
# three-year reservation already covers saves nothing at all until that commitment is
# exchanged: the money is spent either way. Reporting it as a saving is the single easiest way
# for a FinOps tool to promise money that does not exist.
#
# `PricingModel` is a Cost Management dimension with values OnDemand / Reservation /
# SavingsPlan / Spot. One grouped query per subscription, filtered to the candidate resources.
# Returns the lower-cased resource ids that had any committed usage. Never throws.
# ----------------------------------------------------------------------------
function Get-CommitmentCoveredResources {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [string[]]$ResourceIds = @(),
        [int]$Days = 30,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType
    )
    $ids = @($ResourceIds | Where-Object { $_ } | Select-Object -Unique)
    if (-not $ids.Count) { return @() }
    $to = [datetime]::UtcNow.Date
    $from = $to.AddDays(-$Days)
    $filter = @{
        and = @(
            @{ dimensions = @{ name = 'PricingModel'; operator = 'In'; values = @('Reservation', 'SavingsPlan') } }
            @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($ids | Select-Object -First 100) } }
        )
    }
    $body = @{
        type       = $CostType
        timeframe  = 'Custom'
        timePeriod = @{ from = $from.ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd') }
        dataset    = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'CostUSD'; function = 'Sum' } }
            grouping    = @(@{ type = 'Dimension'; name = 'ResourceId' })
            filter      = $filter
        }
    } | ConvertTo-Json -Depth 12

    $covered = @()
    try {
        $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body `
            -Uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
        $cols = @($resp.properties.columns.name)
        $iRes = [array]::IndexOf($cols, 'ResourceId')
        $iCost = [array]::IndexOf($cols, 'CostUSD')
        foreach ($r in $resp.properties.rows) {
            if ($iRes -lt 0) { continue }
            if ($iCost -ge 0 -and [double]$r[$iCost] -le 0) { continue }
            $covered += ([string]$r[$iRes]).ToLowerInvariant()
        }
    } catch {
        # Not fatal: without this list the affected findings are simply priced as if they were
        # pay-as-you-go, which the tier and the caveat text still qualify.
        Write-Host "  commitment-coverage lookup failed for ${SubscriptionId}: $($_.Exception.Message)"
    }
    return @($covered | Select-Object -Unique)
}

# ----------------------------------------------------------------------------
# Get-CostForecast — Azure's own month-end projection for a scope.
#
# A straight line from the month-to-date average is wrong in both directions on a real tenant:
# it ignores weekday/weekend shape, and a reservation purchase or a one-off backfill early in
# the month projects the whole month up. The Forecast API models the tenant's own pattern, so
# the number on the card is Azure's, not ours.
#
# `includeActualCost` makes the response carry BOTH the billed days so far (CostStatus
# 'Actual') and the projected remainder ('Forecast') — the month-end figure is their sum, and
# the actual part is what lets the caller sanity-check it against stored data.
#
# One aggregation per request (see Get-CostTotalsByPeriod): -Field 'CostUSD' for the comparable
# figure, 'Cost' for the billing-currency one. Throws on API errors; the caller decides whether
# a missing forecast is fatal (it never is — the UI falls back to a run-rate).
# ----------------------------------------------------------------------------
function Get-CostForecast {
    param(
        [Parameter(Mandatory)][string]$Scope,      # /subscriptions/<id> or a management-group path
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('CostUSD', 'Cost')][string]$Field = 'CostUSD',
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = $script:DefaultCostType,
        # Limit a management-group forecast to these subscriptions (the operator's scope).
        [string[]]$SubscriptionIds
    )
    $dataset = @{
        granularity = 'Daily'
        aggregation = @{ totalCost = @{ name = $Field; function = 'Sum' } }
    }
    if ($SubscriptionIds -and $SubscriptionIds.Count) {
        $dataset.filter = @{ dimensions = @{ name = 'SubscriptionId'; operator = 'In'; values = @($SubscriptionIds) } }
    }
    $body = @{
        type                   = $CostType
        timeframe              = 'Custom'
        timePeriod             = @{ from = $From.ToString('yyyy-MM-dd'); to = $To.ToString('yyyy-MM-dd') }
        includeActualCost      = $true
        # Partial days are re-stated by Azure for a day or two; including them makes the
        # projection jitter between runs for no gain.
        includeFreshPartialCost = $false
        dataset                = $dataset
    } | ConvertTo-Json -Depth 10

    $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body `
        -Uri "https://management.azure.com$Scope/providers/Microsoft.CostManagement/forecast?api-version=2023-11-01"

    $cols = @($resp.properties.columns.name)
    $iVal = [array]::IndexOf($cols, $Field)
    $iStatus = [array]::IndexOf($cols, 'CostStatus')
    $iCur = [array]::IndexOf($cols, 'Currency')
    if ($iVal -lt 0) { throw "forecast response has no '$Field' column. Columns: [$($cols -join ', ')]" }

    $actual = 0.0; $forecast = 0.0; $currency = $null
    foreach ($r in $resp.properties.rows) {
        $v = [double]$r[$iVal]
        $status = if ($iStatus -ge 0) { [string]$r[$iStatus] } else { 'Forecast' }
        if ($status -eq 'Actual') { $actual += $v } else { $forecast += $v }
        if (-not $currency -and $iCur -ge 0 -and $r[$iCur]) { $currency = ([string]$r[$iCur]).Trim().ToUpper() }
    }
    return [PSCustomObject]@{
        TotalAmount    = [Math]::Round($actual + $forecast, 2)
        ActualAmount   = [Math]::Round($actual, 2)
        ForecastAmount = [Math]::Round($forecast, 2)
        Currency       = $currency
        Field          = $Field
    }
}

# ----------------------------------------------------------------------------
# Get-ConsumptionBudgets — the budgets the customer already set in Azure.
#
# The portal deliberately does NOT invent its own budget store: a budget lives where the
# finance owner put it, alerts on it already exist, and a second copy would drift. Cost
# Management Reader covers `Microsoft.Consumption/budgets/read`.
#
# Only Cost-category budgets are returned (the API also carries usage budgets), and only ones
# whose window covers today, so an expired budget never shows as 0% used. Never throws.
# ----------------------------------------------------------------------------
function Get-ConsumptionBudgets {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$MgmtToken,
        [string]$ScopeName = ''
    )
    $out = @()
    $uri = "https://management.azure.com$Scope/providers/Microsoft.Consumption/budgets?api-version=2023-05-01"
    try {
        do {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" } -TimeoutSec 30
            $out += @(ConvertTo-BudgetItems -Value @($resp.value) -Scope $Scope -ScopeName $ScopeName)
            $uri = $resp.nextLink
        } while ($uri)
    } catch {
        Write-Host "budget read failed for ${Scope}: $($_.Exception.Message)"
    }
    return @($out)
}

# The budgets of one list response as portal items: Cost budgets only, not expired, with their
# tag filters ('In' only) and whether any other clause narrows them further. Pure.
#
# A subscription's listing also returns the budgets set on its RESOURCE GROUPS (verified on a live
# tenant). Each item's Scope is therefore taken from the budget's own id, and a resource-group
# budget carries ResourceGroupId and the group's name — it measures one group, never the
# subscription, let alone the month.
function ConvertTo-BudgetItems {
    param([object[]]$Value, [string]$Scope, [string]$ScopeName)
    $out = @()
    $today = [datetime]::UtcNow.Date
    foreach ($b in @($Value)) {
        if (-not $b) { continue }
        $p = $b.properties
        if ([string]$p.category -and [string]$p.category -ne 'Cost') { continue }
        $start = [datetime]::MinValue; $end = [datetime]::MaxValue
        if ($p.timePeriod.startDate) { [datetime]::TryParse([string]$p.timePeriod.startDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$start) | Out-Null }
        if ($p.timePeriod.endDate) { [datetime]::TryParse([string]$p.timePeriod.endDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$end) | Out-Null }
        if ($end -ne [datetime]::MaxValue -and $end.Date -lt $today) { continue }   # expired
        # Tag filters ('In' only), so a budget set per cost centre or owner can be shown on
        # that statement. Any other clause (dimensions, 'not') narrows the budget further,
        # which the page says rather than pretending the budget covers the whole value.
        $tagFilters = @(); $extra = $false
        if ($p.filter) {
            $clauses = @($p.filter)
            if ($p.filter.and) { $clauses += @($p.filter.and) }
            foreach ($cl in $clauses) {
                if ($cl.tags -and [string]$cl.tags.name) {
                    if ([string]$cl.tags.operator -and [string]$cl.tags.operator -ne 'In') { $extra = $true; continue }
                    $tagFilters += [PSCustomObject]@{ key = (([string]$cl.tags.name).ToLowerInvariant() -replace '[^a-z0-9]', ''); values = @($cl.tags.values | ForEach-Object { [string]$_ }) }
                }
                if ($cl.dimensions -or $cl.not) { $extra = $true }
            }
        }
        $ownScope = $Scope; $ownName = $ScopeName; $rgId = ''
        if ([string]$b.id -match '(?i)^(.*?)/providers/Microsoft\.Consumption/budgets/') { $ownScope = $Matches[1] }
        if ($ownScope -match '(?i)^/subscriptions/[0-9a-f-]{36}/resourcegroups/([^/]+)$') { $rgId = $ownScope.ToLowerInvariant(); $ownName = $Matches[1] }
        $out += [PSCustomObject]@{
            Name         = [string]$b.name
            Scope        = $ownScope
            ScopeName    = $ownName
            ResourceGroupId = $rgId
            Amount       = [double]$p.amount
            Currency     = if ($p.currentSpend.unit) { [string]$p.currentSpend.unit } else { '' }
            TimeGrain    = [string]$p.timeGrain
            SpentAmount  = if ($null -ne $p.currentSpend.amount) { [double]$p.currentSpend.amount } else { 0.0 }
            ForecastAmount = if ($null -ne $p.forecastSpend.amount) { [double]$p.forecastSpend.amount } else { $null }
            StartDate    = if ($start -ne [datetime]::MinValue) { $start.ToString('yyyy-MM-dd') } else { '' }
            EndDate      = if ($end -ne [datetime]::MaxValue) { $end.ToString('yyyy-MM-dd') } else { '' }
            TagFilters   = @($tagFilters)
            ExtraFilters = $extra
        }
    }
    return @($out)
}


# ----------------------------------------------------------------------------
# WHICH SCOPE ANSWERS TENANT-WIDE QUESTIONS (forecast, Ask, the explorer, commitments).
#
# Cost Management can only query one scope per request: a subscription, or a management group.
# The portal's totals are the sum over every included subscription, so a question about "the
# tenant" must be asked at a management group that contains them all — otherwise the forecast
# on the Overview describes one subscription while the month-to-date next to it describes all
# of them, with nothing to say so.
#
#   1. COST_QUERY_SCOPE (bicep costQueryScope), when the operator set one;
#   2. else the SMALLEST management group the identity can read whose descendants include every
#      included subscription (discovered nightly by SyncMonthlyCosts-Timer, stored in
#      PortalConfig 'costscope/resolved' so requests never pay for the ARM walk);
#   3. else none — callers fall back per subscription and say so.
#
# Extra = how many subscriptions that group holds beyond the included ones; when it is > 0 (or a
# subscription scope is set) queries must carry a SubscriptionId filter.
# ----------------------------------------------------------------------------
function Find-CoveringManagementGroup {
    param(
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [int]$MaxGroups = 25
    )
    $want = @($SubscriptionIds | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    if (-not $want.Count) { return $null }
    $h = @{ Authorization = "Bearer $MgmtToken" }
    $groups = @()
    $uri = 'https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2021-04-01'
    try {
        do {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $h -TimeoutSec 60
            $groups += @($resp.value)
            $uri = $resp.nextLink
        } while ($uri -and $groups.Count -lt $MaxGroups)
    } catch {
        Write-Host "  management-group list failed (no covering group can be found): $($_.Exception.Message)"
        return $null
    }
    $best = $null
    foreach ($g in @($groups | Select-Object -First $MaxGroups)) {
        $name = [string]$g.name
        $subs = @()
        $duri = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$name/descendants?api-version=2021-04-01"
        try {
            do {
                $d = Invoke-RestMethod -Method GET -Uri $duri -Headers $h -TimeoutSec 60
                $subs += @($d.value | Where-Object { [string]$_.type -match '(?i)/subscriptions$' } | ForEach-Object { ([string]$_.name).ToLowerInvariant() })
                $duri = $d.nextLink
            } while ($duri)
        } catch { continue }
        if (@($want | Where-Object { $subs -notcontains $_ }).Count) { continue }
        $extra = $subs.Count - $want.Count
        if (-not $best -or $extra -lt $best.Extra) {
            $best = [PSCustomObject]@{ Scope = "/providers/Microsoft.Management/managementGroups/$name"; Name = [string]$g.properties.displayName; Extra = $extra }
        }
    }
    return $best
}

# Nightly: work out the scope and store it. Returns { Scope; Source; Name; Extra }.
function Update-ResolvedCostScope {
    param(
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string]$StorageToken,
        [Parameter(Mandatory)][string[]]$SubscriptionIds
    )
    $r = $null
    if (-not [string]::IsNullOrWhiteSpace($env:COST_QUERY_SCOPE)) {
        $r = [PSCustomObject]@{ Scope = $env:COST_QUERY_SCOPE; Source = 'configured'; Name = ''; Extra = -1 }
    } else {
        $mg = Find-CoveringManagementGroup -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds
        $r = if ($mg) { [PSCustomObject]@{ Scope = $mg.Scope; Source = 'discovered'; Name = $mg.Name; Extra = $mg.Extra } }
             else { [PSCustomObject]@{ Scope = ''; Source = 'none'; Name = ''; Extra = 0 } }
    }
    try {
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{
            PartitionKey = 'costscope'; RowKey = 'resolved'
            Scope = [string]$r.Scope; Source = $r.Source; Name = [string]$r.Name; Extra = [int]$r.Extra
            Subscriptions = @($SubscriptionIds).Count; At = ([datetime]::UtcNow.ToString('o'))
        }
    } catch { Write-Host "  cost-scope write failed (non-fatal): $($_.Exception.Message)" }
    Write-Host "Tenant cost scope: $(if ($r.Scope) { "$($r.Scope) ($($r.Source)$(if ($r.Extra -gt 0) { ", $($r.Extra) extra subscription(s) filtered out" }))" } else { 'none — no readable management group contains every subscription; per-subscription fallback' })"
    return $r
}

# A discovered management group contains every subscription but its cost data covers only part
# of the spend (measured by SyncMonthlyCosts-Timer against the per-subscription month-to-date) —
# typically subscriptions on another billing agreement, which Cost Management does not total at
# management-group level. Stored as source 'insufficient' with no scope, so live questions fall
# back to what they can answer honestly and say why. A configured scope is never overridden.
function Set-CostScopeInsufficient {
    param([Parameter(Mandatory)][string]$StorageToken, [string]$Name, [double]$CoveragePct, [int]$Subscriptions)
    if (-not [string]::IsNullOrWhiteSpace($env:COST_QUERY_SCOPE)) { return }
    try {
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{
            PartitionKey = 'costscope'; RowKey = 'resolved'
            Scope = ''; Source = 'insufficient'; Name = [string]$Name; Extra = 0; CoveragePct = [Math]::Round($CoveragePct, 1)
            Subscriptions = $Subscriptions; At = ([datetime]::UtcNow.ToString('o'))
        }
    } catch { Write-Host "  cost-scope write failed (non-fatal): $($_.Exception.Message)" }
    Write-Host "Tenant cost scope: $Name shows only $([Math]::Round($CoveragePct, 0))% of month-to-date spend in its cost data — not used for tenant-wide queries."
}

# For requests: the stored resolution (COST_QUERY_SCOPE always wins). Never calls ARM.
# Returns { Scope ('' = none); Source; Name; Extra; CoveragePct }.
function Get-ResolvedCostScope {
    param([Parameter(Mandatory)][string]$StorageToken)
    if (-not [string]::IsNullOrWhiteSpace($env:COST_QUERY_SCOPE)) {
        return [PSCustomObject]@{ Scope = $env:COST_QUERY_SCOPE; Source = 'configured'; Name = ''; Extra = -1 }
    }
    try {
        $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'costscope' and RowKey eq 'resolved'" -Token $StorageToken) | Select-Object -First 1
        if ($row -and $row.Scope) {
            return [PSCustomObject]@{ Scope = [string]$row.Scope; Source = [string]$row.Source; Name = [string]$row.Name; Extra = [int]$row.Extra; CoveragePct = $null }
        }
        if ($row -and [string]$row.Source -eq 'insufficient') {
            return [PSCustomObject]@{ Scope = ''; Source = 'insufficient'; Name = [string]$row.Name; Extra = 0; CoveragePct = if ($null -ne $row.CoveragePct) { [double]$row.CoveragePct } else { $null } }
        }
    } catch { Write-Host "cost-scope read failed: $($_.Exception.Message)" }
    return [PSCustomObject]@{ Scope = ''; Source = 'none'; Name = ''; Extra = 0 }
}

# ----------------------------------------------------------------------------
# Budget lists of the month overview (CostSummary 'monthoverview'/'current').
#
# Resource-group budgets (up to 300) and tag budgets (up to 100) used to be stored as one JSON
# string each on the overview row. A Table property holds at most 64 KiB, and 300 budgets are
# more than that: the whole row then failed with 400 Bad Request and the Overview showed nothing.
# They now live in their own rows, 'monthbudgets'/'<kind>|NNN', 40 items to a row, and the
# overview row records how many (RgBudgetRows / TagBudgetRows).
# Get-MonthBudgetList still reads the old inline property when the overview has no row count,
# so a deployment keeps working until its next monthly sync.
# ----------------------------------------------------------------------------
function Save-MonthBudgetList {
    param([Parameter(Mandatory)][ValidateSet('Rg', 'Tag')][string]$Kind, [array]$Items, [Parameter(Mandatory)][string]$StorageToken)
    $all = @($Items)
    $per = 40
    $entities = @()
    for ($i = 0; $i -lt $all.Count; $i += $per) {
        $chunk = @($all[$i..([Math]::Min($i + $per - 1, $all.Count - 1))])
        $entities += @{ PartitionKey = 'monthbudgets'; RowKey = ('{0}|{1:000}' -f $Kind, ($i / $per))
                        ItemsJson = ($chunk | ConvertTo-Json -Compress -AsArray -Depth 4) }
    }
    if ($entities.Count) { Set-TableEntityBatch -Table 'CostSummary' -Entities $entities -Token $StorageToken }
    # Rows beyond the new count belong to a longer list from an earlier night.
    $stale = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthbudgets' and RowKey ge '$Kind|' and RowKey lt '$Kind|~'" -Token $StorageToken |
        Where-Object { [int](([string]$_.RowKey -split '\|')[1]) -ge $entities.Count })
    if ($stale.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $stale -Token $StorageToken }
    return $entities.Count
}

function Get-MonthBudgetList {
    param($Overview, [Parameter(Mandatory)][ValidateSet('Rg', 'Tag')][string]$Kind, [Parameter(Mandatory)][string]$StorageToken)
    if (-not $Overview) { return @() }
    $countProp = "${Kind}BudgetRows"
    if ($null -ne $Overview.$countProp) {
        $n = [int]$Overview.$countProp
        if ($n -le 0) { return @() }
        $rows = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthbudgets' and RowKey ge '$Kind|' and RowKey lt '$Kind|~'" -Token $StorageToken |
            Where-Object { [int](([string]$_.RowKey -split '\|')[1]) -lt $n } | Sort-Object RowKey)
        return @($rows | ForEach-Object { @([string]$_.ItemsJson | ConvertFrom-Json) })
    }
    $inline = [string]$Overview."${Kind}BudgetsJson"
    if ($inline) { return @($inline | ConvertFrom-Json) }
    return @()
}

Export-ModuleMember -Function `
    Get-PeriodKey, Get-PeriodBounds, Get-UtcMonthStart, Test-PeriodComplete, Get-CompletePeriodKeys, `
    ConvertTo-PeriodRows, Get-PeriodBaselineCount, Get-PeriodRetentionFloorDays, `
    Get-RollingWindows, Get-RollingWindowEndDate, `
    ConvertTo-DimensionRows, Measure-DailyDimensionCost, Measure-DimensionBaseline, `
    Find-CostSpike, Select-UnexplainedSpike, `
    Measure-ExitRunRate, Test-ExitRunRateResolved, Measure-BaselineCoverage, Add-DailySeriesRows, `
    Get-ResourceContext, ConvertTo-PseudonymousActor, Resolve-CostColumn, `
    Get-NarrationKey, Test-NarrativeGrounding, `
    Get-CostQueryDimensions, Invoke-CostQuery, Get-DailyResourceCost, Get-SubscriptionDailyCost, Invoke-CostQueryRest, `
    Save-MonthBudgetList, Get-MonthBudgetList, `
    Resolve-QueryWindow, Get-PreviousQueryWindow, Merge-CostComparisonRows, Invoke-CostComparison, `
    Select-SpecSubscriptions, Merge-SubscriptionCostRows, Invoke-CostQueryAcrossSubscriptions, `
    Find-SubscriptionsInText, Set-SpecSubscriptions, Invoke-StoredCostQuery, `
    Get-BillingCurrency, `
    Test-CostQueryThrottled, Get-InteractiveQueryPolicy, Get-CostTypeSetting, `
    Get-CostTotalSeries, Get-CostForecast, Get-ConsumptionBudgets, `
    ConvertTo-BudgetItems, Set-CostScopeInsufficient, `
    Get-CommitmentCoveredResources, Find-CoveringManagementGroup, Update-ResolvedCostScope, Get-ResolvedCostScope
