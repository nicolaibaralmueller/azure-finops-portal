param($Timer)

Write-Host "=== Cost change detection started ==="

# DETECTION AT PERIOD GRAIN — weekly and monthly, over COMPLETE periods only.
#
# This is an analysis tool, not an alerting one. A one-day spike is over before anyone looks
# and is usually a batch job or a billing artefact; the money is in sustained change — a
# resource that costs materially more this month than it did the months before. Daily
# detection was removed for that reason, along with the things that only made sense at daily
# grain (AzureActivity correlation, reservation-installment suppression).
#
# Two deterministic stages (CostAnalysis.psm1), then evidence and explanation per finding
# (CostEvidence.psm1): the evidence is gathered by code, and the model — when configured —
# only explains the change from that evidence and must cite it:
#
#   1. ROLL UP   Newly-complete periods are aggregated from CostSnapshots into CostPeriods —
#                one row per (period, resource) instead of one per (day, resource). This is
#                what makes period detection affordable: a monthly baseline spans ~4 months,
#                and loading that many raw daily rows for a large tenant is millions of rows.
#                Rolling up reads ONE DAY AT A TIME so memory stays bounded, and each period
#                is rolled up once, the day after it ends.
#
#   2. DETECT    For each grain, the latest complete period vs the MEDIAN of the prior
#                complete periods, at resource / meter / subscription dimensions, with the
#                rollups de-duplicated against resource findings. Identical pipeline to
#                before — period rows are just re-stamped daily rows (ConvertTo-PeriodRows).
#
#   3. EVIDENCE  For the largest findings: what drove each change and what was changed
#                (Get-CostChangeEvidence), stored on the finding and shown without AI.
#
#   4. EXPLAIN   Invoke-CostChangeExplanation, only for findings that have evidence.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# --- per-period thresholds ---
# A $25 jump is meaningful in a day and noise in a month, so each grain has its own gates.
# Percentages tighten as the window widens: longer periods are more stable, so a smaller
# relative move is more significant.
$thresholds = @{
    week  = @{ MinDeltaUsd = 150.0; MinDeltaPct = 25.0 }
    month = @{ MinDeltaUsd = 500.0; MinDeltaPct = 15.0 }
}
# How many findings per grain get evidence gathered (largest first). Each costs one or two Cost
# Management queries — the tightest rate limit in the app — so it is bounded. 0 = none.
$evidenceMax = 10
try {
    $cfg = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $storageToken) | Select-Object -First 1
    if ($cfg) {
        if ($null -ne $cfg.EvidenceMaxFindings) { $evidenceMax = [int][Math]::Max(0, [Math]::Min(30, [int]$cfg.EvidenceMaxFindings)) }
        if ($null -ne $cfg.WeekMinDeltaUsd)  { $thresholds.week.MinDeltaUsd   = [double]$cfg.WeekMinDeltaUsd }
        if ($null -ne $cfg.WeekMinDeltaPct)  { $thresholds.week.MinDeltaPct   = [double]$cfg.WeekMinDeltaPct }
        if ($null -ne $cfg.MonthMinDeltaUsd) { $thresholds.month.MinDeltaUsd  = [double]$cfg.MonthMinDeltaUsd }
        if ($null -ne $cfg.MonthMinDeltaPct) { $thresholds.month.MinDeltaPct  = [double]$cfg.MonthMinDeltaPct }
    }
} catch { Write-Host "PortalConfig read failed, using default thresholds: $($_.Exception.Message)" }

# --- check today's ingest (no waiting) ---
# This used to sleep up to 10 minutes for the ingest marker, holding one of the worker's three
# slots while the portal API and the platform health check queued behind it. Detection works
# on closed periods, so it no longer waits: when today's ingest hasn't reported yet, the run
# still detects (flagged DataComplete = false on the dashboard) but does NOT cache a month
# rollup — the ingest may still be rewriting the month's last days, and a cached rollup is
# never recomputed. That is why this timer starts at 02:40, after the 02:00 ingest normally
# finishes (it ran 20-27 minutes in Oct/Nov 2026): at 02:20 it never saw the ingest complete, so
# no month was ever rolled up. If the ingest still overruns, see the rollup safety window below.
$ingest = Wait-ForIngestCompletion -Token $storageToken -MaxWaitMinutes 0
$ingestComplete = $ingest.Complete
$ingestReported = $ingestComplete -or [bool]$ingest.Reported
if (-not $ingestComplete) { Write-Host "Proceeding with an incomplete ingest: $($ingest.Reason)" }

$today = [datetime]::UtcNow.Date

# The operator's subscription scope. Rollups in CostPeriods deliberately cover EVERY subscription
# (so a scope change never invalidates the cache); rows of excluded subscriptions are dropped when
# detection reads them, below, so neither the current period nor a baseline ever contains them.
$subScope = Get-SubscriptionScope -Token $storageToken
$allocKeys = @(Get-AllocationTagKeys -StorageToken $storageToken)

