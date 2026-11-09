param($Timer)

Write-Host "=== Monthly subscription cost sync started ==="

# The Overview's MONTH VIEW -> CostSummary/'monthoverview', served by GetMonthOverview: Azure's own
# month-end forecast and the customer's Azure budgets.
#
# The monthly total per subscription ('monthly-sub') is no longer queried here. It used to be a
# 13-month query per subscription every night — about 1,100 QPU on a 42-subscription tenant, nearly
# twice Cost Management's hourly per-tenant quota — and its one reader (SyncCommitments-Timer) only
# uses the latest month. The cost ingest now derives those rows from its daily per-subscription
# totals (Modules/CostIngest.psm1, Update-MonthlySubRows), and this sync reads the month-to-date
# from them.
#
# Runs daily at 02:55 UTC, after the nightly ingest; also as a follow-up step once a new
# deployment's first cost history has loaded.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$mgmtToken    = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'

$costType = Get-CostTypeSetting -StorageToken $storageToken
Write-Host "Cost type: $costType"

$subScope = Get-SubscriptionScope -Token $storageToken
$subs = @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken -StorageToken $storageToken)
if (-not $subs.Count) {
    Write-Host "No accessible subscriptions — grant the identity Cost Management Reader + Reader at a management group."
    Write-Host "=== Monthly subscription cost sync finished (no subscriptions) ==="
    return
}
$today = [datetime]::UtcNow.Date

# ============================================================================
# Overview month view: forecast and budgets
# ============================================================================
# One row, read by GetMonthOverview. Everything here is nightly and stored, so the Overview
# stays a pure table read — the page must never wait on Cost Management.
#
# The month in question is the one the SETTLED day belongs to (D-2, the same cut-off detection
# and the trend chart use), so every figure on the page describes the same month.
$settled = Get-RollingWindowEndDate -Today $today
$monthStart = Get-UtcMonthStart -Date $settled
$monthKey = $monthStart.ToString('yyyy-MM')
$prevKey = $monthStart.AddMonths(-1).ToString('yyyy-MM')

# --- month-end forecast (Azure's own model, not our straight line) ---
# It must cover the SAME subscriptions as the month-to-date beside it on the Overview. Before
# 2026-09-18 it silently fell back to the deployment subscription whenever costQueryScope was
# unset, while month-to-date was tenant-wide — a like-for-unlike comparison on the main page.
#   1. a management group that contains every included subscription (configured, or found by
#      Update-ResolvedCostScope), filtered to the included ones when it holds more;
#   2. otherwise the per-subscription forecasts, summed. A subscription Azure can't forecast
#      (too little history) is left out only while it is a small share of month-to-date: past
#      5% the sum would understate the month, so no forecast is shown and the UI falls back to
#      a labelled run-rate.
# Either way the forecast's month-to-date part is checked against the portal's own per-
# subscription month-to-date. A management group can CONTAIN every subscription and still show
# only part of their cost (subscriptions on another billing agreement — seen on a live tenant,
# where the group's cost data covered a small fraction of the spend). Such a forecast is rejected, and the group is marked
# unusable for tenant-wide questions (Set-CostScopeInsufficient). A forecast below what has
# already been spent is rejected too: a month cannot end lower than it has already cost.
$monthEnd = $monthStart.AddMonths(1).AddDays(-1)
# Month-to-date per subscription, from the rows the cost ingest derives (see the header).
$mtdBySub = @{}
foreach ($e in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthly-sub' and RowKey ge '$monthKey|' and RowKey lt '$monthKey|~'" -Token $storageToken)) {
    $mtdBySub[([string]$e.SubscriptionId).ToLowerInvariant()] = [double]$e.CostUsd
}
if (-not $mtdBySub.Count) { Write-Host "  no month-to-date rows for $monthKey yet (the cost ingest has not loaded this month) — forecast checks use 0." }
$mtdTotal = 0.0; foreach ($v in $mtdBySub.Values) { $mtdTotal += $v }
$scopeCoverageOk = $true
$forecastUsd = $null; $forecastBilling = $null; $forecastCurrency = ''; $forecastNote = ''
$forecastCoverage = 'none'
$includedIds = @($subs | ForEach-Object { ([string]$_.Id).ToLowerInvariant() })
$resolvedScope = Update-ResolvedCostScope -MgmtToken $mgmtToken -StorageToken $storageToken -SubscriptionIds $includedIds
$forecastScope = [string]$resolvedScope.Scope
if ($forecastScope -and $forecastScope -notmatch '(?i)managementGroups/') {
    # A configured subscription scope only answers for the whole portal when it IS the portal.
    if ($includedIds.Count -ne 1 -or (Get-RowSubscriptionId -Row $forecastScope) -ne $includedIds[0]) {
        Write-Host "  costQueryScope is a single subscription but the portal covers $($includedIds.Count) — forecasting per subscription instead."
        $forecastScope = ''
    }
}

