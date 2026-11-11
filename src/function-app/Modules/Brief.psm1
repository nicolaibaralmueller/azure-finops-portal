# ============================================================================
# Brief.psm1 — the executive brief at the top of the Overview.
#
# The one place where AI clearly beats code is connecting findings across the whole portfolio:
# "this month is heading for X against Y last month, driven by A and B; these are the three
# things worth doing". Everything the brief states is assembled here deterministically first:
#
#   spend     month-to-date vs the same days last month, last month's total, run-rate
#             (weekly brief) — or the last complete month vs the one before (monthly brief)
#   changes   the largest cost changes of the latest analysed period, with their evidence
#   savings   the largest open savings (the app's own findings + Azure Advisor), with the total
#
#   owners    spend per owner this month and the open savings that are theirs
#   resourceGroups  spend per resource group, with an environment guess
#
# The findings agent (CostAgent.psm1) then turns this into 3-6 prioritised findings, checking
# and sizing them with read-only queries. Without AI (or over the daily AI limit) the page shows
# the rule-ranked findings (Get-RuleFindings) stored with every brief.
#
# Two grains:
#   week   generated on Mondays (or when missing / older than 7 days)
#   month  generated once the previous month is settled (from the 2nd), once per month
# An admin can regenerate either on demand (RegenerateBrief).
#
# Stored in CostSummary, PartitionKey 'brief', RowKey = grain.
# ============================================================================

$script:BriefVersion = 3   # 2: Azure's forecast replaces the run-rate; owners on items
                           # 3: owners + resource groups in the payload; AI findings (CostAgent.psm1)

# The newest day whose cost is settled (same D-2 rule as detection; see CostAnalysis.psm1).
function Get-BriefSettledDate {
    param([datetime]$Today = [datetime]::UtcNow.Date)
    return Get-RollingWindowEndDate -Today $Today
}

# The complete calendar month the MONTHLY brief covers: the latest month whose last day is
# settled. On the 2nd the previous month's last day is D-2, so it becomes available then.
function Get-BriefTargetMonth {
    param([datetime]$Today = [datetime]::UtcNow.Date)
    $next = (Get-BriefSettledDate -Today $Today).AddDays(1)
    return (Get-UtcMonthStart -Date $next).AddMonths(-1)
}

# Sum a month (optionally only days 1..ThroughDay) from a date -> row map.
# Returns { usd; billing; currency; days; expectedDays; daysInMonth; complete }. expectedDays is
# the days counted (1..ThroughDay), daysInMonth the calendar length — use the latter for pace. billing is $null unless
# EVERY counted day carries a billing-currency figure — a partial native sum would understate.
function Measure-MonthSpend {
    param(
        [Parameter(Mandatory)][hashtable]$Days,
        [Parameter(Mandatory)][datetime]$Month,
        [int]$ThroughDay = 0
    )
    $dim = [datetime]::DaysInMonth($Month.Year, $Month.Month)
    $last = if ($ThroughDay -gt 0) { [Math]::Min($ThroughDay, $dim) } else { $dim }
    $usd = 0.0; $billing = 0.0; $allBilling = $true; $present = 0; $currency = $null
    for ($d = 1; $d -le $last; $d++) {
        $key = ([datetime]::new($Month.Year, $Month.Month, $d)).ToString('yyyy-MM-dd')
        if (-not $Days.ContainsKey($key)) { $allBilling = $false; continue }
        $row = $Days[$key]
        $present++
        $usd += [double]$row.TotalUsd
        if ($null -ne $row.TotalBilling -and $row.Currency) {
            $billing += [double]$row.TotalBilling
            if (-not $currency) { $currency = [string]$row.Currency }
        } else { $allBilling = $false }
    }
    return [PSCustomObject]@{
        month        = $Month.ToString('yyyy-MM')
        # The exact days summed, so a comparison can name them ("1-8 Nov vs 1-8 Oct").
        from         = ([datetime]::new($Month.Year, $Month.Month, 1)).ToString('yyyy-MM-dd')
        to           = ([datetime]::new($Month.Year, $Month.Month, $last)).ToString('yyyy-MM-dd')
        throughDay   = $last
        daysInMonth  = $dim
        usd          = [Math]::Round($usd, 2)
        billing      = if ($allBilling -and $present -gt 0) { [Math]::Round($billing, 2) } else { $null }
        currency     = $currency
        days         = $present
        expectedDays = $last
        complete     = ($present -eq $last)
    }
}