# ============================================================================
# STAGE 1 — roll newly-complete periods up into CostPeriods
# ============================================================================
# Reads one day at a time and accumulates, so peak memory is a single day of snapshots plus
# one entry per resource — not the whole period. Each period is written once; the marker in
# PortalConfig/'rollup' stops it being recomputed every night.
function Update-PeriodRollup {
    param(
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType,
        [Parameter(Mandatory)][string]$PeriodKey,
        [Parameter(Mandatory)][string]$Token
    )
    $bounds = Get-PeriodBounds -PeriodKey $PeriodKey -PeriodType $PeriodType
    # Keyed by (resource, meter label), NOT by resource alone. Each snapshot day labels a resource
    # with its largest meter category that day; keeping only the first day's label put the whole
    # month under it. A VM whose Defender plan was switched off on the 12th was labelled
    # 'Microsoft Defender for Cloud' on the 1st, so its entire month — compute and disk after the
    # 12th included — landed in the Defender meter rollup.
    $acc = @{}   # "dimensionKey|meter" -> accumulated row
    $days = 0
    for ($d = $bounds.Start; $d -le $bounds.End; $d = $d.AddDays(1)) {
        $dayKey = $d.ToString('yyyy-MM-dd')
        $rows = @()
        try {
            $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $Token)
        } catch {
            Write-Host "  rollup: reading $dayKey failed: $($_.Exception.Message)"
            throw   # a partial period would understate; let the caller skip and retry tomorrow
        }
        if ($rows.Count) { $days++ }
        foreach ($r in $rows) {
            $k = [string]$r.DimensionKey
            if (-not $k) { continue }
            $ak = "$k|$([string]$r.Meter)"
            if (-not $acc.ContainsKey($ak)) {
                $acc[$ak] = [PSCustomObject]@{ DimensionKey = $k; Scope = [string]$r.Scope; ResourceId = [string]$r.ResourceId; Meter = [string]$r.Meter; CostUsd = 0.0 }
            }
            $acc[$ak].CostUsd += [double]$r.CostUsd
        }
    }
    if (-not $acc.Count) { return 0 }

    # COVERAGE GATE. A period is only rolled up when snapshots exist for EVERY day of it.
    # Without this, a period that the data only partly covers — the month ingest started
    # mid-way through, say — gets cached as though it were whole, and then serves as a
    # baseline. June built from three days would make July look like a 10x increase, and the
    # marker would stop it ever being recomputed. Better to have no monthly view for a few
    # weeks than a confidently wrong one.
    $expectedDays = ($bounds.End - $bounds.Start).Days + 1
    if ($days -lt $expectedDays) {
        Write-Host "  rollup: skipping $PeriodType $PeriodKey — only $days of $expectedDays days have snapshots (period not fully covered)."
        return 0
    }

    # A rebuild (older rollup format) must not leave the previous rows next to the new ones:
    # their RowKeys differ, so both would be summed.
    $old = @(Get-TableEntities -Table 'CostPeriods' -Filter "PartitionKey eq '$PeriodType|$PeriodKey'" -Select 'PartitionKey,RowKey' -Token $Token)
    if ($old.Count) { [void](Remove-TableEntityBatch -Table 'CostPeriods' -Entities $old -Token $Token) }

    $entities = foreach ($e in $acc.Values) {
        @{
            PartitionKey = "$PeriodType|$PeriodKey"
            RowKey       = (Get-ShortHash -Value "$($e.DimensionKey)|$($e.Meter)")
            PeriodType   = $PeriodType
            Period       = $PeriodKey
            DimensionKey = $e.DimensionKey
            Scope        = $e.Scope
            ResourceId   = $e.ResourceId
            Meter        = $e.Meter
            CostUsd      = [Math]::Round([double]$e.CostUsd, 4)
            DaysWithData = $days
        }
    }
    Set-TableEntityBatch -Table 'CostPeriods' -Entities @($entities) -Token $Token
    return @($entities).Count
}

# Which complete periods exist in the retained snapshot window, and which still need rolling up.
$retentionFloor = Get-PeriodRetentionFloorDays
$scanFrom = $today.AddDays(-$retentionFloor)
# Rollup format. 2 = one row per (resource, meter label) — see Update-PeriodRollup. A marker
# from an older format is rebuilt while the month is still one detection reads (the target month
# plus its baseline), so a format fix reaches the live comparison without a manual reset.
$rollupVersion = 2
$existingRollups = @{}
try {
    foreach ($m in @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'rollup'" -Select 'RowKey,RollupVersion' -Token $storageToken)) {
        $existingRollups[[string]$m.RowKey] = if ($null -ne $m.RollupVersion) { [int]$m.RollupVersion } else { 1 }
    }
} catch { Write-Host "rollup marker read failed (periods may be recomputed): $($_.Exception.Message)" }

# Only MONTHS are rolled up. The weekly grain is a trailing 7-day window whose bounds move
# every night, so a cached calendar rollup would never be reused — it is computed directly
# from CostSnapshots below, with the same one-day-at-a-time streaming.
$rollupTypes = @('month')
# A period is safe to cache once the ingest can no longer rewrite any of its days. When today's
# ingest has reported, that is every complete period. When it hasn't (the ingest starts at 02:00
# and usually ends by ~02:27, before this timer's 02:40 start, but a slow night can overrun),
# only periods that ended before the ingest's
# nightly rewrite window — the last BaselineDays + 2 days, see the cost ingest (CostIngest.psm1) — are safe.
# Skipping outright instead meant a month was NEVER rolled up while the ingest kept finishing late.
$rollupSafeBefore = $today
if (-not $ingestReported) {
    $ingestBaselineDays = 7
    try {
        $cfg = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $storageToken) | Select-Object -First 1
        if ($cfg -and $null -ne $cfg.BaselineDays) { $ingestBaselineDays = [int]$cfg.BaselineDays }
    } catch {}
    $rollupSafeBefore = $today.AddDays(-($ingestBaselineDays + 2))
    Write-Host "  rollup: today's ingest hasn't reported — only rolling up periods that ended before $($rollupSafeBefore.ToString('yyyy-MM-dd')), outside the ingest's rewrite window."
}
foreach ($periodType in $rollupTypes) {
    # Enumerate candidate periods by walking the retained date range, not by scanning rows.
    $candidates = @{}
    for ($d = $scanFrom; $d -le $today; $d = $d.AddDays(1)) { $candidates[(Get-PeriodKey -Date $d -PeriodType $periodType)] = $true }
    $complete = @($candidates.Keys | Where-Object { Test-PeriodComplete -PeriodKey $_ -PeriodType $periodType -Today $today } | Sort-Object)
    # The months detection reads: the newest complete one and its baseline.
    $inUse = @($complete | Select-Object -Last ((Get-PeriodBaselineCount -PeriodType $periodType) + 1))

    foreach ($pk in $complete) {
        $rk = "$periodType|$pk"
        if ($existingRollups.ContainsKey($rk)) {
            if ($existingRollups[$rk] -ge $rollupVersion -or $pk -notin $inUse) { continue }
            Write-Host "  rollup: rebuilding $periodType $pk — stored in rollup format $($existingRollups[$rk]), current is $rollupVersion."
        }
        # Don't roll up a period whose start predates the retained snapshots — it would be
        # built from partial data and then cached as if it were whole.
        $bounds = Get-PeriodBounds -PeriodKey $pk -PeriodType $periodType
        if ($bounds.End -ge $rollupSafeBefore) {
            Write-Host "  rollup: deferring $periodType $pk — its last days may still be rewritten by an ingest that hasn't reported."
            continue
        }
        if ($bounds.Start -lt $scanFrom) {
            Write-Host "  rollup: skipping $periodType $pk — starts before the retained snapshot window."
            continue
        }
        try {
            $n = Update-PeriodRollup -PeriodType $periodType -PeriodKey $pk -Token $storageToken
            if ($n -gt 0) {
                Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{
                    PartitionKey = 'rollup'; RowKey = "$periodType|$pk"; PeriodType = $periodType; Period = $pk
                    Dimensions = $n; RollupVersion = $rollupVersion; At = ([datetime]::UtcNow.ToString('o'))
                }
                Write-Host "  rollup: $periodType $pk -> $n resource row(s)."
            }
        } catch { Write-Host "  rollup: $periodType $pk failed, will retry next run: $($_.Exception.Message)" }
    }
}

