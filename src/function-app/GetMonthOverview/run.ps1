using namespace System.Net
param($Request, $TriggerMetadata)

# Everything the Overview's month view needs, in one call. Read-only; members allowed.
#
# The question this page answers is "are we on track this month, what moved it, and what can we
# save?" — so the figures are MONTHLY, not daily. Daily spend still exists (the trend chart),
# but a single day is noise next to a bill.
#
# Served entirely from storage:
#   month-to-date, the same days of last month, last month's total   dailytotal rows
#                                                                    (the cost ingest, CostIngest.psm1)
#   forecast, budgets                                                CostSummary/monthoverview
#                                                                    (SyncMonthlyCosts-Timer)
#   open savings                                                     SavingsFindings +
#                                                                    Recommendations (latest runs)
#
# Month-to-date is built by Build-BriefSpend (Brief.psm1) so the tile and the executive brief
# can never disagree: one implementation, one set of completeness rules.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$today = [datetime]::UtcNow.Date
$subScope = Get-SubscriptionScope -Token $token

# --- month-to-date, same days last month, last month total ---
$spend = $null
try {
    $from = (Get-UtcMonthStart -Date (Get-BriefSettledDate -Today $today)).AddMonths(-2).ToString('yyyy-MM-dd')
    $days = @{}
    foreach ($row in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailytotal' and RowKey ge '$from'" -Token $token)) {
        $days[[string]$row.RowKey] = $row
    }
    if ($days.Count) { $spend = Build-BriefSpend -Days $days -Grain 'week' -Today $today }
} catch { Write-Host "daily totals read failed: $($_.Exception.Message)" }

# --- the nightly month view (forecast, budgets) ---
$ov = $null
try {
    $ov = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthoverview' and RowKey eq 'current'" -Token $token) | Select-Object -First 1
} catch { Write-Host "month overview read failed: $($_.Exception.Message)" }

function Read-Json { param($Value) if (-not $Value) { return @() } try { return @([string]$Value | ConvertFrom-Json) } catch { return @() } }


# Budgets are reported by Azure in their own currency; they are shown as-is with their percent
# used, never summed with anything else.
$budgets = @(Read-Json $ov.BudgetsJson | Where-Object { Test-InSubscriptionScope -Scope $subScope -Value $_ } | ForEach-Object {
    $amount = [double]$_.Amount
    $spent = [double]$_.SpentAmount
    [PSCustomObject]@{
        name = [string]$_.Name
        scopeName = [string]$_.ScopeName
        timeGrain = [string]$_.TimeGrain
        amount = $amount
        spent = $spent
        currency = [string]$_.Currency
        usedPct = if ($amount -gt 0) { [Math]::Round(($spent / $amount) * 100, 1) } else { $null }
        forecast = if ($null -ne $_.ForecastAmount) { [double]$_.ForecastAmount } else { $null }
        # True = Azure's own budget forecast lands above the budget before the period ends.
        projectedToExceed = ($null -ne $_.ForecastAmount -and $amount -gt 0 -and [double]$_.ForecastAmount -gt $amount)
        endDate = [string]$_.EndDate
        # True = it measures everything the portal covers, so it may speak for the month (verdict).
        coversPortal = [bool]$_.CoversPortal
    }
})

# --- open savings (same rules as the brief: countable tiers only, one entry per resource) ---
$savings = $null
try { $savings = Get-BriefSavings -Token $token -Top 3 } catch { Write-Host "savings read failed: $($_.Exception.Message)" }

# --- what has actually been saved this month (settled 'done' findings) ---
$realised = 0.0
try {
    $monthPrefix = [datetime]::UtcNow.ToString('yyyy-MM')
    foreach ($s in @(Get-TableEntities -Table 'SavingsStatus' -Filter "PartitionKey eq 'status'" -Token $token)) {
        if (-not (Test-InSubscriptionScope -Scope $subScope -Value $s)) { continue }
        if ($s.RealisedAt -and ([string]$s.RealisedAt).StartsWith($monthPrefix) -and $null -ne $s.RealisedUsd) {
            $realised += [double]$s.RealisedUsd
        }
    }
} catch { Write-Host "savings status read failed: $($_.Exception.Message)" }

$forecastUsd = if ($ov -and $null -ne $ov.ForecastUsd -and [double]$ov.ForecastUsd -ge 0) { [double]$ov.ForecastUsd } else { $null }
$forecastBilling = if ($ov -and $null -ne $ov.ForecastBilling -and [double]$ov.ForecastBilling -ge 0) { [double]$ov.ForecastBilling } else { $null }

$result = [PSCustomObject]@{
    # Null until the first ingest has written daily totals.
    spend            = $spend
    month            = if ($ov) { [string]$ov.Month } elseif ($spend) { [string]$spend.month } else { $null }
    settledThrough   = if ($ov) { [string]$ov.SettledThrough } elseif ($spend) { [string]$spend.throughDate } else { $null }
    costType         = if ($ov -and $ov.CostType) { [string]$ov.CostType } else { $null }
    # Azure's own month-end projection. null = it could not produce one (too little history in
    # the scope, or the nightly sync hasn't run) — the UI then labels the run-rate as such.
    forecast         = [PSCustomObject]@{
        usd      = $forecastUsd
        billing  = $forecastBilling
        currency = if ($ov) { [string]$ov.ForecastCurrency } else { '' }
        note     = if ($ov) { [string]$ov.ForecastNote } else { '' }
        source   = if ($null -ne $forecastUsd) { 'azure' } else { 'none' }
        coverage = if ($ov -and $ov.ForecastCoverage) { [string]$ov.ForecastCoverage } else { $null }
    }
    budgets          = $budgets
    budgetNote       = if ($ov) { [string]$ov.BudgetNote } else { '' }
    savings          = if ($savings) {
        [PSCustomObject]@{
            totalMonthlyUsd = $savings.totalMonthlyUsd
            count = $savings.count
            unconvertedCount = $savings.unconvertedCount
            # Monthly savings already banked: findings marked done whose cost then actually
            # fell. Settled once by DetectSavings-Timer, so this figure doesn't re-count itself.
            realisedThisMonthUsd = [Math]::Round($realised, 2)
            top = @($savings.items)
        }
    } else { $null }
    lastSynced       = if ($ov) { [string]$ov.SyncedAt } else { $null }
    # False = the nightly sync has never written the month view; the month-to-date figures
    # above may still be present, so the page shows what it has.
    ready            = ($null -ne $ov -and $null -ne $spend)
    # True = the subscription scope changed and the totals above still include the previous
    # set; the next nightly run rebuilds them.
    scopePending     = ((Test-ScopeHashPending -Scope $subScope -Stored (Get-DailyTotalScopeHash -Token $token)) -or
                        ($ov -and (Test-ScopeHashPending -Scope $subScope -Stored ([string]$ov.ScopeHash))))
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 10)
    Headers    = @{ "Content-Type" = "application/json" }
})