function Get-PctChange {
    param($Current, $Previous)
    if ($null -eq $Current -or $null -eq $Previous -or [double]$Previous -le 0) { return $null }
    return [Math]::Round((([double]$Current - [double]$Previous) / [double]$Previous) * 100, 1)
}

# Spend figures for a grain from dailytotal rows (hashtable 'yyyy-MM-dd' -> row). Pure.
function Build-BriefSpend {
    param(
        [Parameter(Mandatory)][hashtable]$Days,
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$Grain,
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    if ($Grain -eq 'week') {
        $settled = Get-BriefSettledDate -Today $Today
        $month = Get-UtcMonthStart -Date $settled
        $dim = [datetime]::DaysInMonth($month.Year, $month.Month)
        $mtd = Measure-MonthSpend -Days $Days -Month $month -ThroughDay $settled.Day
        $prevMonth = $month.AddMonths(-1)
        $prevSame = Measure-MonthSpend -Days $Days -Month $prevMonth -ThroughDay $settled.Day
        $prevFull = Measure-MonthSpend -Days $Days -Month $prevMonth
        $runRateUsd = if ($mtd.days -gt 0 -and $mtd.complete) { [Math]::Round($mtd.usd / $settled.Day * $dim, 2) } else { $null }
        $runRateBilling = if ($null -ne $mtd.billing -and $mtd.complete) { [Math]::Round($mtd.billing / $settled.Day * $dim, 2) } else { $null }
        return [PSCustomObject]@{
            kind                = 'month-to-date'
            month               = $month.ToString('yyyy-MM')
            throughDate         = $settled.ToString('yyyy-MM-dd')
            current             = $mtd
            previousSamePeriod  = $prevSame
            previousMonth       = $prevFull
            changeVsPreviousPct = if ($mtd.complete -and $prevSame.complete) { Get-PctChange $mtd.usd $prevSame.usd } else { $null }
            # Straight-line: this month's daily average so far, times the days in the month. Labelled
            # as such in the UI; a real forecast (Cost Management Forecast API) replaces it later.
            runRateUsd          = $runRateUsd
            runRateBilling      = $runRateBilling
            runRateVsPreviousMonthPct = if ($null -ne $runRateUsd -and $prevFull.complete) { Get-PctChange $runRateUsd $prevFull.usd } else { $null }
        }
    }

    $target = Get-BriefTargetMonth -Today $Today
    $cur = Measure-MonthSpend -Days $Days -Month $target
    $prev = Measure-MonthSpend -Days $Days -Month $target.AddMonths(-1)
    return [PSCustomObject]@{
        kind                = 'complete-month'
        month               = $target.ToString('yyyy-MM')
        throughDate         = $target.AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')
        current             = $cur
        previousMonth       = $prev
        changeVsPreviousPct = if ($cur.complete -and $prev.complete) { Get-PctChange $cur.usd $prev.usd } else { $null }
    }
}

# Reduce a stored finding's evidence to the few facts worth carrying into the brief.
function Get-BriefFacts {
    param([string]$EvidenceJson, [int]$Max = 3)
    if ([string]::IsNullOrWhiteSpace($EvidenceJson)) { return @() }
    $ev = $null
    try { $ev = $EvidenceJson | ConvertFrom-Json } catch { return @() }
    $keep = @($ev.facts | Where-Object { $_.kind -in @('driver', 'property-change', 'change', 'new-resource') -and
        -not ($_.kind -eq 'driver' -and $_.direction -eq 'decrease') })
    return @($keep | Select-Object -First $Max | ForEach-Object {
        $f = [ordered]@{ kind = $_.kind }
        foreach ($p in @('driverKind', 'name', 'resourceName', 'deltaUsd', 'sharePct', 'quantityChangePct', 'unitPriceChangePct', 'isNew', 'time', 'action', 'operation', 'path', 'from', 'to')) {
            if ($_.PSObject.Properties[$p] -and $null -ne $_.$p) { $f[$p] = $_.$p }
        }
        [PSCustomObject]$f
    })
}

# The largest changes of the latest analysed period of a grain.
# The owner on a stored row's AllocationJson — the value of the FIRST configured allocation tag
# (Get-AllocationTagKeys), e.g. ServiceLead — or '' (none, untagged, or not a resource).
function Get-BriefOwner {
    param($Row, [string]$Key = 'owner')
    $j = [string]$Row.AllocationJson
    if (-not $j) { return '' }
    try { $o = [string](($j | ConvertFrom-Json).$Key) } catch { return '' }
    if (-not $o -or $o.StartsWith('(')) { return '' }
    return $o
}

function Get-BriefChanges {
    param([Parameter(Mandatory)][ValidateSet('week', 'month')][string]$Grain, [Parameter(Mandatory)][string]$Token, [int]$Top = 5)
    $ownerKey = @(Get-AllocationTagKeys -StorageToken $Token)[0]
    $pointer = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'latestperiod' and RowKey eq '$Grain'" -Token $Token) | Select-Object -First 1
    if (-not $pointer -or -not $pointer.Period) {
        return [PSCustomObject]@{ periodType = $Grain; period = $null; periodStart = $null; periodEnd = $null; total = 0; items = @() }
    }
    $pk = "$Grain|$([string]$pointer.Period)"
    $rows = @(Get-TableEntities -Table 'CostSpikes' -Filter "PartitionKey eq '$(ConvertTo-ODataLiteral -Value $pk)'" -Token $Token)
    # Findings stored before the operator narrowed the subscription scope are dropped here.
    $rows = @(Select-InSubscriptionScope -Scope (Get-SubscriptionScope -Token $Token) -Rows $rows)
    # Where each change stands now (DetectCostSpikes-Timer, Get-FindingState). Rows from before the
    # state existed derive it from the month-end flag. Open ones first: a change that is falling
    # or already back below the bar is not news, and must not be ranked as urgent.
    $stateOf = { param($r) if ($r.State) { [string]$r.State } elseif ([bool]$r.Resolved) { 'resolved' } else { 'open' } }
    $rank = @{ open = 0; decreasing = 1; resolved = 2 }
    $items = @($rows | Sort-Object @{ Expression = { $rank[(& $stateOf $_)] } }, @{ Expression = { [double]$_.DeltaUsd }; Descending = $true } | Select-Object -First $Top | ForEach-Object {
        $state = & $stateOf $_
        $days = 0
        try { $days = ([datetime]::ParseExact([string]$_.PeriodEnd, 'yyyy-MM-dd', $null) - [datetime]::ParseExact([string]$_.PeriodStart, 'yyyy-MM-dd', $null)).Days + 1 } catch { $days = 0 }
        $currentDaily = if ($null -ne $_.CurrentDailyUsd -and [double]$_.CurrentDailyUsd -ge 0) { [double]$_.CurrentDailyUsd } else { $null }
        $dimension = if ($_.Dimension) { [string]$_.Dimension } else { 'resource' }
        $name = switch ($dimension) {
            'meter'        { "$([string]$_.Meter) in $(if ($_.ScopeName) { [string]$_.ScopeName } else { [string]$_.Scope })" }
            'subscription' { if ($_.ScopeName) { [string]$_.ScopeName } else { [string]$_.Scope } }
            default        { if ($_.ResourceName) { [string]$_.ResourceName } else { ([string]$_.ResourceId -split '/')[-1] } }
        }
        $explained = ($null -ne $_.Explained -and [bool]$_.Explained)
        [PSCustomObject]@{
            id          = "C-$([string]$_.RowKey)"
            findingId   = [string]$_.RowKey
            # where the stored finding lives (CostSpikes PartitionKey), and which period it covers
            periodKey   = $pk
            period      = $(if ($Grain -eq 'week') { 'last 7 days' } else { 'last month' })
            dimension   = $dimension
            name        = $name
            resourceId  = [string]$_.ResourceId
            subscription = if ($_.ScopeName) { [string]$_.ScopeName } else { [string]$_.Scope }
            # Who owns it (Allocation.psm1 stamps it nightly); '' for rollups and untagged.
            owner       = (Get-BriefOwner $_ -Key $ownerKey)
            currentUsd  = [Math]::Round([double]$_.SpikeUsd, 2)
            baselineUsd = [Math]::Round([double]$_.BaselineUsd, 2)
            deltaUsd    = [Math]::Round([double]$_.DeltaUsd, 2)
            deltaPct    = if ($_.IsNew -or $null -eq $_.DeltaPct -or [double]$_.DeltaPct -lt 0) { $null } else { [Math]::Round([double]$_.DeltaPct, 1) }
            isNew       = [bool]$_.IsNew
            resolved    = ($state -eq 'resolved')
            # open | decreasing | resolved — judged on the latest settled days, not the period total.
            state       = $state
            # The latest settled days' level on the same footing as currentUsd (per period).
            currentRunRateUsd = if ($null -ne $currentDaily -and $days -gt 0) { [Math]::Round($currentDaily * $days, 2) } else { $null }
            # What is STILL being overspent per period: the current level above the typical one.
            # A falling change is ranked on this, not on the period's peak.
            currentExcessUsd = if ($null -ne $currentDaily -and $days -gt 0) { [Math]::Round([Math]::Max(0, $currentDaily * $days - [double]$_.BaselineUsd), 2) } else { $null }
            currentAsOf = if ($_.CurrentAsOf) { [string]$_.CurrentAsOf } else { $null }
            # How far the daily cost has fallen (negative %), since fallSince (null = against the
            # period's average day).
            fallPct     = if ($null -ne $_.FallPct -and [double]$_.FallPct -lt 0) { [double]$_.FallPct } else { $null }
            fallSince   = if ($_.FallSince) { [string]$_.FallSince } else { $null }
            explained   = $explained
            cause       = if ($explained) { [string]$_.Cause } else { $null }
            facts       = @(Get-BriefFacts -EvidenceJson ([string]$_.EvidenceJson))
        }
    })
    return [PSCustomObject]@{
        periodType  = $Grain
        period      = [string]$pointer.Period
        periodStart = [string]$pointer.PeriodStart
        periodEnd   = [string]$pointer.PeriodEnd
        total       = @($rows | Where-Object { (& $stateOf $_) -ne 'resolved' }).Count
        resolved    = @($rows | Where-Object { (& $stateOf $_) -eq 'resolved' }).Count
        items       = $items
    }
}

# Resources that had any cost on the last -Days settled days (lower-case ids), from CostSnapshots.
# $null when a day has no snapshots at all — then nothing can be concluded and callers must not filter.
function Get-ActiveResourceIds {
    param([Parameter(Mandatory)][string]$Token, [int]$Days = 3, [datetime]$Today = [datetime]::UtcNow.Date)
    $settled = Get-BriefSettledDate -Today $Today
    $active = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; $i -lt $Days; $i++) {
        $day = $settled.AddDays(-$i).ToString('yyyy-MM-dd')
        $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$day'" -Select 'DimensionKey,ResourceId,CostUsd' -Token $Token)
        if (-not $rows.Count) { return $null }
        foreach ($r in $rows) {
            if ([double]$r.CostUsd -le 0) { continue }
            # The id and every parent of it: cost often lands on a child (a database under its
            # server, a pipeline under its factory) while the saving names the parent.
            $id = ([string]$(if ($r.DimensionKey) { $r.DimensionKey } else { $r.ResourceId })).ToLowerInvariant().TrimEnd('/')
            while ($id -match '/providers/' -and $active.Add($id)) {
                $cut = $id.LastIndexOf('/'); if ($cut -le 0) { break }
                $id = $id.Substring(0, $cut)
            }
        }
    }
    return ,$active
}