# ============================================================================
# STAGE 2 — detect, per grain
# ============================================================================
$mgmtToken = $null
try { $mgmtToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/' } catch { Write-Host "mgmt token failed: $($_.Exception.Message)" }

$subNames = @{}
if ($mgmtToken) {
    try { foreach ($s in @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken)) { $subNames[$s.Id.ToLower()] = $s.Name } }
    catch { Write-Host "subscription name lookup failed (scopes will show as ids): $($_.Exception.Message)" }
}

$aiConfigured = Test-AiConfigured
if (-not $aiConfigured) { Write-Host "AI not configured — findings are stored with their evidence but without a written explanation." }
$costType = Get-CostTypeSetting -StorageToken $storageToken

# One evidence budget for the whole run (both grains). Evidence is worth having but never worth
# the detection results: a throttled Cost Management API must not push this timer towards its
# 30-minute limit. Findings past the deadline are stored with EvidenceStatus 'skipped'.
$evidenceDeadline = [datetime]::UtcNow.AddMinutes(8)
# Set once the daily AI limit is hit, so the rest of the run stops asking.
$aiStopped = $false

# Read one period's rollup rows back in the shape the detection pipeline expects (Date holds
# the period key, exactly as ConvertTo-PeriodRows produces).
function Get-PeriodRows {
    param([string]$PeriodType, [string]$PeriodKey, [string]$Token)
    $rows = @(Get-TableEntities -Table 'CostPeriods' -Filter "PartitionKey eq '$PeriodType|$PeriodKey'" -Token $Token)
    $rows = @(Select-InSubscriptionScope -Scope $subScope -Rows $rows)
    return @($rows | ForEach-Object {
        [PSCustomObject]@{
            Date = [string]$_.Period; DimensionKey = $_.DimensionKey
            Scope = $_.Scope; ResourceId = $_.ResourceId; Meter = $_.Meter; CostUsd = $_.CostUsd
        }
    })
}

# Read the trailing rolling windows straight from CostSnapshots, one day at a time so peak
# memory stays a single day plus one accumulator per (window, resource). Every window must be
# fully covered by data: a missing day in the current window under-reports a change, and a
# missing day in a baseline window manufactures one.
function Get-RollingWindowRows {
    param($Windows, [string]$Token)
    $from = @($Windows | Sort-Object Start | Select-Object -First 1).Start
    $to   = @($Windows | Sort-Object End -Descending | Select-Object -First 1).End
    $acc = @{}
    $daysWithData = @{}
    for ($d = $from; $d -le $to; $d = $d.AddDays(1)) {
        $w = @($Windows | Where-Object { $d -ge $_.Start -and $d -le $_.End }) | Select-Object -First 1
        if (-not $w) { continue }
        $dayKey = $d.ToString('yyyy-MM-dd')
        $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $Token)
        # Coverage is judged on the unfiltered day (did the ingest run?), then the scope applies.
        if ($rows.Count) { $daysWithData[$dayKey] = $true }
        $rows = @(Select-InSubscriptionScope -Scope $subScope -Rows $rows)
        foreach ($r in $rows) {
            $dk = [string]$r.DimensionKey
            if (-not $dk) { continue }
            $k = "$($w.Key)|$dk"
            if (-not $acc.ContainsKey($k)) {
                $acc[$k] = [PSCustomObject]@{ Date = $w.Key; DimensionKey = $dk; Scope = [string]$r.Scope
                    ResourceId = [string]$r.ResourceId; Meter = [string]$r.Meter; CostUsd = 0.0 }
            }
            $acc[$k].CostUsd += [double]$r.CostUsd
        }
    }
    $expected = ($to - $from).Days + 1
    return [PSCustomObject]@{ Rows = @($acc.Values); DaysCovered = $daysWithData.Count; DaysExpected = $expected }
}

