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
    # Which days each resource / meter / subscription had cost, to spot a creation period
    # (Get-StartedSpanDays) — the baseline scales those to a whole month.
    $masks = @{ res = @{}; meter = @{}; sub = @{} }
    $days = 0
    for ($d = $bounds.Start; $d -le $bounds.End; $d = $d.AddDays(1)) {
        $dayIndex = ($d - $bounds.Start).Days
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
            if ([double]$r.CostUsd -gt 0) {
                Add-ActiveDay -Masks $masks.res -Key $k -DayIndex $dayIndex
                Add-ActiveDay -Masks $masks.meter -Key (Get-DimensionKey -Dimension 'meter' -Scope ([string]$r.Scope) -Meter ([string]$r.Meter)) -DayIndex $dayIndex
                Add-ActiveDay -Masks $masks.sub -Key (Get-DimensionKey -Dimension 'subscription' -Scope ([string]$r.Scope)) -DayIndex $dayIndex
            }
        }
    }
    if (-not $acc.Count) { return 0 }
    $periodDays = ($bounds.End - $bounds.Start).Days + 1

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
            # Creation period: days from the first cost day to month end when the key started
            # this month and ran every day after (0 = not a creation period). Per dimension.
            ResSpanDays   = Get-StartedSpanDays -Mask ([long]($masks.res[$e.DimensionKey] ?? 0)) -DayCount $periodDays
            MeterSpanDays = Get-StartedSpanDays -Mask ([long]($masks.meter[(Get-DimensionKey -Dimension 'meter' -Scope $e.Scope -Meter $e.Meter)] ?? 0)) -DayCount $periodDays
            SubSpanDays   = Get-StartedSpanDays -Mask ([long]($masks.sub[(Get-DimensionKey -Dimension 'subscription' -Scope $e.Scope)] ?? 0)) -DayCount $periodDays
        }
    }
    Set-TableEntityBatch -Table 'CostPeriods' -Entities @($entities) -Token $Token
    return @($entities).Count
}

# The meter grain's own rollup: one row per (subscription, meter category) from the ingest's
# exact per-category day totals (CostSnapshots 'cat|yyyy-MM-dd'), next to the per-resource rows in
# the same CostPeriods partition (RowKey 'cat|...', Kind 'category'). The per-resource rows can
# only give a category the cost of resources whose LARGEST category it was that day — a VM's
# Defender plan counts as 'Virtual Machines' — so a category rollup built from them misses most of
# a cost spread thinly over many resources. Same coverage rule as the resource rollup: every day
# must have category rows, or nothing is written and the meter grain keeps the label basis.
# Returns the number of rows written (0 = not covered).
function Update-PeriodCategoryRollup {
    param(
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$PeriodType,
        [Parameter(Mandatory)][string]$PeriodKey,
        [Parameter(Mandatory)][string]$Token
    )
    $bounds = Get-PeriodBounds -PeriodKey $PeriodKey -PeriodType $PeriodType
    $periodDays = ($bounds.End - $bounds.Start).Days + 1
    $acc = @{}; $masks = @{}; $days = 0
    for ($d = $bounds.Start; $d -le $bounds.End; $d = $d.AddDays(1)) {
        $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq 'cat|$($d.ToString('yyyy-MM-dd'))'" -Token $Token)
        if (-not $rows.Count) {
            Write-Host "  rollup: no category totals for $($d.ToString('yyyy-MM-dd')) — $PeriodType $PeriodKey keeps the label basis for meters."
            return 0
        }
        $days++
        $dayIndex = ($d - $bounds.Start).Days
        foreach ($r in $rows) {
            $k = [string]$r.DimensionKey
            if (-not $k) { continue }
            if (-not $acc.ContainsKey($k)) { $acc[$k] = [PSCustomObject]@{ DimensionKey = $k; Scope = [string]$r.Scope; Meter = [string]$r.Meter; CostUsd = 0.0 } }
            $acc[$k].CostUsd += [double]$r.CostUsd
            if ([double]$r.CostUsd -gt 0) { Add-ActiveDay -Masks $masks -Key $k -DayIndex $dayIndex }
        }
    }
    $old = @(Get-TableEntities -Table 'CostPeriods' -Filter "PartitionKey eq '$PeriodType|$PeriodKey' and RowKey ge 'cat|' and RowKey lt 'cat|~'" -Select 'PartitionKey,RowKey' -Token $Token)
    if ($old.Count) { [void](Remove-TableEntityBatch -Table 'CostPeriods' -Entities $old -Token $Token) }
    $entities = foreach ($e in $acc.Values) {
        @{
            PartitionKey  = "$PeriodType|$PeriodKey"
            RowKey        = "cat|$(Get-ShortHash -Value $e.DimensionKey)"
            Kind          = 'category'
            PeriodType    = $PeriodType
            Period        = $PeriodKey
            DimensionKey  = $e.DimensionKey
            Scope         = $e.Scope
            ResourceId    = ''
            Meter         = $e.Meter
            CostUsd       = [Math]::Round([double]$e.CostUsd, 4)
            DaysWithData  = $days
            MeterSpanDays = Get-StartedSpanDays -Mask ([long]($masks[$e.DimensionKey] ?? 0)) -DayCount $periodDays
        }
    }
    if (@($entities).Count) { Set-TableEntityBatch -Table 'CostPeriods' -Entities @($entities) -Token $Token }
    return @($entities).Count
}

