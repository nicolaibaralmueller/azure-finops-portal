using namespace System.Net
param($Request, $TriggerMetadata)

# Rightsizing / savings recommendations: Azure Advisor cost findings, each with a
# plain-English narrative and an estimated monthly saving. Cached by SyncAdvisor-Timer.
# Read-only; members allowed.
#
# Only the latest sync run is served, so recommendations Advisor has stopped returning stop
# inflating the total. Advisor reports in the BILLING currency: savingsAmount/currency are
# the authoritative figures, estMonthlySavingsUsd is the converted equivalent and is only
# meaningful when converted=true. The USD total sums converted rows ONLY — a EUR amount is
# never added to a USD one.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$rows = @()
try {
    $rows = @(Get-TableEntities -Table 'Recommendations' -Filter "PartitionKey eq 'cost'" -Token $token)
} catch {
    Write-Host "Recommendations read failed: $($_.Exception.Message)"
}

# Which run is current? (No meta row = rows predate run tagging; serve them all.)
$latestRunId = $null
try {
    $meta = @(Get-TableEntities -Table 'Recommendations' -Filter "PartitionKey eq 'advisor-meta' and RowKey eq 'latest'" -Token $token) | Select-Object -First 1
    if ($meta) { $latestRunId = [string]$meta.LatestRunId }
} catch { Write-Host "advisor meta read failed: $($_.Exception.Message)" }
if ($latestRunId) { $rows = @($rows | Where-Object { [string]$_.RunId -eq $latestRunId }) }
# Recommendations of subscriptions outside the operator's scope are hidden.
$rows = @(Select-InSubscriptionScope -Scope (Get-SubscriptionScope -Token $token) -Rows $rows)

$unconverted = 0
$recs = foreach ($r in $rows) {
    # Rows written before the currency fix have no SavingsConverted flag; their
    # EstMonthlySavingsUsd may be a native-currency amount, so treat them as unconverted
    # rather than trusting the old value.
    $converted = if ($null -ne $r.SavingsConverted) { [bool]$r.SavingsConverted } else { [string]$r.Currency -in @('', 'USD') }
    if (-not $converted) { $unconverted++ }
    [PSCustomObject]@{
        id                   = $r.RowKey
        resourceId           = $r.ResourceId
        resourceName         = $r.ResourceName
        subscriptionName     = $r.SubscriptionName
        allocation           = (ConvertFrom-AllocationJson -Row $r)
        impact               = $r.Impact
        problem              = $r.Problem
        solution             = $r.Solution
        recommendationType   = $r.RecommendationType
        currentSku           = $r.CurrentSku
        targetSku            = $r.TargetSku
        region               = $r.Region
        # Advisor's own number, in its own currency.
        savingsAmount        = if ($null -ne $r.SavingsAmount) { [double]$r.SavingsAmount } else { [double]$r.EstMonthlySavingsUsd }
        currency             = if ($r.Currency) { [string]$r.Currency } else { 'USD' }
        # Comparable USD figure — only when converted is true.
        estMonthlySavingsUsd = if ($converted) { [double]$r.EstMonthlySavingsUsd } else { 0.0 }
        converted            = $converted
        narrative            = $r.Narrative
        grounded             = if ($null -ne $r.Grounded) { [bool]$r.Grounded } else { $true }
    }
}
$recs = @($recs | Sort-Object -Property estMonthlySavingsUsd -Descending)
$total = 0.0; foreach ($r in $recs) { if ($r.converted) { $total += [double]$r.estMonthlySavingsUsd } }

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        recommendations        = $recs
        count                  = $recs.Count
        totalMonthlySavingsUsd = [Math]::Round($total, 2)
        # >0 means the total excludes some findings (no FX rate for their billing currency).
        unconvertedCount       = $unconverted
        lastRun                = $latestRunId
    } | ConvertTo-Json -Depth 6)
    Headers    = @{ "Content-Type" = "application/json" }
})