# Daily cost of a few keys across one period, from CostSnapshots one day at a time (the same
# streaming as the rollup). Returns key -> double[days]; empty when a day cannot be read, since a
# series with a hole would read as a drop to zero.
function Get-PeriodDailySeries {
    param([datetime]$Start, [datetime]$End, [string[]]$Keys, [string]$Token)
    $wanted = @{}
    foreach ($k in $Keys) { if ($k) { $wanted[$k] = $true } }
    $n = ($End - $Start).Days + 1
    $series = @{}
    if (-not $wanted.Count) { return $series }
    for ($i = 0; $i -lt $n; $i++) {
        $dayKey = $Start.AddDays($i).ToString('yyyy-MM-dd')
        try { $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $Token) }
        catch { Write-Host "  daily series: reading $dayKey failed, no within-period shape this run: $($_.Exception.Message)"; return @{} }
        if (-not $rows.Count) { Write-Host "  daily series: no snapshots for $dayKey, no within-period shape this run."; return @{} }
        $rows = @(Select-InSubscriptionScope -Scope $subScope -Rows $rows)
        Add-DailySeriesRows -Series $series -Wanted $wanted -Rows $rows -DayIndex $i -DayCount $n
    }
    return $series
}

$analyses = @()

# Why a grain produced nothing. Without this the UI can only say "not analysed yet", which
# reads as "wait for tonight" even when the real answer is "there isn't enough history and
# there won't be until <date>". One row per grain; the reason travels to the page verbatim.
function Set-AnalysisStatus {
    param(
        [Parameter(Mandatory)][string]$PeriodType,
        [Parameter(Mandatory)][ValidateSet('ok', 'skipped')][string]$Status,
        [string]$Period = '',
        [string]$Reason = '',
        [string]$Detail = ''
    )
    try {
        Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{
            PartitionKey = 'analysisstatus'; RowKey = $PeriodType
            PeriodType = $PeriodType; Status = $Status; Period = $Period
            Reason = $Reason; Detail = $Detail
            MinDeltaUsd = [double]$thresholds[$PeriodType].MinDeltaUsd
            MinDeltaPct = [double]$thresholds[$PeriodType].MinDeltaPct
            At = ([datetime]::UtcNow.ToString('o'))
        }
    } catch { Write-Host "analysis-status write failed for ${PeriodType}: $($_.Exception.Message)" }
}

# --- weekly: trailing 7 days vs the 4 preceding non-overlapping 7-day windows ---
$windowEnd = Get-RollingWindowEndDate -Today $today
$windows = Get-RollingWindows -EndDate $windowEnd -WindowDays 7 -Count ((Get-PeriodBaselineCount -PeriodType 'week') + 1)
$rolling = Get-RollingWindowRows -Windows $windows -Token $storageToken
if ($rolling.DaysCovered -lt $rolling.DaysExpected) {
    Write-Host "week : only $($rolling.DaysCovered) of $($rolling.DaysExpected) days have snapshots — not enough history for a trailing comparison yet. Skipping."
    # Shown on the page as is, so in the portal's language (Text.psm1).
    Set-AnalysisStatus -PeriodType 'week' -Status 'skipped' -Reason 'insufficient-history' -Detail (
        Get-PortalText 'status.week.history' @{ need = $rolling.DaysExpected; have = $rolling.DaysCovered })
} else {
    $cur = @($windows | Where-Object { $_.Index -eq 0 })[0]
    $analyses += [PSCustomObject]@{
        PeriodType  = 'week'
        Key         = $cur.Key
        Start       = $cur.Start
        End         = $cur.End
        Label       = "$($cur.Start.ToString('yyyy-MM-dd')) .. $($cur.End.ToString('yyyy-MM-dd'))"
        Current     = @($rolling.Rows | Where-Object { $_.Date -eq $cur.Key })
        Baseline    = @($rolling.Rows | Where-Object { $_.Date -ne $cur.Key })
        BaselineN   = $windows.Count - 1
        # For the evidence queries: the same windows detection compared against.
        BaselineRanges = @($windows | Where-Object { $_.Index -gt 0 } | ForEach-Object { @{ Start = $_.Start; End = $_.End } })
        Granularity = 'Daily'
    }
}