# Category totals exist for a month's first and last day — cheap probe before a full read.
function Test-PeriodHasCategories {
    param([string]$PeriodType, [string]$PeriodKey, [string]$Token)
    $bounds = Get-PeriodBounds -PeriodKey $PeriodKey -PeriodType $PeriodType
    foreach ($d in @($bounds.Start, $bounds.End)) {
        $probe = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq 'cat|$($d.ToString('yyyy-MM-dd'))'" -Select 'PartitionKey,RowKey' -Top 1 -Token $Token)
        if (-not $probe.Count) { return $false }
    }
    return $true
}

# Which complete periods exist in the retained snapshot window, and which still need rolling up.
$retentionFloor = Get-PeriodRetentionFloorDays
$scanFrom = $today.AddDays(-$retentionFloor)
# Rollup format. 2 = one row per (resource, meter label) — see Update-PeriodRollup. 3 = plus the
# creation-period spans (ResSpanDays / MeterSpanDays / SubSpanDays). A marker
# from an older format is rebuilt while the month is still one detection reads (the target month
# plus its baseline), so a format fix reaches the live comparison without a manual reset.
$rollupVersion = 3
$existingRollups = @{}
$rollupHasCategories = @{}
try {
    foreach ($m in @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'rollup'" -Select 'RowKey,RollupVersion,Categories' -Token $storageToken)) {
        $existingRollups[[string]$m.RowKey] = if ($null -ne $m.RollupVersion) { [int]$m.RollupVersion } else { 1 }
        $rollupHasCategories[[string]$m.RowKey] = [bool]$m.Categories
    }
} catch { Write-Host "rollup marker read failed (periods may be recomputed): $($_.Exception.Message)" }

