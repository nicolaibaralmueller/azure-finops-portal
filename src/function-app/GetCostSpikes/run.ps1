using namespace System.Net
param($Request, $TriggerMetadata)

# Cost changes for one COMPLETE period, with their evidence and written explanations (both
# precomputed by DetectCostSpikes-Timer). Read-only; members allowed.
#
# Detection is weekly and monthly, never daily — this is an analysis view, not an alert feed.
# Only settled periods are analysed, so there is no partial-period comparison to get wrong.
#
# Query params:
#   ?periodType=week|month   (default week — surfaces a change soonest after it happens)
#   ?offset=<n>              0 = latest complete period (default), 1 = the one before it, …
#   ?dimension=resource|meter|subscription|all   (default all)
#   ?minUsd=<n>              (default 0)
#
# Each finding carries the grain it was detected at: 'resource' (one resource), or the
# 'meter'/'subscription' rollups that catch an increase spread too thin to flag any single
# resource. Rollups are de-duplicated against resource findings at detection time.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$q = $Request.Query
$periodType = if ($q -and ([string]$q['periodType'] -eq 'month')) { 'month' } else { 'week' }
$offset = 0
if ($q -and $q['offset']) {
    $parsed = 0
    if ([int]::TryParse([string]$q['offset'], [ref]$parsed)) { $offset = [Math]::Max(0, [Math]::Min($parsed, 24)) }
}
$minUsd = 0.0
if ($q -and $q['minUsd']) { [double]::TryParse([string]$q['minUsd'], [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$minUsd) | Out-Null }
# ?key=<period key> serves that exact period instead of stepping back from the newest — what a
# link from the Overview's findings needs: the brief may be days old, and the weekly window has
# moved on since. Week keys are the window's last day (yyyy-MM-dd), month keys yyyy-MM.
$exactKey = $null
if ($q -and $q['key']) {
    $k = [string]$q['key']
    $pattern = if ($periodType -eq 'week') { '^\d{4}-\d{2}-\d{2}$' } else { '^\d{4}-\d{2}$' }
    if ($k -match $pattern) { $exactKey = $k }
}
$dimFilter = if ($q -and $q['dimension']) { ([string]$q['dimension']).ToLower() } else { 'all' }
if ($dimFilter -notin @('all', 'resource', 'meter', 'subscription')) { $dimFilter = 'all' }

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# Resolve which period to serve.
#   week  — a TRAILING 7 days whose bounds move nightly, so the newest analysed window is read
#           from the pointer the detector writes rather than guessed from today's date (which
#           would miss before the nightly run, and can't know how settled the data is).
#           Earlier steps back a whole window at a time.
#   month — deterministic calendar keys, walked back from today.
$today = [datetime]::UtcNow.Date
$periodKey = $null
$bounds = $null

if ($exactKey) {
    try {
        if ($periodType -eq 'week') {
            $end = [datetime]::ParseExact($exactKey, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $periodKey = $exactKey
            $bounds = @{ Start = $end.AddDays(-6); End = $end }
        } else {
            $bounds = Get-PeriodBounds -PeriodKey $exactKey -PeriodType 'month'
            $periodKey = $exactKey
        }
    } catch { $periodKey = $null; $bounds = $null }
} elseif ($periodType -eq 'week') {
    $pointer = $null
    try {
        $pointer = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'latestperiod' and RowKey eq 'week'" -Token $token) | Select-Object -First 1
    } catch { Write-Host "latest-period pointer read failed: $($_.Exception.Message)" }
    # No pointer yet (nothing analysed since deployment) — fall back to the window the detector
    # WOULD use, so the caller sees the real range with analyzed:false ("this window hasn't been
    # analysed") rather than the much vaguer "no period exists at all".
    $latestEnd = if ($pointer -and $pointer.PeriodEnd) {
        [datetime]::ParseExact([string]$pointer.PeriodEnd, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    } else {
        Get-RollingWindowEndDate -Today $today
    }
    $end = $latestEnd.AddDays(-7 * $offset)
    $periodKey = $end.ToString('yyyy-MM-dd')
    $bounds = @{ Start = $end.AddDays(-6); End = $end }
} else {
    $cursor = $today
    $found = 0
    # A month can be 31 days and we allow up to 24 periods back, so bound the walk generously.
    for ($i = 0; $i -lt 800; $i++) {
        $key = Get-PeriodKey -Date $cursor -PeriodType $periodType
        if (Test-PeriodComplete -PeriodKey $key -PeriodType $periodType -Today $today) {
            if ($found -eq $offset) { $periodKey = $key; break }
            $found++
            # Jump to the day before this period starts so each key is visited once.
            $cursor = (Get-PeriodBounds -PeriodKey $key -PeriodType $periodType).Start.AddDays(-1)
            continue
        }
        $cursor = $cursor.AddDays(-1)
    }
    if ($periodKey) { $bounds = Get-PeriodBounds -PeriodKey $periodKey -PeriodType $periodType }
}

if (-not $periodKey) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{ spikes = @(); count = 0; periodType = $periodType; period = $null; periodStart = $null; periodEnd = $null; analyzed = $false } | ConvertTo-Json -Depth 4)
        Headers    = @{ "Content-Type" = "application/json" }
    })
    return
}
$rows = @()
try {
    # PartitionKey is "<periodType>|<periodKey>", so this is a single-partition point query.
    $rows = @(Get-TableEntities -Table 'CostSpikes' -Filter "PartitionKey eq '$periodType|$periodKey'" -Token $token)
} catch {
    Write-Host "CostSpikes read failed: $($_.Exception.Message)"
}
# Findings of subscriptions outside the operator's scope are hidden (not deleted).
$rows = @(Select-InSubscriptionScope -Scope (Get-SubscriptionScope -Token $token) -Rows $rows)