# The largest OPEN savings: the app's own findings + Advisor, latest runs only.
# Sustained cost increases ('step-up') are not savings and are left out. Where both sources
# flag the same resource, the lower figure is kept so the total is never double-counted.
#   -ExcludeIdle  leave out savings on a resource that has had no cost for the last 3 settled
#                 days (stopped, deallocated or deleted since Advisor / the check last looked).
#                 Reads three days of snapshots, so for the nightly builders, not page loads.
function Get-BriefSavings {
    param([Parameter(Mandatory)][string]$Token, [int]$Top = 5, [switch]$ExcludeIdle, [datetime]$Today = [datetime]::UtcNow.Date)
    $ownerKey = @(Get-AllocationTagKeys -StorageToken $Token)[0]
    $items = @()
    $unconverted = 0
    $subScope = Get-SubscriptionScope -Token $Token
    try {
        $meta = @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings-meta' and RowKey eq 'latest'" -Token $Token) | Select-Object -First 1
        if ($meta -and $meta.LatestRunId) {
            # Statuses, so a dismissed or completed finding is not proposed as an action.
            $statusById = @{}
            try {
                foreach ($s in @(Get-TableEntities -Table 'SavingsStatus' -Filter "PartitionKey eq 'status'" -Token $Token)) { $statusById[[string]$s.RowKey] = [string]$s.Status }
            } catch { Write-Host "brief: savings status read failed: $($_.Exception.Message)" }

            foreach ($r in @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings'" -Token $Token)) {
                if ([string]$r.RunId -ne [string]$meta.LatestRunId -or [string]$r.Category -eq 'step-up') { continue }
                if (-not (Test-InSubscriptionScope -Scope $subScope -Value $r)) { continue }
                # Only the tiers that are added up anywhere: an indicative figure is not
                # something to put in front of someone as "do this, save that".
                $tier = if ($r.Tier) { [string]$r.Tier } elseif ([string]$r.Category -eq 'orphaned') { 'certain' } else { 'indicative' }
                if ($tier -notin @('certain', 'likely')) { continue }
                $st = $statusById[[string]$r.RowKey]
                if ($st -in @('dismissed', 'done')) { continue }
                if ([double]$r.EstMonthlySavingsUsd -le 0) { continue }
                $items += [PSCustomObject]@{
                    id = "S-$([string]$r.RowKey)"; source = 'analysis'; category = [string]$r.Category; tier = $tier
                    title = [string]$r.Title; detail = [string]$r.Detail
                    resourceId = [string]$r.ResourceId; resourceName = [string]$r.ResourceName
                    subscription = [string]$r.SubscriptionName; confidence = [string]$r.Confidence; owner = (Get-BriefOwner $r -Key $ownerKey)
                    monthlyUsd = [Math]::Round([double]$r.EstMonthlySavingsUsd, 2)
                }
            }
        }
    } catch { Write-Host "brief: savings findings read failed: $($_.Exception.Message)" }
    try {
        $meta = @(Get-TableEntities -Table 'Recommendations' -Filter "PartitionKey eq 'advisor-meta' and RowKey eq 'latest'" -Token $Token) | Select-Object -First 1
        foreach ($r in @(Get-TableEntities -Table 'Recommendations' -Filter "PartitionKey eq 'cost'" -Token $Token)) {
            if ($meta -and [string]$r.RunId -ne [string]$meta.LatestRunId) { continue }
            if (-not (Test-InSubscriptionScope -Scope $subScope -Value $r)) { continue }
            if (-not [bool]$r.SavingsConverted) { $unconverted++; continue }
            if ([double]$r.EstMonthlySavingsUsd -le 0) { continue }
            $items += [PSCustomObject]@{
                id = "A-$([string]$r.RowKey)"; source = 'advisor'; category = [string]$r.RecommendationType
                title = if ($r.Solution) { [string]$r.Solution } else { [string]$r.Problem }; detail = [string]$r.Problem
                resourceId = [string]$r.ResourceId; resourceName = [string]$r.ResourceName
                subscription = [string]$r.SubscriptionName; confidence = [string]$r.Impact; owner = (Get-BriefOwner $r -Key $ownerKey)
                monthlyUsd = [Math]::Round([double]$r.EstMonthlySavingsUsd, 2)
                # Reservation / savings-plan purchases: Advisor lists the same purchase several
                # times — 1- and 3-year terms, 7/30/60-day look-backs, shared or single scope.
                # They are alternatives (you buy one), so only the best of each is counted.
                alternativeOf = ("$($r.ResourceId)|$(if ($r.Solution) { $r.Solution } else { $r.Problem })|$($r.Region)|$($r.ReservedResourceType)|$($r.TargetSku)|$($r.CurrentSku)").ToLowerInvariant()
                term = [string]$r.Term; lookback = [string]$r.LookbackPeriod
                # A reservation / savings-plan purchase for the billing account: no resource
                # behind it, so it has no owner and can't lack one.
                billingScope = ([string]$r.ResourceId -notmatch '(?i)/providers/')
            }
        }
    } catch { Write-Host "brief: advisor read failed: $($_.Exception.Message)" }

    # Billing-scope purchase alternatives: keep the largest saving of each purchase.
    $alternatives = 0
    $best = [ordered]@{}; $rest = @()
    foreach ($i in $items) {
        if ($i.source -ne 'advisor' -or [string]$i.resourceId -match '(?i)/providers/') { $rest += $i; continue }
        $k = [string]$i.alternativeOf
        if (-not $best.Contains($k)) { $best[$k] = $i; continue }
        $alternatives++
        if ($i.monthlyUsd -gt $best[$k].monthlyUsd) { $best[$k] = $i }
    }
    $items = @($rest) + @($best.Values)
    foreach ($i in $items) { if ($i.PSObject.Properties['alternativeOf']) { $i.PSObject.Properties.Remove('alternativeOf') } }

    # One entry per resource (lowest figure) for resource-scoped items; billing-scope items
    # (no /subscriptions/.../providers/ path) are kept as they are.
    $byResource = @{}
    $kept = @()
    foreach ($i in $items) {
        if ([string]$i.resourceId -notmatch '(?i)/providers/') { $kept += $i; continue }
        $k = ([string]$i.resourceId).ToLowerInvariant()
        if (-not $byResource.ContainsKey($k) -or $i.monthlyUsd -lt $byResource[$k].monthlyUsd) { $byResource[$k] = $i }
    }
    $kept += @($byResource.Values)

    $idleCount = 0
    if ($ExcludeIdle) {
        $active = $null
        try { $active = Get-ActiveResourceIds -Token $Token -Today $Today } catch { Write-Host "brief: snapshot read failed, idle check skipped: $($_.Exception.Message)" }
        if ($null -ne $active) {
            $before = $kept.Count
            $kept = @($kept | Where-Object { [string]$_.resourceId -notmatch '(?i)/providers/' -or $active.Contains(([string]$_.resourceId).ToLowerInvariant().TrimEnd('/')) })
            $idleCount = $before - $kept.Count
        }
    }
    $total = 0.0; foreach ($i in $kept) { $total += [double]$i.monthlyUsd }

    return [PSCustomObject]@{
        totalMonthlyUsd  = [Math]::Round($total, 2)
        count            = $kept.Count
        unconvertedCount = $unconverted
        # left out by -ExcludeIdle: the resource has had no cost for three days
        idleCount        = $idleCount
        # Advisor purchase recommendations not counted: other terms / look-backs of the same purchase
        alternativeCount = $alternatives
        items            = @($kept | Sort-Object monthlyUsd -Descending | Select-Object -First $Top)
    }
}