# Adds the category rows to a month's rollup and records it on the marker (merge). The category
# rollup can follow the resource rollup by days — the history refetch that supplies older months'
# category totals runs after the nightly ingest — so a month without them is retried every night.
function Add-MonthCategories {
    param([string]$PeriodType, [string]$PeriodKey)
    try {
        $n = Update-PeriodCategoryRollup -PeriodType $PeriodType -PeriodKey $PeriodKey -Token $storageToken
        if ($n -gt 0) {
            Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{ PartitionKey = 'rollup'; RowKey = "$PeriodType|$PeriodKey"; Categories = $true }
            Write-Host "  rollup: $PeriodType $PeriodKey -> $n meter-category row(s)."
        }
    } catch { Write-Host "  rollup: category totals for $PeriodType $PeriodKey failed, will retry next run: $($_.Exception.Message)" }
}

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
            if ($existingRollups[$rk] -ge $rollupVersion -or $pk -notin $inUse) {
                # Current resource rollup, but no category rows yet: add them once the ingest has them.
                if ($pk -in $inUse -and -not $rollupHasCategories[$rk] -and
                    (Test-PeriodHasCategories -PeriodType $periodType -PeriodKey $pk -Token $storageToken)) {
                    Add-MonthCategories -PeriodType $periodType -PeriodKey $pk
                }
                continue
            }
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
                # The resource rollup replaced the whole partition, category rows included.
                Set-TableEntity -Table 'PortalConfig' -Token $storageToken -Entity @{ PartitionKey = 'rollup'; RowKey = "$periodType|$pk"; Categories = $false }
                if (Test-PeriodHasCategories -PeriodType $periodType -PeriodKey $pk -Token $storageToken) {
                    Add-MonthCategories -PeriodType $periodType -PeriodKey $pk
                }
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
            ResSpanDays = $_.ResSpanDays; MeterSpanDays = $_.MeterSpanDays; SubSpanDays = $_.SubSpanDays
            # 'category' = an exact meter-category total (Update-PeriodCategoryRollup); '' = a resource row.
            Kind = [string]$_.Kind
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
    $catAcc = @{}; $catDays = @{}
    # Per window: which days each resource / meter / subscription had cost (creation periods).
    $masks = @{ res = @{}; meter = @{}; sub = @{}; cat = @{} }
    for ($d = $from; $d -le $to; $d = $d.AddDays(1)) {
        $w = @($Windows | Where-Object { $d -ge $_.Start -and $d -le $_.End }) | Select-Object -First 1
        if (-not $w) { continue }
        $dayIndex = ($d - $w.Start).Days
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
            if ([double]$r.CostUsd -gt 0) {
                Add-ActiveDay -Masks $masks.res -Key $k -DayIndex $dayIndex
                Add-ActiveDay -Masks $masks.meter -Key "$($w.Key)|$(Get-DimensionKey -Dimension 'meter' -Scope ([string]$r.Scope) -Meter ([string]$r.Meter))" -DayIndex $dayIndex
                Add-ActiveDay -Masks $masks.sub -Key "$($w.Key)|$(Get-DimensionKey -Dimension 'subscription' -Scope ([string]$r.Scope))" -DayIndex $dayIndex
            }
        }
        # The day's exact per-category totals, for the meter grain (see Update-PeriodCategoryRollup).
        $catRows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq 'cat|$dayKey'" -Token $Token)
        if ($catRows.Count) { $catDays[$dayKey] = $true }
        foreach ($r in @(Select-InSubscriptionScope -Scope $subScope -Rows $catRows)) {
            $dk = [string]$r.DimensionKey
            if (-not $dk) { continue }
            $k = "$($w.Key)|$dk"
            if (-not $catAcc.ContainsKey($k)) {
                $catAcc[$k] = [PSCustomObject]@{ Date = $w.Key; DimensionKey = $dk; Scope = [string]$r.Scope
                    ResourceId = ''; Meter = [string]$r.Meter; CostUsd = 0.0; Kind = 'category' }
            }
            $catAcc[$k].CostUsd += [double]$r.CostUsd
            if ([double]$r.CostUsd -gt 0) { Add-ActiveDay -Masks $masks.cat -Key $k -DayIndex $dayIndex }
        }
    }
    foreach ($k in $catAcc.Keys) {
        $row = $catAcc[$k]
        $wDays = @($Windows | Where-Object { $_.Key -eq $row.Date } | ForEach-Object { ($_.End - $_.Start).Days + 1 })[0]
        $row | Add-Member -NotePropertyName MeterSpanDays -NotePropertyValue (Get-StartedSpanDays -Mask ([long]($masks.cat[$k] ?? 0)) -DayCount $wDays) -Force
    }
    foreach ($row in $acc.Values) {
        $wDays = @($Windows | Where-Object { $_.Key -eq $row.Date } | ForEach-Object { ($_.End - $_.Start).Days + 1 })[0]
        $row | Add-Member -NotePropertyName ResSpanDays -NotePropertyValue (Get-StartedSpanDays -Mask ([long]($masks.res["$($row.Date)|$($row.DimensionKey)"] ?? 0)) -DayCount $wDays) -Force
        $row | Add-Member -NotePropertyName MeterSpanDays -NotePropertyValue (Get-StartedSpanDays -Mask ([long]($masks.meter["$($row.Date)|$(Get-DimensionKey -Dimension 'meter' -Scope ([string]$row.Scope) -Meter ([string]$row.Meter))"] ?? 0)) -DayCount $wDays) -Force
        $row | Add-Member -NotePropertyName SubSpanDays -NotePropertyValue (Get-StartedSpanDays -Mask ([long]($masks.sub["$($row.Date)|$(Get-DimensionKey -Dimension 'subscription' -Scope ([string]$row.Scope))"] ?? 0)) -DayCount $wDays) -Force
    }
    $expected = ($to - $from).Days + 1
    return [PSCustomObject]@{ Rows = @($acc.Values); DaysCovered = $daysWithData.Count; DaysExpected = $expected
        # Category rows only count when EVERY day has them (else the meter grain keeps the labels).
        CategoryRows = @($catAcc.Values); CategoryDaysCovered = $catDays.Count }
}