if ($forecastScope) {
    # Filter when the group holds subscriptions the portal doesn't cover (other subscriptions in
    # the group, or ones excluded by the operator's scope). A configured scope's contents are
    # unknown (Extra = -1), so it is always filtered.
    $forecastSubIds = if ($resolvedScope.Extra -ne 0 -or $subScope.Ids) { $includedIds } else { @() }
    try {
        $f = Get-CostForecast -Scope $forecastScope -MgmtToken $mgmtToken -From $monthStart -To $monthEnd -Field 'CostUSD' -CostType $costType -SubscriptionIds $forecastSubIds
        Write-Host "  forecast for ${monthKey} at ${forecastScope}: $($f.TotalAmount) USD (actual so far $($f.ActualAmount); per-subscription month-to-date $([Math]::Round($mtdTotal, 2)))"
        # The forecast's actual part ends a day or two before the per-subscription figures, so
        # it may read a little lower; far lower means the group doesn't see all the spend.
        $coveragePct = if ($mtdTotal -gt 0) { ([double]$f.ActualAmount / $mtdTotal) * 100 } else { 100.0 }
        if ($mtdTotal -gt 0 -and $coveragePct -lt 85) {
            $scopeCoverageOk = $false
            $groupName = if ($resolvedScope.Name) { $resolvedScope.Name } else { ($forecastScope -split '/')[-1] }
            $forecastNote = "Azure's forecast for $groupName sees only $([Math]::Round($coveragePct, 0))% of this month's spend (the rest isn't visible at management-group level), so the portal's own estimate is shown."
            if ($resolvedScope.Source -eq 'discovered') { Set-CostScopeInsufficient -StorageToken $storageToken -Name $groupName -CoveragePct $coveragePct -Subscriptions $includedIds.Count }
        } elseif ([double]$f.TotalAmount -lt $mtdTotal * 0.98) {
            $forecastNote = 'Azure''s forecast came out below what has already been spent this month, so the portal''s own estimate is shown.'
        } else {
            $forecastUsd = $f.TotalAmount
            $forecastCoverage = 'scope'
            try {
                $fn = Get-CostForecast -Scope $forecastScope -MgmtToken $mgmtToken -From $monthStart -To $monthEnd -Field 'Cost' -CostType $costType -SubscriptionIds $forecastSubIds
                $forecastBilling = $fn.TotalAmount; $forecastCurrency = [string]$fn.Currency
            } catch { Write-Host "  forecast (billing currency) failed: $($_.Exception.Message)" }
        }
    } catch {
        # Azure declines to forecast a scope with too little history, and that is a normal
        # state for a new tenant — the UI falls back to a labelled run-rate.
        $forecastNote = 'Azure could not produce a forecast for these subscriptions yet.'
        Write-Host "  forecast unavailable: $($_.Exception.Message)"
    }
} else {
    # Per subscription. One query each (USD); the billing-currency figure uses Azure's own
    # USD->billing ratio from the daily totals rather than a second query per subscription.
    $sum = 0.0; $missed = @(); $missedMtd = 0.0
    foreach ($sub in $subs) {
        try {
            $f = Get-CostForecast -Scope "/subscriptions/$($sub.Id)" -MgmtToken $mgmtToken -From $monthStart -To $monthEnd -Field 'CostUSD' -CostType $costType
            $sum += [double]$f.TotalAmount
        } catch {
            $missed += $sub.Name
            $missedMtd += [double]$mtdBySub[([string]$sub.Id).ToLowerInvariant()]
        }
    }
    $missedShare = if ($mtdTotal -gt 0) { $missedMtd / $mtdTotal } else { if ($missed.Count) { 1.0 } else { 0.0 } }
    if ($missed.Count -eq $subs.Count) {
        $forecastNote = 'Azure could not produce a forecast for these subscriptions yet.'
    } elseif ($sum -lt ($mtdTotal - $missedMtd) * 0.98) {
        $forecastNote = 'Azure''s forecast came out below what has already been spent this month, so the portal''s own estimate is shown.'
    } elseif ($missedShare -gt 0.05) {
        $forecastNote = "Azure could not forecast $($missed.Count) subscription(s) holding $([Math]::Round($missedShare * 100, 0))% of month-to-date spend, so no forecast is shown."
    } else {
        $forecastUsd = [Math]::Round($sum, 2)
        $forecastCoverage = if ($missed.Count) { 'partial' } else { 'per-subscription' }
        if ($missed.Count) { $forecastNote = "Excludes $($missed.Count) subscription(s) Azure could not forecast ($([Math]::Round($missedShare * 100, 1))% of month-to-date)." }
        try {
            $rate = Get-BillingCurrencyRate -StorageToken $storageToken
            if ($rate) { $forecastBilling = [Math]::Round($forecastUsd * [double]$rate.Rate, 2); $forecastCurrency = [string]$rate.Currency }
        } catch { Write-Host "  billing rate unavailable for the forecast: $($_.Exception.Message)" }
    }
    Write-Host "  forecast for ${monthKey}: per subscription, $($subs.Count - $missed.Count)/$($subs.Count) forecast, total $forecastUsd USD."
}