# Assemble the whole deterministic brief for a grain.
function Build-BriefPayload {
    param(
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$Grain,
        [Parameter(Mandatory)][string]$Token,
        [datetime]$Today = [datetime]::UtcNow.Date
    )
    $from = (Get-UtcMonthStart -Date (Get-BriefSettledDate -Today $Today)).AddMonths(-2).ToString('yyyy-MM-dd')
    $days = @{}
    foreach ($row in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailytotal' and RowKey ge '$from'" -Token $Token)) {
        $days[[string]$row.RowKey] = $row
    }
    $notes = @()
    $spend = Build-BriefSpend -Days $days -Grain $Grain -Today $Today
    # ONE month-end projection on the Overview: Azure's forecast (SyncMonthlyCosts-Timer) replaces
    # the straight-line run-rate whenever there is one, so the brief's prose can't quote a second
    # month-end figure beside the forecast on the page.
    if ($spend.kind -eq 'month-to-date') {
        try {
            $ov = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthoverview' and RowKey eq 'current'" -Token $Token) | Select-Object -First 1
            if ($ov -and [string]$ov.Month -eq [string]$spend.month -and $null -ne $ov.ForecastUsd -and [double]$ov.ForecastUsd -ge 0) {
                $fUsd = [Math]::Round([double]$ov.ForecastUsd, 2)
                $spend | Add-Member -NotePropertyName forecastUsd -NotePropertyValue $fUsd -Force
                $spend | Add-Member -NotePropertyName forecastVsPreviousMonthPct -NotePropertyValue $(if ($spend.previousMonth.complete) { Get-PctChange $fUsd $spend.previousMonth.usd } else { $null }) -Force
                $spend.runRateUsd = $null; $spend.runRateBilling = $null; $spend.runRateVsPreviousMonthPct = $null
            }
        } catch { Write-Host "brief: month overview read failed (run-rate kept): $($_.Exception.Message)" }
    }
    if (-not $spend.current.complete) { $notes += Get-PortalText 'brief.missingDays' @{ n = ($spend.current.expectedDays - $spend.current.days); month = $spend.month } }

    $changes = Get-BriefChanges -Grain $Grain -Token $Token -Top 8
    if (-not $changes.period) { $notes += Get-PortalText "brief.noPeriod.$Grain" }
    # The page shows one set of findings (this brief's), so they also cover last month's changes.
    if ($Grain -eq 'week') {
        try {
            $monthChanges = Get-BriefChanges -Grain month -Token $Token -Top 5
            $seen = @{}; foreach ($c in @($changes.items)) { $seen[[string]$c.id] = $true }
            $extra = @($monthChanges.items | Where-Object { -not $seen.ContainsKey([string]$_.id) })
            if ($extra.Count) { $changes.items = @($changes.items) + $extra; $changes.total = [int]$changes.total + $extra.Count }
        } catch { Write-Host "brief: last month's changes read failed: $($_.Exception.Message)" }
    }
    # Every open saving, so each owner's total is complete; the payload carries the largest.
    $allSavings = Get-BriefSavings -Token $Token -Top 1000 -ExcludeIdle -Today $Today
    $savings = [PSCustomObject]@{
        totalMonthlyUsd = $allSavings.totalMonthlyUsd; count = $allSavings.count; unconvertedCount = $allSavings.unconvertedCount
        items = @($allSavings.items | Select-Object -First 8)
    }
    if ($allSavings.alternativeCount -gt 0) { $notes += Get-PortalText 'brief.alternatives' @{ n = $allSavings.alternativeCount } }
    if ($allSavings.idleCount -gt 0) { $notes += Get-PortalText 'brief.idle' @{ n = $allSavings.idleCount } }
    if ($savings.unconvertedCount -gt 0) { $notes += Get-PortalText 'brief.unconverted' @{ n = $savings.unconvertedCount } }

    $owners = @(); $resourceGroups = @()
    try {
        $owners = @(Get-InsightOwners -Token $Token -Savings @($allSavings.items))
        $resourceGroups = @(Get-InsightResourceGroups -Token $Token)
    } catch { Write-Host "brief: allocation read failed: $($_.Exception.Message)" }
    if (-not $resourceGroups.Count) { $notes += Get-PortalText 'brief.noAllocation' }

    return [PSCustomObject]@{
        version        = $script:BriefVersion
        grain          = $Grain
        spend          = $spend
        changes        = $changes
        savings        = $savings
        owners         = $owners
        resourceGroups = $resourceGroups
        notes          = @($notes)
    }
}