# Did the detector actually run for this period? Written by DetectCostSpikes-Timer regardless
# of whether it found anything, so "clean" and "not yet analysed" stay distinguishable.
$analyzed = $false
$marker = $null
try {
    $marker = @(Get-TableEntities -Table 'PortalConfig' `
        -Filter "PartitionKey eq 'analyzed' and RowKey eq '$periodType|$periodKey'" -Token $token) | Select-Object -First 1
    $analyzed = $null -ne $marker
} catch { Write-Host "analysed-marker read failed: $($_.Exception.Message)" }

# How the comparison was made, for the page's "how is this calculated" panel. Markers written
# before this was stored get the ranges detection WOULD have used.
$baselineCount = Get-PeriodBaselineCount -PeriodType $periodType
$baselineRanges = @()
if ($marker -and $marker.BaselineRangesJson) {
    try { $baselineRanges = @([string]$marker.BaselineRangesJson | ConvertFrom-Json) } catch { $baselineRanges = @() }
}
if (-not $baselineRanges.Count -and $bounds) {
    $baselineRanges = @(1..$baselineCount | ForEach-Object {
        if ($periodType -eq 'week') {
            $e = $bounds.End.AddDays(-7 * $_); @{ start = $e.AddDays(-6).ToString('yyyy-MM-dd'); end = $e.ToString('yyyy-MM-dd') }
        } else {
            $s = $bounds.Start.AddMonths(-$_); @{ start = $s.ToString('yyyy-MM-dd'); end = $s.AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd') }
        }
    } | Sort-Object { $_.start })
}
$settledThrough = if ($marker -and $marker.SettledThrough) { [string]$marker.SettledThrough } else { $null }
$analyzedAt = if ($marker -and $marker.At) { [string]$marker.At } else { $null }
# Rows without a marker mean the period predates the marker being introduced — findings exist,
# so it plainly was analysed.
if (-not $analyzed -and $rows.Count -gt 0) { $analyzed = $true }

# When it wasn't analysed, say WHY. "It is processed on the first nightly run after the period
# ends" is only true when the run simply hasn't happened; it is actively wrong when the grain is
# being skipped for want of history, because no number of nightly runs will change that.
$reason = $null
$detail = $null
$minDeltaUsd = $null
$minDeltaPct = $null
$status = $null
try {
    $status = @(Get-TableEntities -Table 'PortalConfig' `
        -Filter "PartitionKey eq 'analysisstatus' and RowKey eq '$periodType'" -Token $token) | Select-Object -First 1
} catch { Write-Host "analysis-status read failed: $($_.Exception.Message)" }
if ($status) {
    if ($null -ne $status.MinDeltaUsd) { $minDeltaUsd = [double]$status.MinDeltaUsd }
    if ($null -ne $status.MinDeltaPct) { $minDeltaPct = [double]$status.MinDeltaPct }
}
if (-not $analyzed) {
    if ($status -and [string]$status.Status -eq 'skipped') {
        $reason = [string]$status.Reason
        $detail = [string]$status.Detail
    } elseif ($status -and [string]$status.Status -eq 'ok' -and [string]$status.Period -and
              [string]::CompareOrdinal($periodKey, [string]$status.Period) -lt 0) {
        # The detector is running fine and has analysed a LATER period — this one is older than
        # the first run that stored results. Keys ('yyyy-MM', 'yyyy-Www') sort chronologically
        # as strings. A period newer than the last analysed one is simply pending (else branch).
        $reason = 'not-covered'
        $detail = "Analysis has run (most recently for $([string]$status.Period)), but never covered this period — it predates the stored results."
    } else {
        $reason = 'pending'
    }
}