# --- budgets the customer already set in Azure ---
# Per subscription, plus the management-group scope when one is configured. These are plain
# ARM reads, not Cost Management queries, so they don't touch that rate limit.
$budgets = @()
foreach ($sub in $subs) {
    $budgets += @(Get-ConsumptionBudgets -Scope "/subscriptions/$($sub.Id)" -MgmtToken $mgmtToken -ScopeName $sub.Name)
}
# A management-group budget measures the whole group, so it is left out while a subscription
# scope is set — it would be compared against a different total than the one on screen.
# Only when that group holds exactly the portal's subscriptions (a configured scope is taken
# as meant); one with extra subscriptions would be measuring someone else's spend too.
$budgetNote = ''
$mgScope = if ([string]$resolvedScope.Scope -match '(?i)managementGroups/') { [string]$resolvedScope.Scope } else { '' }
if ($mgScope -and $subScope.Ids) {
    $budgetNote = 'Management-group budgets are hidden while a subscription scope is set.'
} elseif ($mgScope -and $resolvedScope.Extra -le 0) {
    $budgets += @(Get-ConsumptionBudgets -Scope $mgScope -MgmtToken $mgmtToken -ScopeName $(if ($resolvedScope.Name) { $resolvedScope.Name } else { 'Management group' }))
}
# A budget filtered to a tag measures one cost centre or owner, not the month: those go to the
# statements (TagBudgetsJson, up to 100) and never stand in for "the budget" on the Overview.
$byUse = { if ($_.Amount -gt 0) { $_.SpentAmount / $_.Amount } else { 0 } }
# Only a budget that measures everything the portal covers may speak for the month in the
# Overview verdict: an unfiltered management-group budget (when that group sees all the spend), or
# the subscription's own budget when the portal covers just that one subscription. The others
# (one subscription of many — e.g. a dev subscription's small budget) are listed, never the verdict.
foreach ($b in $budgets) {
    $isMg = ([string]$b.Scope -match '(?i)managementGroups/')
    $covers = (-not $b.ResourceGroupId) -and (-not $b.ExtraFilters) -and (-not @($b.TagFilters | Where-Object { $_ }).Count) -and (
        ($isMg -and $scopeCoverageOk) -or (-not $isMg -and $includedIds.Count -eq 1))
    $b | Add-Member -NotePropertyName CoversPortal -NotePropertyValue ([bool]$covers) -Force
}
# Budgets set on a resource group (the subscription listing returns them too) measure one group:
# SyncAllocation-Timer maps each to the group's allocation tags for the statements.
$rgBudgets = @($budgets | Where-Object { $_.ResourceGroupId } | Sort-Object -Property @{ Expression = $byUse; Descending = $true } | Select-Object -First 300)
$budgets = @($budgets | Where-Object { -not $_.ResourceGroupId })
$tagBudgets = @($budgets | Where-Object { @($_.TagFilters | Where-Object { $_ }).Count } | Sort-Object -Property @{ Expression = $byUse; Descending = $true } | Select-Object -First 100)
$budgets = @($budgets | Where-Object { -not @($_.TagFilters | Where-Object { $_ }).Count } | Sort-Object -Property @{ Expression = { [bool]$_.CoversPortal }; Descending = $true }, @{ Expression = $byUse; Descending = $true } | Select-Object -First 10)