# ----------------------------------------------------------------------------
# Update-PortfolioBrief — build the payload, run the findings agent (CostAgent.psm1) when AI is
# available, store and return the brief.
#   -Force  ignore stored findings even when the payload is unchanged (admin regenerate)
# Returns the stored document: { grain; generatedAt; payload; ai; ruleFindings; aiStatus; grounded }.
# ai = { summary; findings; toolCalls; dropped } — null without AI. ruleFindings is always there.
# aiStatus: 'explained' | 'reused' | 'not-configured' | 'budget-exceeded' | 'failed'
# ----------------------------------------------------------------------------
function Update-PortfolioBrief {
    param(
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$Grain,
        [Parameter(Mandatory)][string]$Token,
        [datetime]$Today = [datetime]::UtcNow.Date,
        [switch]$Force,
        # Figures only: the monthly brief feeds the "last month" tile, the findings come from the
        # weekly one, so the monthly run spends no AI calls.
        [switch]$SkipAi
    )
    $payload = Build-BriefPayload -Grain $Grain -Token $Token -Today $Today
    $sysPrompt = Get-InsightSystemPrompt
    $payloadJson = $payload | ConvertTo-Json -Depth 12
    $key = Get-NarrationKey -SystemPrompt $sysPrompt -PayloadJson $payloadJson -Model $env:AI_MODEL
    $ruleFindings = @(Get-RuleFindings -Payload $payload)

    $stored = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'brief' and RowKey eq '$Grain'" -Token $Token) | Select-Object -First 1
    $storedDoc = $null
    if ($stored -and $stored.BriefJson) { try { $storedDoc = [string]$stored.BriefJson | ConvertFrom-Json } catch { $storedDoc = $null } }

    $ai = $null; $aiStatus = 'not-configured'; $grounded = $true; $aiError = $null
    $aiConfigured = -not $SkipAi -and (Test-AiConfigured)
    if (-not $Force -and $storedDoc -and [string]$stored.NarrationKey -eq $key -and $storedDoc.ai -and $storedDoc.ai.PSObject.Properties['findings']) {
        $ai = $storedDoc.ai; $aiStatus = 'reused'
        $grounded = if ($null -ne $storedDoc.grounded) { [bool]$storedDoc.grounded } else { $true }
    } elseif ($aiConfigured) {
        try {
            $res = Invoke-CostInsights -Payload $payload -Token $Token
            if ($res.ai -and @($res.ai.findings).Count) {
                $ai = $res.ai
                # Dropped findings never reach the page; the flag says some were.
                $grounded = ([int]$res.ai.dropped -eq 0)
                $aiStatus = 'explained'
            } else { $aiStatus = 'failed'; $aiError = if ($res.error) { $res.error } else { 'no finding passed the checks' } }
        } catch {
            $aiStatus = if (Test-AiBudgetExceeded -ErrorRecord $_) { 'budget-exceeded' } else { 'failed' }
            $aiError = $_.Exception.Message
            Write-Host "brief ($Grain): AI step $aiStatus — $aiError"
        }
    }

    $doc = [PSCustomObject]@{
        grain       = $Grain
        generatedAt = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm') + ' UTC'
        generatedAtIso = [datetime]::UtcNow.ToString('o')
        payload     = $payload
        ai          = $ai
        ruleFindings = $ruleFindings
        aiStatus    = $aiStatus
        grounded    = [bool]$grounded
    }
    $json = $doc | ConvertTo-Json -Depth 14 -Compress
    # Table string properties hold 32K characters. Shed detail, least useful first, before failing.
    if ($json.Length -gt 30000) {
        foreach ($c in @($payload.changes.items)) { $c.facts = @() }
        $json = $doc | ConvertTo-Json -Depth 14 -Compress
    }
    if ($json.Length -gt 30000) {
        foreach ($s in @($payload.savings.items)) { $s.detail = Limit-InsightText $s.detail 160 }
        if ($ai) { foreach ($t in @($ai.toolCalls)) { $t.args = Limit-InsightText $t.args 120 } }
        $payload.owners = @($payload.owners | Select-Object -First 8)
        $json = $doc | ConvertTo-Json -Depth 14 -Compress
    }
    Set-TableEntity -Table 'CostSummary' -Token $Token -Entity @{
        PartitionKey = 'brief'; RowKey = $Grain
        BriefJson    = $json
        NarrationKey = $key
        AiStatus     = $aiStatus
        AiError      = if ($aiError) { $aiError.Substring(0, [Math]::Min(500, $aiError.Length)) } else { '' }
        Subject      = [string]$payload.spend.month
        GeneratedAt  = $doc.generatedAtIso
        # The subscription scope it was built for: a change makes it due (Test-BriefDue).
        ScopeHash    = (Get-SubscriptionScope -Token $Token).Hash
    }
    return $doc
}

