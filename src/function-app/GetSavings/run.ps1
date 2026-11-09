using namespace System.Net
param($Request, $TriggerMetadata)

# The app's OWN savings conclusions (deterministic detectors, not Advisor), written by
# DetectSavings-Timer, merged with the status an admin set on each one. Read-only; members
# allowed.
#
# TIERS decide what is added up. 'certain' is measured waste (an orphan's own cost), 'likely'
# is a priced change with a known before and after, 'indicative' is shown but never totalled
# (no published price, or a reservation already pays for it). 'not-a-saving' rows — sustained
# cost increases — are money now being spent, not money available to stop spending; they are
# served under `increases` for the Cost changes page and never counted here.
#
# STATUS: open | in-progress | done | dismissed. Dismissed rows are left out unless
# ?includeDismissed=true, and a dismissed finding whose figure has since moved by more than
# half comes back on its own — the thing that was dismissed is not the thing being reported now.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$includeDismissed = ($Request.Query -and [string]$Request.Query['includeDismissed'] -eq 'true')
$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# Findings (and realised amounts) of subscriptions outside the operator's scope are hidden.
$subScope = Get-SubscriptionScope -Token $token

# Which run is current?
$latestRunId = $null
try {
    $meta = @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings-meta' and RowKey eq 'latest'" -Token $token) | Select-Object -First 1
    if ($meta) { $latestRunId = [string]$meta.LatestRunId }
} catch { Write-Host "savings meta read failed: $($_.Exception.Message)" }

# Status rows, keyed by finding id.
$statusById = @{}
try {
    foreach ($s in @(Get-TableEntities -Table 'SavingsStatus' -Filter "PartitionKey eq 'status'" -Token $token)) {
        $statusById[[string]$s.RowKey] = $s
    }
} catch { Write-Host "savings status read failed: $($_.Exception.Message)" }

$findings = @(); $increases = @()
if ($latestRunId) {
    try {
        $rows = @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings'" -Token $token)
        foreach ($r in $rows | Where-Object { [string]$_.RunId -eq $latestRunId -and (Test-InSubscriptionScope -Scope $subScope -Value $_) }) {
            $evidence = @{}
            if ($r.Evidence) { try { $evidence = $r.Evidence | ConvertFrom-Json } catch { $evidence = @{} } }
            # Rows written before tiers existed: an orphan's figure is its measured cost, so it
            # is certain; anything else is treated as indicative until the next run re-detects it.
            $tier = if ($r.Tier) { [string]$r.Tier }
                    elseif ([string]$r.Category -eq 'orphaned') { 'certain' }
                    elseif ([string]$r.Category -eq 'step-up') { 'not-a-saving' }
                    else { 'indicative' }
            $est = [double]$r.EstMonthlySavingsUsd

            $st = $statusById[[string]$r.RowKey]
            $status = if ($st -and $st.Status) { [string]$st.Status } else { 'open' }
            $amountAtStatus = if ($st -and $null -ne $st.AmountAtStatusUsd) { [double]$st.AmountAtStatusUsd } else { $null }
            # A dismissal applies to the finding as it was. If the figure has moved by more than
            # half, this is materially a different finding and it is surfaced again.
            $reopened = $false
            if ($status -eq 'dismissed' -and $null -ne $amountAtStatus -and $amountAtStatus -gt 0 -and
                [Math]::Abs($est - $amountAtStatus) / $amountAtStatus -gt 0.5) {
                $status = 'open'; $reopened = $true
            }

            $item = [PSCustomObject]@{
                id                   = $r.RowKey
                category             = $r.Category
                tier                 = $tier
                resourceId           = $r.ResourceId
                resourceName         = $r.ResourceName
                subscriptionName     = $r.SubscriptionName
                # Owner / cost centre / environment / application / resource group (tags as they are now).
                allocation           = (ConvertFrom-AllocationJson -Row $r)
                resourceType         = $r.ResourceType
                sku                  = $r.Sku
                location             = $r.Location
                title                = $r.Title
                detail               = $r.Detail
                estMonthlySavingsUsd = $est
                confidence           = $r.Confidence
                evidence             = $evidence
                status               = $status
                statusReason         = if ($st) { [string]$st.Reason } else { '' }
                statusBy             = if ($st) { [string]$st.SetBy } else { '' }
                statusAt             = if ($st) { [string]$st.SetAt } else { '' }
                # Set once the money actually stopped (DetectSavings-Timer settles it).
                realisedUsd          = if ($st -and $null -ne $st.RealisedUsd) { [double]$st.RealisedUsd } else { $null }
                realisedAt           = if ($st) { [string]$st.RealisedAt } else { '' }
                reopened             = $reopened
            }

            if ($tier -eq 'not-a-saving') { $increases += $item; continue }
            if ($status -eq 'dismissed' -and -not $includeDismissed) { continue }
            $findings += $item
        }
    } catch { Write-Host "savings findings read failed: $($_.Exception.Message)" }
}

$findings = @($findings | Sort-Object -Property estMonthlySavingsUsd -Descending)
$increases = @($increases | Sort-Object -Property estMonthlySavingsUsd -Descending)

# Totals count OPEN and IN-PROGRESS findings in the two solid tiers. A dismissed or completed
# finding is no longer money on the table, and an indicative one was never a figure to add.
$countable = @($findings | Where-Object { $_.tier -in @('certain', 'likely') -and $_.status -in @('open', 'in-progress') })
$sum = { param($rows) $t = 0.0; foreach ($x in @($rows)) { $t += [double]$x.estMonthlySavingsUsd }; [Math]::Round($t, 2) }

# Realised in the current calendar month (UTC), from the settled status rows.
$monthPrefix = [datetime]::UtcNow.ToString('yyyy-MM')
$realised = 0.0
foreach ($s in $statusById.Values) {
    if (-not (Test-InSubscriptionScope -Scope $subScope -Value $s)) { continue }
    if ($s.RealisedAt -and ([string]$s.RealisedAt).StartsWith($monthPrefix) -and $null -ne $s.RealisedUsd) {
        $realised += [double]$s.RealisedUsd
    }
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        findings               = $findings
        count                  = $findings.Count
        # Sustained cost increases: not savings, shown on the Cost changes page.
        increases              = $increases
        # Certain + likely, open or in progress — what is genuinely still on the table.
        totalMonthlySavingsUsd = (& $sum $countable)
        certainMonthlyUsd      = (& $sum @($countable | Where-Object tier -eq 'certain'))
        likelyMonthlyUsd       = (& $sum @($countable | Where-Object tier -eq 'likely'))
        # Listed, deliberately not added to the total.
        indicativeCount        = @($findings | Where-Object tier -eq 'indicative').Count
        dismissedCount         = @($statusById.Values | Where-Object { [string]$_.Status -eq 'dismissed' }).Count
        realisedThisMonthUsd   = [Math]::Round($realised, 2)
        canSetStatus           = [bool]$caller.IsAdmin
        lastRun                = $latestRunId
    } | ConvertTo-Json -Depth 6)
    Headers    = @{ "Content-Type" = "application/json" }
})