# Daily cost of a few keys across one period, from CostSnapshots one day at a time (the same
# streaming as the rollup). Returns key -> double[days]; empty when a day cannot be read, since a
# series with a hole would read as a drop to zero. Returns $null when a day cannot be read (so a
# caller can tell "unknown" from "no cost"); a wanted key absent from a returned table had no
# cost on any of the days.
# -UseCategories: meter keys come from the day's category totals ('cat|' partition), the basis the
# meter grain was detected on, instead of the resources' labels.
function Get-PeriodDailySeries {
    param([datetime]$Start, [datetime]$End, [string[]]$Keys, [string]$Token, [switch]$UseCategories)
    $wanted = @{}
    foreach ($k in $Keys) { if ($k) { $wanted[$k] = $true } }
    $n = ($End - $Start).Days + 1
    $series = @{}
    if (-not $wanted.Count) { return $series }
    $needCat = $UseCategories -and @($wanted.Keys | Where-Object { $_ -like 'meter:*' }).Count -gt 0
    for ($i = 0; $i -lt $n; $i++) {
        $dayKey = $Start.AddDays($i).ToString('yyyy-MM-dd')
        try { $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $Token) }
        catch { Write-Host "  daily series: reading $dayKey failed, no daily shape this run: $($_.Exception.Message)"; return $null }
        if (-not $rows.Count) { Write-Host "  daily series: no snapshots for $dayKey, no daily shape this run."; return $null }
        if ($needCat) {
            try { $cat = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq 'cat|$dayKey'" -Token $Token) }
            catch { Write-Host "  daily series: reading category totals for $dayKey failed, no daily shape this run: $($_.Exception.Message)"; return $null }
            if (-not $cat.Count) { Write-Host "  daily series: no category totals for $dayKey, no daily shape this run."; return $null }
            $rows = @($rows) + @($cat)
        }
        $rows = @(Select-InSubscriptionScope -Scope $subScope -Rows $rows)
        Add-DailySeriesRows -Series $series -Wanted $wanted -Rows $rows -DayIndex $i -DayCount $n -NoMeterLabels:$UseCategories
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
# "Where does it stand now" for every finding: the mean of the latest settled days (to D-2).
$recentEnd = $windowEnd
$recentDays = 3
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
        CurrentCategories  = @($rolling.CategoryRows | Where-Object { $_.Date -eq $cur.Key })
        BaselineCategories = @($rolling.CategoryRows | Where-Object { $_.Date -ne $cur.Key })
        UseCategories = ($rolling.CategoryDaysCovered -ge $rolling.DaysExpected)
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
    $curRows = @(Get-PeriodRows -PeriodType 'month' -PeriodKey $targetKey -Token $storageToken)
    # The rollup partition holds resource rows and (once the ingest supplied them) category rows.
    $curCat  = @($curRows | Where-Object { $_.Kind -eq 'category' })
    $baseCat = @($baseRows | Where-Object { $_.Kind -eq 'category' })
    # Category basis only when the analysed month AND every baseline month have it: comparing an
    # exact category total with a label-based one would flag the method change, not the cost.
    $catMonths = @{}; foreach ($r in $baseCat) { $catMonths[[string]$r.Date] = $true }
    $useCat = $curCat.Count -gt 0 -and @($baselineKeys | Where-Object { -not $catMonths.ContainsKey([string]$_) }).Count -eq 0
    $analyses += [PSCustomObject]@{
        PeriodType  = 'month'
        Key         = $targetKey
        Start       = $bounds.Start
        End         = $bounds.End
        Label       = $targetKey
        Current     = @($curRows | Where-Object { $_.Kind -ne 'category' })
        Baseline    = @($baseRows | Where-Object { $_.Kind -ne 'category' })
        CurrentCategories  = $curCat
        BaselineCategories = $baseCat
        UseCategories = $useCat
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
    # A baseline period the key was created in counts at its daily level x this many days
    # (Measure-DimensionBaseline -ScaleStartedTo); one it started in its last 2 days is left out.
    $analysisDays = ($a.End - $a.Start).Days + 1
    if (-not $currentRows.Count) {
        Write-Host "  no rows for $targetKey — skipping."
        Set-AnalysisStatus -PeriodType $periodType -Status 'skipped' -Period $targetKey -Reason 'no-data' -Detail (
            Get-PortalText 'status.noData' @{ period = $a.Label })
        continue
    }

    # -Dimension keys inline rather than building a re-keyed copy of every row first: three
    # dimensions over several periods made those copies the largest thing in memory.
    $current  = Measure-DailyDimensionCost -Rows $currentRows  -Dimension 'resource'
    $baseline = Measure-DimensionBaseline  -Rows $baselineRows -Dimension 'resource' -ScaleStartedTo $analysisDays
    $findings = @(Find-CostSpike -Current $current -Baseline $baseline -MinDeltaUsd $minUsd -MinDeltaPct $minPct -Dimension 'resource')
    Write-Host "  resource grain: $($findings.Count) finding(s)."

    # The meter grain: exact per-category totals when every period has them, otherwise each
    # resource's largest category (the label basis, which misses cost spread thinly over many
    # resources — a VM's Defender plan counts as 'Virtual Machines').
    $useCat = [bool]$a.UseCategories
    Write-Host "  meter basis: $(if ($useCat) { 'exact meter-category totals' } else { 'largest category per resource (category totals not available for every period yet)' })."
    foreach ($dim in @('meter', 'subscription')) {
        $dimCurRows  = if ($dim -eq 'meter' -and $useCat) { @($a.CurrentCategories) } else { $currentRows }
        $dimBaseRows = if ($dim -eq 'meter' -and $useCat) { @($a.BaselineCategories) } else { $baselineRows }
        $dimCurrent  = Measure-DailyDimensionCost -Rows $dimCurRows  -Dimension $dim
        $dimBaseline = Measure-DimensionBaseline  -Rows $dimBaseRows -Dimension $dim -ScaleStartedTo $analysisDays
        $found = @(Find-CostSpike -Current $dimCurrent -Baseline $dimBaseline -MinDeltaUsd $minUsd -MinDeltaPct $minPct -Dimension $dim)
        $kept  = @(Select-UnexplainedSpike -RollupSpikes $found -ResourceSpikes $findings -MinDeltaUsd $minUsd)
        Write-Host "  $dim grain: $($found.Count) flagged, $($kept.Count) not already explained by a resource finding."
        $findings = @(@($findings) + @($kept))
    }
    $findings = @($findings | Sort-Object -Property DeltaUsd -Descending)

    # --- how each finding moved WITHIN the period, and where it stands NOW ---
    # A period is compared as one total, so a service that ran at full cost for twelve days and
    # was then switched off still reads as "more than a typical month" — and a trailing week
    # keeps the high days in its window for up to 7 nights after the cost fell. Two measures fix
    # what the reader sees:
    #   shape    the period's daily series: where it ENDED and on which day it stepped down
    #            (Measure-ExitRunRate; the week uses a 3-day tail, the month a 7-day one).
    #   current  the mean of the latest $recentDays settled days (up to D-2) — after the period
    #            for a closed month — scaled to a whole period and judged against the same bar
    #            (Get-FindingState): resolved / decreasing / open.
    if ($findings.Count) {
        $periodDays = ($a.End - $a.Start).Days + 1
        $keys = @($findings | ForEach-Object { [string]$_.DimensionKey })
        $coverage = @{}
        foreach ($dim in @('resource', 'meter', 'subscription')) {
            $covRows = if ($dim -eq 'meter' -and $useCat) { @($a.BaselineCategories) } else { $baselineRows }
            $coverage[$dim] = Measure-BaselineCoverage -Rows $covRows -Dimension $dim -MinStartedSpan 3
        }
        $series = Get-PeriodDailySeries -Start $a.Start -End $a.End -Keys $keys -Token $storageToken -UseCategories:$useCat
        # The recent days. When the period itself reaches them (the trailing week always does),
        # its own tail is used; otherwise they are read separately — only a few days of snapshots.
        $recentSeries = $null; $recentAsOf = $null; $recentFromTail = $false
        if ($a.End -ge $recentEnd) {
            $recentSeries = $series; $recentAsOf = $a.End; $recentFromTail = $true
        } else {
            $recentSeries = Get-PeriodDailySeries -Start $recentEnd.AddDays(-($recentDays - 1)) -End $recentEnd -Keys $keys -Token $storageToken -UseCategories:$useCat
            $recentAsOf = $recentEnd
        }
        $tailDays = if ($periodType -eq 'week') { 3 } else { 7 }
        $minSegment = if ($periodType -eq 'week') { 2 } else { 3 }
        $counts = @{ open = 0; decreasing = 0; resolved = 0; unknown = 0 }
        foreach ($f in $findings) {
            $k = [string]$f.DimensionKey
            $cov = $coverage[[string]$f.Dimension]
            $f | Add-Member -NotePropertyName BaselinePeriods -NotePropertyValue $(if ($cov -and $cov.ContainsKey($k)) { [int]$cov[$k] } else { 0 }) -Force
            $f | Add-Member -NotePropertyName BaselinePeriodsOf -NotePropertyValue ([int]$a.BaselineN) -Force

            $endResolved = $false
            if ($null -ne $series) {
                # A key the read found no cost for at all: an all-zero period (cannot happen for a
                # finding, but must not crash).
                $daily = if ($series.ContainsKey($k)) { $series[$k] } else { [double[]]::new($periodDays) }
                $m = Measure-ExitRunRate -Daily $daily -TailDays $tailDays -MinSegmentDays $minSegment
                if ($m) {
                    $endResolved = Test-ExitRunRateResolved -ExitRunRateUsd $m.ExitRunRateUsd -BaselineUsd ([double]$f.BaselineUsd) -MinDeltaUsd $minUsd -MinDeltaPct $minPct
                    $f | Add-Member -NotePropertyName ExitRunRateUsd -NotePropertyValue ([double]$m.ExitRunRateUsd) -Force
                    $f | Add-Member -NotePropertyName SteppedDownOn -NotePropertyValue $(if ($null -ne $m.StepDownIndex) { $a.Start.AddDays($m.StepDownIndex).ToString('yyyy-MM-dd') } else { '' }) -Force
                    $f | Add-Member -NotePropertyName DailyBeforeUsd -NotePropertyValue $m.BeforeDailyUsd -Force
                    $f | Add-Member -NotePropertyName DailyAfterUsd -NotePropertyValue $m.AfterDailyUsd -Force
                }
            }

            $recentDaily = $null
            if ($null -ne $recentSeries) {
                $vals = if ($recentSeries.ContainsKey($k)) { @($recentSeries[$k]) } else { @() }
                if ($recentFromTail) { $vals = @($vals | Select-Object -Last $recentDays) }
                $sum = 0.0; foreach ($v in $vals) { $sum += [double]$v }
                # Missing key = no cost on those days.
                $recentDaily = $sum / $recentDays
            }
            $state = Get-FindingState -RecentDailyUsd $recentDaily -PeriodDays $periodDays -BaselineUsd ([double]$f.BaselineUsd) `
                -SpikeUsd ([double]$f.SpikeUsd) -MinDeltaUsd $minUsd -MinDeltaPct $minPct
            # A month that already ended below the bar stays resolved even if a later blip lifts
            # the recent days a little — it was resolved within the period it describes.
            if ($endResolved -and $state -ne 'resolved') { $state = 'resolved' }
            if ($null -eq $recentDaily) { $counts.unknown++ } else { $counts[$state]++ }
            $f | Add-Member -NotePropertyName State -NotePropertyValue $state -Force
            $f | Add-Member -NotePropertyName Resolved -NotePropertyValue ($state -eq 'resolved') -Force
            $f | Add-Member -NotePropertyName CurrentDailyUsd -NotePropertyValue $recentDaily -Force
            $f | Add-Member -NotePropertyName CurrentAsOf -NotePropertyValue $(if ($null -ne $recentDaily) { $recentAsOf.ToString('yyyy-MM-dd') } else { '' }) -Force
            # How far it has fallen, and since when (Get-CostFall) — only for changes that are no
            # longer running high.
            $fall = if ($state -ne 'open') {
                Get-CostFall -CurrentDailyUsd $recentDaily -BeforeDailyUsd $f.DailyBeforeUsd -SteppedDownOn ([string]$f.SteppedDownOn) `
                    -SpikeUsd ([double]$f.SpikeUsd) -PeriodDays $periodDays
            } else { $null }
            $f | Add-Member -NotePropertyName Fall -NotePropertyValue $fall -Force
        }
        Write-Host ("  current level (last $recentDays settled days to $($recentAsOf.ToString('yyyy-MM-dd'))): " +
            "$($counts.open) open, $($counts.decreasing) decreasing, $($counts.resolved) resolved, $($counts.unknown) not measurable.")
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
            # Where it stands NOW (Get-FindingState): open | decreasing | resolved, from the mean of
            # the latest settled days. -1 / '' = not measurable this run.
            State          = if ($f.State) { [string]$f.State } else { 'open' }
            CurrentDailyUsd = if ($null -ne $f.CurrentDailyUsd) { [Math]::Round([double]$f.CurrentDailyUsd, 2) } else { -1 }
            CurrentAsOf    = if ($f.CurrentAsOf) { [string]$f.CurrentAsOf } else { '' }
            # The fall in daily cost (negative %), from FallFromDailyUsd, since FallSince ('' = against
            # the period's average day). 0 / -1 / '' = no fall measured.
            FallPct        = if ($f.Fall) { [double]$f.Fall.Pct } else { 0 }
            FallFromDailyUsd = if ($f.Fall) { [double]$f.Fall.FromDailyUsd } else { -1 }
            FallSince      = if ($f.Fall) { [string]$f.Fall.Since } else { '' }
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
            Status         = if ($f.State) { [string]$f.State } else { 'open' }
            DetectedAt     = ([datetime]::UtcNow.ToString('o'))
        }
    }
    Set-TableEntityBatch -Table 'CostSpikes' -Entities $entities -Token $storageToken
    Write-Host ("$periodType : persisted $($entities.Count) finding(s) for $($a.Label) — evidence gathered $evGathered, reused $evReused, skipped $evSkipped; " +
                "explained $narrated, reused $reused, failed $failed.")

    # A period is re-analysed every night while it is the newest of its grain, and a finding an
    # earlier run produced may no longer be one (a baseline that caught up, a rollup now covered by
    # a resource finding, a changed detection rule). Upserting alone left those rows in the
    # partition, frozen with old figures and evidence. This run is the whole answer for the
    # period, so every stored row it did not write goes. Skipped when the stored rows could not be
    # read ($storedNarratives empty), which only means nothing is removed.
    $written = @{}
    foreach ($e in $entities) { $written[[string]$e.RowKey] = $true }
    $stale = @($storedNarratives.Keys | Where-Object { -not $written.ContainsKey([string]$_) } |
        ForEach-Object { @{ PartitionKey = "$periodType|$targetKey"; RowKey = [string]$_ } })
    if ($stale.Count) {
        try {
            $n = Remove-TableEntityBatch -Table 'CostSpikes' -Entities $stale -Token $storageToken
            Write-Host "$periodType : removed $n finding(s) for $($a.Label) that this run no longer flags."
        } catch { Write-Host "$periodType : removing stale findings failed (they stay until the next run): $($_.Exception.Message)" }
    }

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
        # What the page needs to explain the comparison: which windows / months formed the
        # baseline, and how fresh the "current level" of each finding is.
        BaselineRangesJson = (@($a.BaselineRanges | ForEach-Object { @{ start = $_.Start.ToString('yyyy-MM-dd'); end = $_.End.ToString('yyyy-MM-dd') } }) | ConvertTo-Json -Compress -AsArray)
        SettledThrough = $recentEnd.ToString('yyyy-MM-dd')
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