# Is a stored brief due for regeneration? -Stored is the CostSummary row (or $null).
function Test-BriefDue {
    param(
        [Parameter(Mandatory)][ValidateSet('week', 'month')][string]$Grain,
        $Stored,
        [datetime]$Today = [datetime]::UtcNow.Date,
        # The current subscription scope's hash; a brief built for another scope is due.
        [string]$ScopeHash
    )
    if (-not $Stored -or -not $Stored.GeneratedAt) { return $true }
    # Built by an older version (no owners, resource groups or findings): rebuild tonight rather
    # than show the old shape until the next Monday / month.
    if ($Stored.PSObject.Properties['BriefJson'] -and [string]$Stored.BriefJson -match '"version":\s*(\d+)' -and [int]$Matches[1] -lt $script:BriefVersion) { return $true }
    if ($ScopeHash) {
        $storedScope = if ($Stored.ScopeHash) { [string]$Stored.ScopeHash } else { 'all' }
        if ($storedScope -ne $ScopeHash) { return $true }
    }
    $generated = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Stored.GeneratedAt, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$generated)) { return $true }
    if ($Grain -eq 'week') {
        if (($Today - $generated.Date).TotalDays -ge 7) { return $true }
        return ($Today.DayOfWeek -eq [System.DayOfWeek]::Monday -and $generated.Date -lt $Today)
    }
    $target = (Get-BriefTargetMonth -Today $Today).ToString('yyyy-MM')
    return ([string]$Stored.Subject -ne $target)
}

Export-ModuleMember -Function `
    Get-BriefSettledDate, Get-BriefTargetMonth, Measure-MonthSpend, Build-BriefSpend, Get-BriefFacts, `
    Get-BriefChanges, Get-BriefSavings, Get-ActiveResourceIds, Build-BriefPayload, Update-PortfolioBrief, Test-BriefDue, Get-BriefOwner