Set-TableEntity -Table 'CostSummary' -Token $storageToken -Entity @{
    PartitionKey        = 'monthoverview'
    RowKey              = 'current'
    Month               = $monthKey
    PreviousMonth       = $prevKey
    SettledThrough      = $settled.ToString('yyyy-MM-dd')
    CostType            = $costType
    # -1, not $null: a MERGE keeps an omitted or null property, so a forecast that stopped
    # being available would otherwise leave last night's figure on the card forever.
    ForecastUsd         = if ($null -ne $forecastUsd) { [double]$forecastUsd } else { -1 }
    ForecastBilling     = if ($null -ne $forecastBilling) { [double]$forecastBilling } else { -1 }
    ForecastCurrency    = $forecastCurrency
    ForecastNote        = $forecastNote
    # 'scope' (one management-group query), 'per-subscription', 'partial' (a few small ones
    # couldn't be forecast) or 'none'.
    ForecastCoverage    = $forecastCoverage
    BudgetsJson         = (@($budgets) | ConvertTo-Json -Compress -AsArray -Depth 4)
    # Resource-group and tag budgets live in their own rows (Save-MonthBudgetList): 300 of them
    # exceed the 64 KiB a Table property can hold, which failed this whole row with 400 Bad
    # Request. The inline properties are emptied so a reader can't pick up a stale list.
    TagBudgetsJson      = ''
    RgBudgetsJson       = ''
    TagBudgetRows       = (Save-MonthBudgetList -Kind Tag -Items $tagBudgets -StorageToken $storageToken)
    RgBudgetRows        = (Save-MonthBudgetList -Kind Rg -Items $rgBudgets -StorageToken $storageToken)
    BudgetCount         = @($budgets).Count
    BudgetNote          = $budgetNote
    # Which subscription scope these tenant-wide figures were built for (GetMonthOverview
    # reports scopePending until the next run when it differs from the current one).
    ScopeHash           = $subScope.Hash
    SyncedAt            = ([datetime]::UtcNow.ToString('o'))
}
Write-Host "Month overview for ${monthKey}: $(@($budgets).Count) budget(s), $(@($tagBudgets).Count) tag budget(s), $(@($rgBudgets).Count) resource-group budget(s)."

Write-Host "=== Monthly subscription cost sync finished: month overview for $monthKey across $($subs.Count) subscription(s) ==="
