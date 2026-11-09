param($Timer)

Write-Host "=== Commitments sync started ==="

# Reservations and savings plans for the Savings page (Commitments.psm1):
#   - every reservation / savings plan with its 7- and 30-day utilisation and expiry (needs the
#     optional Reservations Reader / Savings plan Reader roles at tenant scope);
#   - Azure's purchase recommendations for the costliest included subscriptions, with the
#     effective cost of the committed usage as a share of pay-as-you-go.
# The money a commitment wastes (unused hours) is a savings FINDING and is written by
# DetectSavings-Timer; this timer is the context around it. Runs at 02:50 UTC.
# Stored in CostSummary 'commitments'/'current', and per commitment the resources using it in
# CostSummary 'commitment-usage'/<hash of the benefit id> (Reservations page, GetReservations).

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$mgmtToken    = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
$subScope = Get-SubscriptionScope -Token $storageToken
$subs = @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken -StorageToken $storageToken)
$subNames = @{}; foreach ($s in $subs) { $subNames[([string]$s.Id).ToLowerInvariant()] = [string]$s.Name }

$inventory = Get-CommitmentInventory -MgmtToken $mgmtToken
Write-Host "Commitments: $(@($inventory.Items).Count) reservation(s) / savings plan(s) visible."

# Recommendations are per subscription; ask for the 20 costliest (last complete month, from the
# stored monthly history) so a tenant with hundreds of subscriptions stays bounded.
$byCost = @{}
try {
    foreach ($r in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthly-sub'" -Token $storageToken)) {
        $sid = ([string]$r.SubscriptionId).ToLowerInvariant()
        if (-not $subNames.ContainsKey($sid)) { continue }
        if (-not $byCost.ContainsKey($sid) -or [string]$r.Month -gt $byCost[$sid].Month) { $byCost[$sid] = @{ Month = [string]$r.Month; Usd = [double]$r.CostUsd } }
    }
} catch { Write-Host "monthly history read failed (recommendations use the first 20 subscriptions): $($_.Exception.Message)" }
$targets = @($subNames.Keys | Sort-Object { if ($byCost[$_]) { -[double]$byCost[$_].Usd } else { 0 } } | Select-Object -First 20)
$recs = Get-CommitmentRecommendations -MgmtToken $mgmtToken -SubscriptionIds $targets -SubscriptionNames $subNames
Write-Host "Purchase recommendations: $(@($recs.Items).Count) across $($targets.Count) subscription(s)."

# Which resources use each commitment (Reservations page), last 30 days of amortized cost. Asked
# at the tenant cost scope when a management group holds every included subscription, otherwise
# per subscription (as DetectSavings-Timer does for unused hours). The management group is not
# filtered to the included subscriptions here: a shared reservation used outside the scope still
# counts, and GetReservations keeps those resources out of the list.
$usage = [PSCustomObject]@{ Items = @(); Notes = @() }
$perSubscription = $false
try {
    $resolvedScope = Get-ResolvedCostScope -StorageToken $storageToken
    $isMg = ([string]$resolvedScope.Scope -match '(?i)managementGroups/')
    $perSubscription = -not $isMg
    $usageScopes = if ($isMg) { @([string]$resolvedScope.Scope) } else { @($subNames.Keys | ForEach-Object { "/subscriptions/$_" }) }
    $usage = Get-CommitmentConsumption -MgmtToken $mgmtToken -Scopes $usageScopes
    Write-Host "Commitment usage: $(@($usage.Items).Count) commitment(s) with usage or unused hours across $($usageScopes.Count) scope(s)."
} catch { Write-Host "commitment usage failed: $($_.Exception.Message)" }

$keep = @{}
foreach ($u in @($usage.Items)) {
    $rk = Get-ShortHash -Value ([string]$u.id)
    $keep[$rk] = $true
    # A table string property holds 32K characters: keep the largest consumers that fit.
    $take = [Math]::Min(100, @($u.resources).Count)
    do {
        $resJson = (@($u.resources | Select-Object -First $take) | ConvertTo-Json -Depth 4 -Compress -AsArray)
        $take = [int]($take * 0.8)
    } while ($resJson.Length -gt 30000 -and $take -gt 0)
    Set-TableEntity -Table 'CostSummary' -Token $storageToken -Entity @{
        PartitionKey = 'commitment-usage'; RowKey = $rk
        BenefitId = [string]$u.id; Name = [string]$u.name; Kind = [string]$u.kind
        Used30dUsd = [double]$u.used30dUsd; Used7dUsd = [double]$u.used7dUsd
        Unused30dUsd = [double]$u.unused30dUsd; Unused7dUsd = [double]$u.unused7dUsd; UnusedKnown = [bool]$u.unusedKnown
        LastUsed = [string]$u.lastUsed; ResourceCount = [int]$u.resourceCount; Days = [int]$u.days
        ResourcesJson = $resJson
        PerSubscription = $perSubscription
        SyncedAt = ([datetime]::UtcNow.ToString('o'))
    }
}
# Commitments that no longer show up (expired, exchanged) leave the page.
try {
    $stale = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'commitment-usage'" -Select 'PartitionKey,RowKey' -Token $storageToken |
        Where-Object { -not $keep.ContainsKey([string]$_.RowKey) })
    if ($stale.Count -and @($usage.Items).Count) { Remove-TableEntityBatch -Table 'CostSummary' -Entities $stale -Token $storageToken }
} catch { Write-Host "stale commitment-usage cleanup failed: $($_.Exception.Message)" }

$notes = @(@($inventory.Notes) + @($usage.Notes | Select-Object -First 3) + @($recs.Notes | Select-Object -First 5))
Set-TableEntity -Table 'CostSummary' -Token $storageToken -Entity @{
    PartitionKey = 'commitments'; RowKey = 'current'
    InventoryJson = (@($inventory.Items | Select-Object -First 100) | ConvertTo-Json -Depth 5 -Compress -AsArray)
    RecommendationsJson = (@($recs.Items | Select-Object -First 50) | ConvertTo-Json -Depth 5 -Compress -AsArray)
    NotesJson = (@($notes) | ConvertTo-Json -Compress -AsArray)
    InventoryCount = @($inventory.Items).Count
    RecommendationCount = @($recs.Items).Count
    ScopeHash = $subScope.Hash
    SyncedAt = ([datetime]::UtcNow.ToString('o'))
}
foreach ($n in $notes) { Write-Host "  note: $n" }
Write-Host "=== Commitments sync finished ==="
