param($Timer)

Write-Host "=== Advisor / rightsizing sync started ==="

# Pull Azure Advisor COST recommendations and cache them for GetRecommendations. Everything
# shown comes from Advisor itself (impact, estimated savings, SKUs, problem/solution text).
#
# NO AI here. This used to ask the model to reword Advisor's solution sentence, which cost a
# call per recommendation and added nothing — the rewording said what Advisor already said.
#
# CURRENCY: Advisor reports savings in the BILLING currency (extendedProperties.savingsCurrency),
# NOT in USD. The native amount is kept as-is and converted to USD here (Fx.psm1) so it can be
# ranked and summed alongside the app's own USD findings. When no rate is available the row is
# stored UNCONVERTED and excluded from USD totals — never relabelled as USD.
#
# Each run is tagged with a RunId and 'advisor-meta'/'latest' points at it, so recommendations
# Advisor has stopped returning drop out of the portal instead of inflating the savings total.

$mgmtToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# Rate table for the native -> USD conversion (cached; shared with GetFxRates).
$fx = Get-FxRates -StorageToken $storageToken

# Advisor omits `savingsCurrency` on some recommendation types. Reading that as USD is only
# correct on a USD-billed tenant — anywhere else it inflates the converted figure by the whole
# exchange rate. the cost ingest (CostIngest.psm1) records the tenant's actual billing currency; use it as
# the fallback basis, and if it isn't known, decline to convert rather than assume.
$assumeCurrency = ''
try {
    $ingestMarker = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'ingest' and RowKey eq 'lastrun'" -Token $storageToken) | Select-Object -First 1
    if ($ingestMarker) { $assumeCurrency = [string]$ingestMarker.BillingCurrency }
} catch { Write-Host "billing-currency lookup failed: $($_.Exception.Message)" }
if ($assumeCurrency) { Write-Host "Currency fallback for Advisor amounts with none stated: $assumeCurrency" }
else { Write-Host "No known billing currency — Advisor amounts with no stated currency will be excluded from USD totals." }
if (-not $fx.Rates) { Write-Host "No FX rates available — non-USD Advisor savings will be stored unconverted and left out of totals." }

# --- fetch cost recommendations across ALL accessible subscriptions (each best-effort) ---
$subs = @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken -StorageToken $storageToken)
if (-not $subs.Count) {
    Write-Host "No accessible subscriptions — grant the identity Reader at a management group (Assign-AzureRbac.ps1 -ManagementGroupId)."
    Write-Host "=== Advisor sync finished (no subscriptions) ==="
    return
}
$subNames = @{}
foreach ($s in $subs) { $subNames[$s.Id.ToLower()] = $s.Name }
$recs = @()
foreach ($sub in $subs) {
    $uri = "https://management.azure.com/subscriptions/$($sub.Id)/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01&`$filter=$([uri]::EscapeDataString("Category eq 'Cost'"))"
    try {
        do {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $mgmtToken" }
            if ($resp.value) { $recs += $resp.value }
            $uri = $resp.nextLink
        } while ($uri)
    } catch { Write-Host "  [$($sub.Name)] Advisor query failed: $($_.Exception.Message)" }
}
Write-Host "Advisor returned $($recs.Count) cost recommendation(s) across $($subs.Count) subscription(s)."

# Batch-resolve display names for every recommended resource so the portal shows names,
# not GUIDs. Billing-scope recommendations (savings plans / RIs) carry a bare GUID that has
# no resource behind it — those stay unresolved and the UI labels them by recommendation type.
$nameMap = @{}
if ($recs.Count) {
    $allIds = @($recs | ForEach-Object { [string]$_.properties.resourceMetadata.resourceId })
    $nameMap = Resolve-ResourceDisplayNames -ResourceIds $allIds -MgmtToken $mgmtToken
}

# Who owns each recommended resource (Allocation.psm1).
$allocKeys = @(Get-AllocationTagKeys -StorageToken $storageToken)
$tagIndex = @{}
if ($recs.Count) {
    $tagIndex = Get-ResourceTagIndex -MgmtToken $mgmtToken -SubscriptionIds @($subs | ForEach-Object { $_.Id }) -ResourceIds @($recs | ForEach-Object { [string]$_.properties.resourceMetadata.resourceId }) -Aliases (Get-AllocationValueAliases -StorageToken $storageToken)
}

$runId = [datetime]::UtcNow.ToString('o')
# Collected and written in one batched pass instead of a REST round-trip per recommendation.
$recEntities = @()

