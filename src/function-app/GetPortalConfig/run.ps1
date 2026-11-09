using namespace System.Net
param($Request, $TriggerMetadata)

# Non-secret portal configuration: spike thresholds + baseline window, and the AI provider
# metadata (provider + model — NEVER the key). The key lives only in Key Vault and is never
# returned by any endpoint. Read-only; members allowed.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

# Defaults must match DetectCostSpikes-Timer / the cost ingest (CostIngest.psm1) / CostAnalysis.psm1.
$minDeltaUsd = 25.0; $minDeltaPct = 50.0; $baselineDays = 7; $snapshotRetentionDays = 180
$snapshotBackfillDays = 120
$costType = 'AmortizedCost'
# Per-period detection thresholds. Detection runs weekly + monthly over complete periods;
# a $25 jump is meaningful in a day and noise in a month, so each grain has its own gates.
$weekMinDeltaUsd = 150.0; $weekMinDeltaPct = 25.0
$monthMinDeltaUsd = 500.0; $monthMinDeltaPct = 15.0
$aiDailyCallLimit = $null; $aiUsage = $null
$scopeInfo = [PSCustomObject]@{ all = $true; included = @(); total = $null; pending = $false }
try {
    $token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
    try {
        $aiDailyCallLimit = Get-AiDailyCallLimit -StorageToken $token -NoCache
        $aiUsage = Get-AiUsageToday -StorageToken $token
    } catch { Write-Host "AI usage read failed: $($_.Exception.Message)" }
    # The operator's subscription scope (Setup/Set-SubscriptionScope.ps1), with names from the
    # ingest's 'discovered' list. Read-only here: the portal shows it, it does not edit it.
    try {
        $subScope = Get-SubscriptionScope -Token $token
        $discovered = @()
        $disc = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'subscriptions' and RowKey eq 'discovered'" -Token $token) | Select-Object -First 1
        if ($disc -and $disc.SubscriptionsJson) { try { $discovered = @([string]$disc.SubscriptionsJson | ConvertFrom-Json) } catch { $discovered = @() } }
        $names = @{}; foreach ($d in $discovered) { $names[([string]$d.id).ToLowerInvariant()] = [string]$d.name }
        $pending = (Test-ScopeHashPending -Scope $subScope -Stored (Get-DailyTotalScopeHash -Token $token))
        $scopeInfo = [PSCustomObject]@{
            all      = ($null -eq $subScope.Ids)
            # Only subscriptions the portal's identity saw at the last ingest: one it cannot read has
            # no name and no cost data here, so it is not listed. (Before the first ingest, all of them.)
            included = if ($subScope.Ids) { @($subScope.Ids | Sort-Object | Where-Object { $discovered.Count -eq 0 -or $names.ContainsKey($_) } | ForEach-Object { [PSCustomObject]@{ id = $_; name = if ($names[$_]) { $names[$_] } else { $_ } } }) } else { @() }
            total    = if ($discovered.Count) { $discovered.Count } else { $null }
            pending  = [bool]$pending
        }
    } catch { Write-Host "subscription scope read failed: $($_.Exception.Message)" }
    $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $token) | Select-Object -First 1
    if ($row) {
        if ($null -ne $row.MinDeltaUsd)  { $minDeltaUsd  = [double]$row.MinDeltaUsd }
        if ($null -ne $row.MinDeltaPct)  { $minDeltaPct  = [double]$row.MinDeltaPct }
        if ($null -ne $row.BaselineDays) { $baselineDays = [int]$row.BaselineDays }
        if ($null -ne $row.SnapshotRetentionDays) { $snapshotRetentionDays = [int]$row.SnapshotRetentionDays }
        if ($null -ne $row.SnapshotBackfillDays) { $snapshotBackfillDays = [int]$row.SnapshotBackfillDays }
        if ($row.CostType -in @('ActualCost', 'AmortizedCost')) { $costType = [string]$row.CostType }
        if ($null -ne $row.WeekMinDeltaUsd)  { $weekMinDeltaUsd  = [double]$row.WeekMinDeltaUsd }
        if ($null -ne $row.WeekMinDeltaPct)  { $weekMinDeltaPct  = [double]$row.WeekMinDeltaPct }
        if ($null -ne $row.MonthMinDeltaUsd) { $monthMinDeltaUsd = [double]$row.MonthMinDeltaUsd }
        if ($null -ne $row.MonthMinDeltaPct) { $monthMinDeltaPct = [double]$row.MonthMinDeltaPct }
    }
} catch { Write-Host "PortalConfig read failed, returning defaults: $($_.Exception.Message)" }

$result = [PSCustomObject]@{
    minDeltaUsd  = $minDeltaUsd
    minDeltaPct  = $minDeltaPct
    baselineDays = $baselineDays
    # Days of raw CostSnapshots kept; 0 = never prune. The ingest floors it at what the
    # detectors need, so a low value here can't starve them.
    snapshotRetentionDays = $snapshotRetentionDays
    # How far back the one-time per-resource history fetch reaches, 30 days at a time. Without
    # it CostSnapshots can only grow forwards, and weekly detection needs 35 days while monthly
    # needs two whole calendar months. 0 = don't backfill.
    snapshotBackfillDays  = $snapshotBackfillDays
    # 'AmortizedCost' (default) spreads reservation/savings-plan purchases across their term
    # and attributes them to the resources that consumed them — the right basis for trends,
    # anomalies and allocation. 'ActualCost' shows what was billed on the day, for invoice
    # tie-out. Changing it rebuilds the 90-day daily-total history on the next ingest.
    costType              = $costType
    weekMinDeltaUsd       = $weekMinDeltaUsd
    weekMinDeltaPct       = $weekMinDeltaPct
    monthMinDeltaUsd      = $monthMinDeltaUsd
    monthMinDeltaPct      = $monthMinDeltaPct
    aiProvider   = $env:AI_PROVIDER
    aiModel      = $env:AI_MODEL
    aiConfigured = (Test-AiConfigured)
    # Daily ceiling on AI calls (0 = AI off) and what today (UTC) has used so far.
    aiDailyCallLimit   = $aiDailyCallLimit
    aiCallsToday       = if ($aiUsage) { $aiUsage.Calls } else { $null }
    aiInputTokensToday = if ($aiUsage) { $aiUsage.InputTokens } else { $null }
    aiOutputTokensToday = if ($aiUsage) { $aiUsage.OutputTokens } else { $null }
    canEdit      = [bool]$caller.IsAdmin
    # Which subscriptions the portal covers. all = true means every subscription the identity
    # can see; pending = changed, and the totals are rebuilt on the next nightly run.
    subscriptionScope = $scopeInfo
    # The tags that say who owns spend (normalised; see Allocation.psm1).
    allocationTagKeys = @(Get-AllocationTagKeys -StorageToken $token)
    # Display names for them, from the names as configured ('ServiceLead' -> 'Service lead').
    allocationTagLabels = [PSCustomObject](Get-AllocationTagLabels -StorageToken $token)
    # Tag value aliases as set ({ "<tag key>": { "<variant>": "<canonical>" } }), or null.
    allocationValueAliases = $(try { $s = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $token) | Select-Object -First 1
        if ($s -and $s.AllocationValueAliases) { [string]$s.AllocationValueAliases | ConvertFrom-Json } else { $null } } catch { $null })
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 4)
    Headers    = @{ "Content-Type" = "application/json" }
})