$spikes = foreach ($r in $rows) {
    if ([double]$r.DeltaUsd -lt $minUsd) { continue }
    $dimension = if ($r.Dimension) { [string]$r.Dimension } else { 'resource' }
    if ($dimFilter -ne 'all' -and $dimension -ne $dimFilter) { continue }
    $evidence = $null
    if ($r.EvidenceJson) { try { $evidence = [string]$r.EvidenceJson | ConvertFrom-Json } catch { $evidence = $null } }
    $cited = @()
    if ($r.CitedFactsJson) { try { $cited = @([string]$r.CitedFactsJson | ConvertFrom-Json) } catch { $cited = @() } }
    [PSCustomObject]@{
        id             = $r.RowKey
        periodType     = $periodType
        period         = $periodKey
        periodStart    = [string]$r.PeriodStart
        periodEnd      = [string]$r.PeriodEnd
        dimension      = $dimension
        scope          = $r.Scope
        scopeName      = $r.ScopeName
        unexplainedUsd = if ($null -ne $r.UnexplainedUsd -and [double]$r.UnexplainedUsd -ge 0) { [double]$r.UnexplainedUsd } else { $null }
        resourceId     = $r.ResourceId
        resourceName   = $r.ResourceName
        allocation     = (ConvertFrom-AllocationJson -Row $r)
        meter          = $r.Meter
        baselineUsd    = [double]$r.BaselineUsd
        spikeUsd       = [double]$r.SpikeUsd
        deltaUsd       = [double]$r.DeltaUsd
        deltaPct       = if ($r.IsNew) { $null } else { [double]$r.DeltaPct }
        isNew          = [bool]$r.IsNew
        # Within-period shape (monthly). resolved = the period ended at a level that would not
        # be flagged: the increase has already fallen back.
        resolved       = [bool]$r.Resolved
        exitRunRateUsd = if ($null -ne $r.ExitRunRateUsd -and [double]$r.ExitRunRateUsd -ge 0) { [double]$r.ExitRunRateUsd } else { $null }
        steppedDownOn  = if ($r.SteppedDownOn) { [string]$r.SteppedDownOn } else { $null }
        # Where it stands now: open | decreasing | resolved (rows from before this existed derive
        # it from the month-end flag).
        state          = if ($r.State) { [string]$r.State } elseif ([bool]$r.Resolved) { 'resolved' } else { 'open' }
        currentDailyUsd = if ($null -ne $r.CurrentDailyUsd -and [double]$r.CurrentDailyUsd -ge 0) { [double]$r.CurrentDailyUsd } else { $null }
        currentAsOf    = if ($r.CurrentAsOf) { [string]$r.CurrentAsOf } else { $null }
        # How far the daily cost has fallen (negative %), from fallFromDailyUsd, since fallSince
        # (null = against the period's average day). null = no fall measured.
        fallPct        = if ($null -ne $r.FallPct -and [double]$r.FallPct -lt 0) { [double]$r.FallPct } else { $null }
        fallFromDailyUsd = if ($null -ne $r.FallFromDailyUsd -and [double]$r.FallFromDailyUsd -ge 0) { [double]$r.FallFromDailyUsd } else { $null }
        fallSince      = if ($r.FallSince) { [string]$r.FallSince } else { $null }
        baselinePeriods   = if ($null -ne $r.BaselinePeriods -and [int]$r.BaselinePeriods -ge 0) { [int]$r.BaselinePeriods } else { $null }
        baselinePeriodsOf = if ($null -ne $r.BaselinePeriodsOf -and [int]$r.BaselinePeriodsOf -ge 0) { [int]$r.BaselinePeriodsOf } else { $null }
        # Written explanation (AI, from the evidence). Rows written before the evidence rework
        # may still carry a headline without evidence; the page labels those as older text.
        headline       = $r.Headline
        cause          = $r.Cause
        recommendation = $r.Recommendation
        citedFacts     = $cited
        explained      = [bool]$r.Explained
        explanationStatus = [string]$r.ExplanationStatus
        grounded       = if ($null -ne $r.Grounded) { [bool]$r.Grounded } else { $true }
        # What drove the change and what was changed (CostEvidence.psm1). null = not gathered.
        evidence       = $evidence
        # 'complete' | 'partial' | 'skipped' (outside the per-run limit or time budget) | 'none'
        evidenceStatus = if ($r.EvidenceStatus) { [string]$r.EvidenceStatus } else { 'none' }
        status         = $r.Status
        detectedAt     = $r.DetectedAt
    }
}
# Open increases first, then decreasing ones; ones that have already fallen back go last.
$stateRank = @{ open = 0; decreasing = 1; resolved = 2 }
$spikes = @($spikes | Sort-Object -Property @{ Expression = { $stateRank[[string]$_.state] } }, @{ Expression = 'deltaUsd'; Descending = $true })

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        spikes      = $spikes
        count       = $spikes.Count
        periodType  = $periodType
        period      = $periodKey
        periodStart = $bounds.Start.ToString('yyyy-MM-dd')
        periodEnd   = $bounds.End.ToString('yyyy-MM-dd')
        # Whether the detector RAN for this period — deliberately not inferred from findings
        # existing, since a clean period legitimately has none.
        analyzed    = $analyzed
        # Only set when analyzed is false: 'pending' | 'insufficient-history' | 'needs-baseline'
        # | 'no-data' | 'not-covered', with a sentence the page can show as-is.
        reason      = $reason
        detail      = $detail
        # The bar a change had to clear to be listed — both must be met. Shown so an empty or
        # short list reads as "nothing else moved this much" rather than "something is broken".
        minDeltaUsd = $minDeltaUsd
        minDeltaPct = $minDeltaPct
        # How the comparison was made: the windows/months whose MEDIAN is the typical level, how
        # many there are, the newest settled day the "current level" uses, and when it ran.
        baselineRanges = @($baselineRanges)
        baselineCount  = $baselineCount
        settlingDays   = ([datetime]::UtcNow.Date - (Get-RollingWindowEndDate)).Days
        settledThrough = $settledThrough
        analyzedAt     = $analyzedAt
    } | ConvertTo-Json -Depth 12)
    Headers    = @{ "Content-Type" = "application/json" }
})