foreach ($rec in $recs) {
    $p = $rec.properties
    $ext = $p.extendedProperties
    $resourceId = [string]$p.resourceMetadata.resourceId
    $problem  = [string]$p.shortDescription.problem
    $solution = [string]$p.shortDescription.solution
    $impact   = [string]$p.impact

    # Savings + SKUs live in extendedProperties; field names vary by recommendation type.
    # $native is in $currency (the BILLING currency), NOT necessarily USD.
    $native = 0.0; $currency = ''
    $recType = ''; $currentSku = ''; $targetSku = ''; $region = ''
    if ($ext) {
        $currency = [string]$ext.savingsCurrency
        if ($ext.annualSavingsAmount) {
            [double]::TryParse([string]$ext.annualSavingsAmount, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$native) | Out-Null
            $native = $native / 12
        } elseif ($ext.savingsAmount) {
            [double]::TryParse([string]$ext.savingsAmount, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$native) | Out-Null
        }
        $recType    = [string]$ext.recommendationType
        $currentSku = [string]$ext.currentSku
        $targetSku  = if ($ext.targetSku) { [string]$ext.targetSku } elseif ($ext.recommendedSku) { [string]$ext.recommendedSku } else { '' }
        $region     = [string]$ext.region
    }

    # Native -> USD. $null means "no rate for this currency": store it unconverted and let
    # GetRecommendations leave it out of the USD total rather than mislabel it.
    $usd = ConvertTo-Usd -Amount $native -Currency $currency -Rates $fx.Rates -AssumeCurrency $assumeCurrency
    $converted = ($null -ne $usd)
    $estUsd = if ($converted) { [Math]::Round([double]$usd, 2) } else { 0.0 }
    $nativeRounded = [Math]::Round($native, 2)
    $displayCurrency = if ([string]::IsNullOrWhiteSpace($currency)) { 'USD' } else { $currency.ToUpper() }

    $rowKey = (Get-ShortHash -Value ([string]$rec.id))

    $recEntities += @{
        PartitionKey         = 'cost'
        RowKey               = $rowKey
        RunId                = $runId
        ResourceId           = $resourceId
        ResourceName         = [string]$nameMap[$resourceId.ToLower()]
        SubscriptionName     = if ($resourceId -match '(?i)/subscriptions/([0-9a-f-]{36})') { [string]$subNames[$Matches[1].ToLower()] } else { '' }
        AllocationJson       = if ($resourceId -match '(?i)/providers/') { ConvertTo-AllocationJson (Get-ResourceAllocation -Index $tagIndex -ResourceId $resourceId -TagKeys $allocKeys) } else { '' }
        Impact               = $impact
        Problem              = $problem
        Solution             = $solution
        RecommendationType   = $recType
        CurrentSku           = $currentSku
        TargetSku            = $targetSku
        Region               = $region
        # Reservation / savings-plan purchases come as alternatives of the same purchase; these
        # tell them apart (Get-BriefSavings counts only the best of each).
        Term                 = if ($ext) { [string]$ext.term } else { '' }
        LookbackPeriod       = if ($ext) { [string]$ext.lookbackPeriod } else { '' }
        ReservedResourceType = if ($ext) { [string]$ext.reservedResourceType } else { '' }
        PurchaseScope        = if ($ext) { [string]$ext.scope } else { '' }
        # Advisor's own figure, in its own currency — the authoritative number.
        SavingsAmount        = $nativeRounded
        Currency             = $displayCurrency
        # The USD equivalent, valid only when SavingsConverted is true.
        EstMonthlySavingsUsd = $estUsd
        SavingsConverted     = $converted
        # Cleared rather than omitted: a MERGE leaves an omitted property as it was, so the old
        # AI rewording would otherwise stay on every row that had one.
        Narrative            = ''
        Grounded             = $true
        SyncedAt             = ([datetime]::UtcNow.ToString('o'))
    }
}
Set-TableEntityBatch -Table 'Recommendations' -Entities $recEntities -Token $storageToken

# Point GetRecommendations at this run. Rows Advisor stopped returning keep their old RunId
# and are filtered out — no deletes needed (same pattern as SavingsFindings).
Set-TableEntity -Table 'Recommendations' -Token $storageToken -Entity @{
    PartitionKey = 'advisor-meta'; RowKey = 'latest'; LatestRunId = $runId; At = $runId; RecommendationCount = $recs.Count
}

Write-Host "=== Advisor sync finished: $($recs.Count) recommendation(s) upserted for run $runId ==="