# --- monthly: latest complete calendar month vs the prior complete months ---
$monthKeys = @(@(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'rollup'" -Select 'RowKey' -Token $storageToken) |
    Where-Object { [string]$_.RowKey -like 'month|*' } | ForEach-Object { (([string]$_.RowKey) -split '\|', 2)[1] } | Sort-Object -Unique)
if ($monthKeys.Count -lt 2) {
    Write-Host "month : only $($monthKeys.Count) complete month(s) rolled up — need at least 2 to compare. Skipping."
    # A month is only meaningful against the months before it, so the very first complete month
    # can never be analysed — it becomes the baseline for the next one. Say when that is,
    # otherwise the page implies tonight's run will fix it.
    $nextClose = (Get-UtcMonthStart -Date $today).AddMonths(1)
    $have = if ($monthKeys.Count) { " ($($monthKeys -join ', '))" } else { '' }
    $key = if ($monthKeys.Count -eq 1) { 'status.month.baseline1' } else { 'status.month.baselineN' }
    Set-AnalysisStatus -PeriodType 'month' -Status 'skipped' -Reason 'needs-baseline' -Detail (
        Get-PortalText $key @{ n = $monthKeys.Count; list = $have
            month = $today.ToString('MMMM yyyy', (Get-PortalCulture)); date = $nextClose.AddDays(-1).ToString('yyyy-MM-dd') })
} else {
    $targetKey = $monthKeys[-1]
    $baselineKeys = @($monthKeys[0..($monthKeys.Count - 2)] | Select-Object -Last (Get-PeriodBaselineCount -PeriodType 'month'))
    $bounds = Get-PeriodBounds -PeriodKey $targetKey -PeriodType 'month'
    $baseRows = @()
    foreach ($bk in $baselineKeys) { $baseRows += Get-PeriodRows -PeriodType 'month' -PeriodKey $bk -Token $storageToken }
    $analyses += [PSCustomObject]@{
        PeriodType  = 'month'
        Key         = $targetKey
        Start       = $bounds.Start
        End         = $bounds.End
        Label       = $targetKey
        Current     = Get-PeriodRows -PeriodType 'month' -PeriodKey $targetKey -Token $storageToken
        Baseline    = $baseRows
        BaselineN   = $baselineKeys.Count
        BaselineRanges = @($baselineKeys | ForEach-Object { $mb = Get-PeriodBounds -PeriodKey $_ -PeriodType 'month'; @{ Start = $mb.Start; End = $mb.End } })
        Granularity = 'Monthly'
    }
}

foreach ($a in $analyses) {
    $periodType = $a.PeriodType
    $minUsd = [double]$thresholds[$periodType].MinDeltaUsd
    $minPct = [double]$thresholds[$periodType].MinDeltaPct
    $targetKey = $a.Key
    Write-Host "$periodType : analysing $($a.Label) against $($a.BaselineN) prior window(s) (>= `$$minUsd AND >= $minPct%)."

    $currentRows  = @($a.Current)
    $baselineRows = @($a.Baseline)
    if (-not $currentRows.Count) {
        Write-Host "  no rows for $targetKey — skipping."
        Set-AnalysisStatus -PeriodType $periodType -Status 'skipped' -Period $targetKey -Reason 'no-data' -Detail (
            Get-PortalText 'status.noData' @{ period = $a.Label })
        continue
    }

    # -Dimension keys inline rather than building a re-keyed copy of every row first: three
    # dimensions over several periods made those copies the largest thing in memory.
    $current  = Measure-DailyDimensionCost -Rows $currentRows  -Dimension 'resource'
    $baseline = Measure-DimensionBaseline  -Rows $baselineRows -Dimension 'resource'
    $findings = @(Find-CostSpike -Current $current -Baseline $baseline -MinDeltaUsd $minUsd -MinDeltaPct $minPct -Dimension 'resource')
    Write-Host "  resource grain: $($findings.Count) finding(s)."

    foreach ($dim in @('meter', 'subscription')) {
        $dimCurrent  = Measure-DailyDimensionCost -Rows $currentRows  -Dimension $dim
        $dimBaseline = Measure-DimensionBaseline  -Rows $baselineRows -Dimension $dim
        $found = @(Find-CostSpike -Current $dimCurrent -Baseline $dimBaseline -MinDeltaUsd $minUsd -MinDeltaPct $minPct -Dimension $dim)
        $kept  = @(Select-UnexplainedSpike -RollupSpikes $found -ResourceSpikes $findings -MinDeltaUsd $minUsd)
        Write-Host "  $dim grain: $($found.Count) flagged, $($kept.Count) not already explained by a resource finding."
        $findings = @(@($findings) + @($kept))
    }
    $findings = @($findings | Sort-Object -Property DeltaUsd -Descending)

    # --- how each monthly finding moved WITHIN the month ---
    # A month is compared as one total, so a service that ran at full cost for twelve days and
    # was then switched off still reads as "more than a typical month". The daily shape says
    # where the month ENDED: when that level would not be flagged, the increase has already
    # fallen back and the finding is marked Resolved instead of being shown as open.
    if ($periodType -eq 'month' -and $findings.Count) {
        $coverage = @{}
        foreach ($dim in @('resource', 'meter', 'subscription')) { $coverage[$dim] = Measure-BaselineCoverage -Rows $baselineRows -Dimension $dim }
        $series = Get-PeriodDailySeries -Start $a.Start -End $a.End -Keys @($findings | ForEach-Object { [string]$_.DimensionKey }) -Token $storageToken
        $resolvedCount = 0
        foreach ($f in $findings) {
            $cov = $coverage[[string]$f.Dimension]
            $f | Add-Member -NotePropertyName BaselinePeriods -NotePropertyValue $(if ($cov -and $cov.ContainsKey([string]$f.DimensionKey)) { [int]$cov[[string]$f.DimensionKey] } else { 0 }) -Force
            $f | Add-Member -NotePropertyName BaselinePeriodsOf -NotePropertyValue ([int]$a.BaselineN) -Force
            $daily = $series[[string]$f.DimensionKey]
            if (-not $daily) { continue }
            $m = Measure-ExitRunRate -Daily $daily
            if (-not $m) { continue }
            $resolved = Test-ExitRunRateResolved -ExitRunRateUsd $m.ExitRunRateUsd -BaselineUsd ([double]$f.BaselineUsd) -MinDeltaUsd $minUsd -MinDeltaPct $minPct
            if ($resolved) { $resolvedCount++ }
            $f | Add-Member -NotePropertyName ExitRunRateUsd -NotePropertyValue ([double]$m.ExitRunRateUsd) -Force
            $f | Add-Member -NotePropertyName SteppedDownOn -NotePropertyValue $(if ($null -ne $m.StepDownIndex) { $a.Start.AddDays($m.StepDownIndex).ToString('yyyy-MM-dd') } else { '' }) -Force
            $f | Add-Member -NotePropertyName DailyBeforeUsd -NotePropertyValue $m.BeforeDailyUsd -Force
            $f | Add-Member -NotePropertyName DailyAfterUsd -NotePropertyValue $m.AfterDailyUsd -Force
            $f | Add-Member -NotePropertyName Resolved -NotePropertyValue ([bool]$resolved) -Force
        }
        Write-Host "  within-month shape: $($series.Count) of $($findings.Count) finding(s) measured, $resolvedCount already back below the bar at month end."
    }

    foreach ($f in $findings) {
        $f | Add-Member -NotePropertyName ScopeName -NotePropertyValue ([string]$subNames[([string]$f.Scope).ToLower()]) -Force
    }

    $nameMap = @{}
    if ($mgmtToken -and $findings.Count) {
        $nameMap = Resolve-ResourceDisplayNames -ResourceIds @($findings | ForEach-Object { $_.ResourceId }) -MgmtToken $mgmtToken
    }

    # Narratives already stored for this period, so an unchanged finding isn't explained twice
    # on the customer's AI key. This period is re-analysed on every nightly run for as long as
    # it is the newest of its grain — the latest complete month for up to ~30 nights — and
    # every one of those runs used to pay for a fresh explanation of identical figures.
    # See Get-NarrationKey in CostAnalysis.psm1 for why a hit is safe.
    $storedNarratives = @{}
    try {
        foreach ($e in @(Get-TableEntities -Table 'CostSpikes' -Filter "PartitionKey eq '$periodType|$targetKey'" -Token $storageToken)) {
            $storedNarratives[[string]$e.RowKey] = $e
        }
    } catch { Write-Host "  stored-narrative read failed for $periodType $targetKey (they will be regenerated): $($_.Exception.Message)" }

    # Bounds come from the analysis: a calendar month's own range, or the rolling window's.
    $bounds = @{ Start = $a.Start; End = $a.End }

    # --- pass 1: evidence ----------------------------------------------------------------
    # What drove each change: meter / resource / service breakdown, the volume-vs-price split,
    # and the change log (CostEvidence.psm1). Gathered for the largest findings only, inside
    # the run's evidence time budget. A month is re-analysed every night until the next one
    # closes, so complete evidence stored for this period is reused rather than re-queried.
    $contexts = @{}
    $evidenceById = @{}
    $evidenceStatus = @{}
    $evGathered = 0; $evReused = 0; $evSkipped = 0
    for ($i = 0; $i -lt $findings.Count; $i++) {
        $f = $findings[$i]
        $ctx = if ($mgmtToken -and $f.ResourceId) { Get-ResourceContext -ResourceId $f.ResourceId -MgmtToken $mgmtToken } else { $null }
        $contexts[$f.Id] = $ctx
        $resourceName = [string]$nameMap[([string]$f.ResourceId).ToLower()]
        if (-not $resourceName -and $ctx -and $ctx.name) { $resourceName = [string]$ctx.name }
        $f | Add-Member -NotePropertyName ResourceName -NotePropertyValue $resourceName -Force
        $f | Add-Member -NotePropertyName PeriodType -NotePropertyValue $periodType -Force

        $prior = $storedNarratives[[string]$f.Id]
        if ($prior -and $prior.EvidenceJson -and [string]$prior.EvidenceStatus -eq 'complete') {
            try {
                $stored = [string]$prior.EvidenceJson | ConvertFrom-Json
                # Evidence gathered by an older version lacks what the current one collects.
                if ([int]$stored.version -ge (Get-CostEvidenceVersion)) {
                    $evidenceById[$f.Id] = $stored
                    $evidenceStatus[$f.Id] = 'complete'
                    $evReused++
                    continue
                }
            } catch { Write-Host "  stored evidence for $($f.Id) is unreadable — gathering it again." }
        }
        if ($i -ge $evidenceMax -or -not $mgmtToken -or [datetime]::UtcNow -ge $evidenceDeadline) {
            $evidenceStatus[$f.Id] = 'skipped'
            $evSkipped++
            continue
        }
        $ev = Get-CostChangeEvidence -Finding $f -MgmtToken $mgmtToken -CurrentStart $a.Start -CurrentEnd $a.End `
            -BaselineRanges $a.BaselineRanges -Granularity $a.Granularity -ResourceContext $ctx `
            -CostType $costType -Deadline $evidenceDeadline
        $evidenceById[$f.Id] = $ev
        $evidenceStatus[$f.Id] = if ($ev.complete) { 'complete' } else { 'partial' }
        $evGathered++
    }

    # Names for every resource the evidence mentions, in one batched lookup.
    $idsNeeded = @($evidenceById.Values | ForEach-Object { Get-EvidenceResourceIds -Evidence $_ } |
        Sort-Object -Unique | Where-Object { -not $nameMap.ContainsKey($_.ToLower()) })
    if ($mgmtToken -and $idsNeeded.Count) {
        try {
            $more = Resolve-ResourceDisplayNames -ResourceIds $idsNeeded -MgmtToken $mgmtToken
            foreach ($k in @($more.Keys)) { $nameMap[$k] = $more[$k] }
        } catch { Write-Host "  evidence name lookup failed: $($_.Exception.Message)" }
    }
    foreach ($ev in $evidenceById.Values) { Set-EvidenceResourceNames -Evidence $ev -NameMap $nameMap }

    # --- pass 2: explanation + persist ---------------------------------------------------
    # The model explains a change only FROM its evidence and must cite it; a finding without
    # evidence gets no written explanation at all rather than a guess. An unchanged request
    # reuses the stored explanation (NarrationKey, see Get-NarrationKey).
    # Who owns each resource-level change (Allocation.psm1). Rollups (meter, subscription) have
    # no single owner and carry none.
    $tagIndex = @{}
    $resIds = @($findings | Where-Object { [string]$_.ResourceId -match '(?i)/providers/' } | ForEach-Object { [string]$_.ResourceId })
    if ($mgmtToken -and $resIds.Count) {
        $tagIndex = Get-ResourceTagIndex -MgmtToken $mgmtToken -SubscriptionIds @($subNames.Keys) -ResourceIds $resIds -Aliases (Get-AllocationValueAliases -StorageToken $storageToken)
    }
    $entities = @()
    $narrated = 0; $reused = 0; $failed = 0
    foreach ($f in $findings) {
        $ev = $evidenceById[$f.Id]
        $prior = $storedNarratives[[string]$f.Id]
        $x = $null
        # How the cost moved within the period. Recomputed every run, so it is set on reused
        # evidence too.
        if ($ev) { Set-EvidenceDailyShape -Evidence $ev -Finding $f }
        if ($ev) {
            $x = Invoke-CostChangeExplanation -Finding $f -ResourceContext $contexts[$f.Id] -Evidence $ev -StoredRow $prior -ReuseOnly:$aiStopped
            switch ($x.Status) {
                'reused'          { $reused++ }
                'explained'       { $narrated++ }
                'budget-exceeded' { $aiStopped = $true; Write-Host "  daily AI limit reached — remaining findings keep their evidence only. $($x.Error)" }
                'failed'          { $failed++; Write-Host "  explanation failed for $($f.Id): $($x.Error)" }
            }
        }
        $hasText = $x -and $x.Status -in @('reused', 'explained')

        $evidenceJson = ''
        if ($ev) {
            $evidenceJson = $ev | ConvertTo-Json -Depth 10 -Compress
            # Table string properties hold 32K characters; drop the oldest change-log facts first.
            while ($evidenceJson.Length -gt 30000 -and @($ev.facts).Count -gt 1) {
                $ev.facts = @($ev.facts | Select-Object -First (@($ev.facts).Count - 1))
                $evidenceJson = $ev | ConvertTo-Json -Depth 10 -Compress
            }
        }

        $entities += @{
            PartitionKey   = "$periodType|$targetKey"
            RowKey         = $f.Id
            PeriodType     = $periodType
            Period         = $targetKey
            PeriodStart    = $bounds.Start.ToString('yyyy-MM-dd')
            PeriodEnd      = $bounds.End.ToString('yyyy-MM-dd')
            Dimension      = [string]$f.Dimension
            Scope          = $f.Scope
            ScopeName      = if ($f.ScopeName) { [string]$f.ScopeName } else { '' }
            UnexplainedUsd = if ($null -ne $f.UnexplainedUsd) { [double]$f.UnexplainedUsd } else { -1 }
            ResourceId     = $f.ResourceId
            ResourceName   = [string]$f.ResourceName
            AllocationJson = if ([string]$f.ResourceId -match '(?i)/providers/') { ConvertTo-AllocationJson (Get-ResourceAllocation -Index $tagIndex -ResourceId $f.ResourceId -TagKeys $allocKeys) } else { '' }
            Meter          = $f.Meter
            BaselineUsd    = [Math]::Round([double]$f.BaselineUsd, 2)
            SpikeUsd       = [Math]::Round([double]$f.SpikeUsd, 2)
            DeltaUsd       = [Math]::Round([double]$f.DeltaUsd, 2)
            DeltaPct       = if ($null -ne $f.DeltaPct) { [Math]::Round([double]$f.DeltaPct, 1) } else { -1 }
            IsNew          = [bool]$f.IsNew
            # Within-period shape (monthly). -1 / '' = not measured. Resolved = the period ended
            # at a level that would not be flagged: the increase has already fallen back.
            ExitRunRateUsd = if ($null -ne $f.ExitRunRateUsd) { [Math]::Round([double]$f.ExitRunRateUsd, 2) } else { -1 }
            SteppedDownOn  = if ($f.SteppedDownOn) { [string]$f.SteppedDownOn } else { '' }
            Resolved       = [bool]$f.Resolved
            BaselinePeriods   = if ($null -ne $f.BaselinePeriods) { [int]$f.BaselinePeriods } else { -1 }
            BaselinePeriodsOf = if ($null -ne $f.BaselinePeriodsOf) { [int]$f.BaselinePeriodsOf } else { -1 }
            # Written as '' rather than left out: a MERGE keeps an omitted (or null) property,
            # and an explanation written for different evidence must not survive next to it.
            Headline       = if ($hasText) { [string]$x.Headline } else { '' }
            Cause          = if ($hasText) { [string]$x.Cause } else { '' }
            Recommendation = if ($hasText) { [string]$x.Recommendation } else { '' }
            CitedFactsJson = if ($hasText) { (@($x.CitedFacts) | ConvertTo-Json -Compress -AsArray) } else { '[]' }
            Explained      = [bool]($hasText -and $x.Explained)
            Grounded       = if ($hasText) { [bool]$x.Grounded } else { $true }
            Confidence     = ''     # retired: replaced by cited evidence
            NarrativeError = if ($x -and $x.Error) { ([string]$x.Error).Substring(0, [Math]::Min(500, ([string]$x.Error).Length)) } else { '' }
            ExplanationStatus = if ($x) { [string]$x.Status } else { 'no-evidence' }
            # Fingerprint of the explanation request. Written even without text so a later run
            # with the same evidence can tell nothing changed.
            NarrationKey   = if ($x -and $x.NarrationKey) { [string]$x.NarrationKey } else { '' }
            EvidenceJson   = $evidenceJson
            EvidenceStatus = if ($evidenceStatus.ContainsKey($f.Id)) { [string]$evidenceStatus[$f.Id] } else { 'none' }
            Kind           = 'usage'
            Status         = 'open'
            DetectedAt     = ([datetime]::UtcNow.ToString('o'))
        }
    }
    Set-TableEntityBatch -Table 'CostSpikes' -Entities $entities -Token $storageToken
    Write-Host ("$periodType : persisted $($entities.Count) finding(s) for $($a.Label) — evidence gathered $evGathered, reused $evReused, skipped $evSkipped; " +
                "explained $narrated, reused $reused, failed $failed.")

    # Pointer to the newest analysed window, so GetCostSpikes doesn't have to guess which one
    # exists — the rolling window's bounds move every night.
    Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{
        PartitionKey = 'latestperiod'; RowKey = $periodType
        Period = $targetKey; PeriodStart = $bounds.Start.ToString('yyyy-MM-dd'); PeriodEnd = $bounds.End.ToString('yyyy-MM-dd')
        At = ([datetime]::UtcNow.ToString('o'))
    }

    # "Analysed" must NOT be inferred from findings existing. A period that was analysed and
    # found clean has no rows, and reporting that as "not analysed yet" tells the user to wait
    # for something that already happened. This marker records the fact of the analysis,
    # separately from its result.
    Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{
        PartitionKey = 'analyzed'; RowKey = "$periodType|$targetKey"
        PeriodType = $periodType; Period = $targetKey
        PeriodStart = $bounds.Start.ToString('yyyy-MM-dd'); PeriodEnd = $bounds.End.ToString('yyyy-MM-dd')
        FindingCount = @($entities).Count
        At = ([datetime]::UtcNow.ToString('o'))
    }
    Set-AnalysisStatus -PeriodType $periodType -Status 'ok' -Period $targetKey
}

# ============================================================================
# RETENTION — everything this timer writes
# ============================================================================
# CostSnapshots was the only pruned table; everything below grew forever.
#
# The weekly grain is why it matters. Its window is a TRAILING 7 days whose key is the window
# end, so it moves nightly: every run creates a fresh CostSpikes partition plus an 'analyzed'
# marker, ~365 a year, and GetCostSpikes steps back in 7-day jumps so six of every seven are
# unreachable the day after they are written. They are still worth keeping for a while — each
# is the newest window for one day, and that is what the page shows — but not forever.
#
# NOT fixed by only persisting on a fixed weekday (the other option the notes floated): the
# page would then have nothing to show on six days out of seven, which is a worse product than
# some dead partitions.
#
# Two windows, because the tables have different readers:
#   CostSpikes + 'analyzed'  user-facing history. GetCostSpikes allows ?offset up to 24, which
#                            at month grain is two years, so keep more than that.
#   CostPeriods              an internal rollup cache that ONLY monthly detection reads, and it
#                            never looks back further than its baseline. Keeping it in step
#                            with the snapshot retention is the honest window; older rows have
#                            no reader at all.
# 'rollup' markers are deliberately NOT pruned: they are ~12 rows a year, and deleting one
# would invite a rebuild of a month whose data has just been dropped.
$spikeRetentionDays = 800
$maxDeletesPerRun   = 5000

# Newest day a stored period covers, or $null when the key isn't one we recognise — an
# unparseable key is never deleted, because "I don't understand this" must not mean "bin it".
# Handles legacy 'yyyy-Www' weekly keys from before the rolling window landed.
function Get-PeriodPartitionEnd {
    param([string]$Key)      # '<periodType>|<periodKey>'
    $parts = [string]$Key -split '\|', 2
    if ($parts.Count -ne 2) { return $null }
    $type = $parts[0]; $key = $parts[1]
    if ($type -eq 'week') {
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($key, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
        if ($key -match '^\d{4}-W\d{2}$') { try { return (Get-PeriodBounds -PeriodKey $key -PeriodType 'week').End } catch { return $null } }
        return $null
    }
    if ($type -eq 'month' -and $key -match '^\d{4}-\d{2}$') {
        try { return (Get-PeriodBounds -PeriodKey $key -PeriodType 'month').End } catch { return $null }
    }
    return $null
}

try {
    $spikeCutoff = $today.AddDays(-$spikeRetentionDays)

    # --- CostSpikes: findings past the retention window ---
    # A key-only scan is affordable here in a way it would not be on CostSnapshots: this table
    # holds a handful of rows per period, not ~16k a day.
    $spikeKeys = @(Get-TableEntities -Table 'CostSpikes' -Select 'PartitionKey,RowKey' -Top $maxDeletesPerRun -Token $storageToken)
    $expiredSpikes = @($spikeKeys | Where-Object {
        $end = Get-PeriodPartitionEnd -Key $_.PartitionKey
        $end -and $end -lt $spikeCutoff
    })
    if ($expiredSpikes.Count) {
        $n = Remove-TableEntityBatch -Table 'CostSpikes' -Entities $expiredSpikes -Token $storageToken
        Write-Host "retention: deleted $n finding row(s) for periods ending before $($spikeCutoff.ToString('yyyy-MM-dd'))."
    }

    # --- the 'analyzed' markers that pair with them ---
    $analyzedKeys = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'analyzed'" -Select 'PartitionKey,RowKey' -Top $maxDeletesPerRun -Token $storageToken)
    $expiredMarkers = @($analyzedKeys | Where-Object {
        $end = Get-PeriodPartitionEnd -Key $_.RowKey
        $end -and $end -lt $spikeCutoff
    })
    if ($expiredMarkers.Count) {
        $n = Remove-TableEntityBatch -Table 'PortalConfig' -Entities $expiredMarkers -Token $storageToken
        Write-Host "retention: deleted $n stale 'analyzed' marker(s)."
    }

    # --- CostPeriods: monthly rollups older than detection can reach ---
    # Driven off the rollup markers rather than a scan: they are the authoritative list of which
    # months exist, one tiny row each, so no enumeration of the (much larger) data is needed.
    $periodsRetention = 180
    if ($cfg -and $null -ne $cfg.SnapshotRetentionDays -and [int]$cfg.SnapshotRetentionDays -gt 0) { $periodsRetention = [int]$cfg.SnapshotRetentionDays }
    $periodsRetention = [Math]::Max($periodsRetention, (Get-PeriodRetentionFloorDays))
    $periodCutoff = $today.AddDays(-$periodsRetention)

    $deleted = 0
    foreach ($rk in @($existingRollups.Keys)) {
        if ($deleted -ge $maxDeletesPerRun) { Write-Host "retention: rollup prune capped for this run; continues tomorrow."; break }
        $end = Get-PeriodPartitionEnd -Key $rk
        if (-not $end -or $end -ge $periodCutoff) { continue }
        $rows = @(Get-TableEntities -Table 'CostPeriods' -Filter "PartitionKey eq '$rk'" -Select 'PartitionKey,RowKey' -Top ($maxDeletesPerRun - $deleted) -Token $storageToken)
        if ($rows.Count) { $deleted += Remove-TableEntityBatch -Table 'CostPeriods' -Entities $rows -Token $storageToken }
    }
    if ($deleted) { Write-Host "retention: deleted $deleted CostPeriods row(s) for months ending before $($periodCutoff.ToString('yyyy-MM-dd')) (keeping $periodsRetention days)." }
} catch { Write-Host "retention pass failed (non-fatal, retries next run): $($_.Exception.Message)" }

Write-Host "=== Cost change detection finished ==="
