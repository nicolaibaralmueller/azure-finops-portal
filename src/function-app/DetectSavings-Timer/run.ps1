param($Timer)

Write-Host "=== Savings finder started ==="

# The app's OWN savings conclusions (not Advisor). Runs the deterministic detectors in
# SavingsFinder.psm1 over the ingested cost data (+ Resource Graph + metrics) and writes the
# SavingsFindings table. Each run is tagged with a RunId; GetSavings serves only the latest
# run (so stale findings drop off without deletes).
#
# NO AI here. Each finding already carries a deterministic Detail sentence built from its own
# figures; asking a model to reword it cost a call per finding and said nothing new.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# Detectors read the ingested cost series, so a still-running ingest would silently shrink
# every saving estimate. Bounded wait: this timer starts 35 minutes after the ingest, which
# normally finishes within 20–27, so the 5-minute budget covers a slow night.
$ingest = Wait-ForIngestCompletion -Token $storageToken -MaxWaitMinutes 5
if (-not $ingest.Complete) { Write-Host "Running against a possibly incomplete ingest: $($ingest.Reason)" }

# --- load recent cost snapshots (last ~14 days), ONE DAY AT A TIME ---
# This used to read the whole window in a single `PartitionKey ge` scan and then re-shape it
# through a pipeline, so ~16k rows/day × 15 days were materialised TWICE over before
# Get-ResourceCostMap — which was rewritten to stream precisely so this wouldn't happen — even
# started folding them. Peak memory was the entire window three times over, on a worker that
# runs up to 3 invocations concurrently and shares 3.5 GB with the portal site.
#
# Reading per day fixes two things at once: peak memory becomes one day of rows plus the
# accumulator, and each read is a single-partition query (the indexed path) instead of a
# cross-partition scan. Same window as before: today-14 .. today inclusive.
# A day that fails to read is skipped rather than aborting the run — the detectors already
# tolerate gaps (Find-CostStepUp needs 6 days of the 15, and the orphan/VM detectors treat a
# missing resource as $0 cost), and losing the whole night's savings view to one bad partition
# read would be a worse trade.
# Rows of subscriptions outside the operator's scope are dropped as they are read.
$subScope = Get-SubscriptionScope -Token $storageToken
$costAcc = @{}
$daysRead = 0; $daysFailed = 0
foreach ($offset in 14..0) {
    $dayKey = ([datetime]::UtcNow.Date).AddDays(-$offset).ToString('yyyy-MM-dd')
    try {
        $dayRows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $storageToken)
    } catch {
        Write-Host "  snapshot read failed for ${dayKey}: $($_.Exception.Message)"
        $daysFailed++
        continue
    }
    if ($subScope.Ids) { $dayRows = @(Select-InSubscriptionScope -Scope $subScope -Rows $dayRows) }
    if ($dayRows.Count) { $daysRead++ }
    Add-ResourceCostRows -Accumulator $costAcc -Rows $dayRows -Date $dayKey
}
$costMap = Complete-ResourceCostMap -Accumulator $costAcc
$costAcc = $null
Write-Host "Cost map covers $($costMap.Keys.Count) resource(s) over $daysRead day(s) with data$(if ($daysFailed) { ", $daysFailed day(s) unreadable" })."

$mgmtToken = $null; $subIds = @(); $subNames = @{}
try {
    $mgmtToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
    $subsAll = @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken -StorageToken $storageToken)
    $subIds = @($subsAll | ForEach-Object { $_.Id })
    foreach ($s in $subsAll) { $subNames[$s.Id.ToLower()] = $s.Name }
} catch { Write-Host "mgmt token / subscription discovery failed: $($_.Exception.Message)" }

# --- run detectors (each best-effort); Resource Graph detectors span all subscriptions ---
$findings = @()
try { $findings += Find-CostStepUp -CostMap $costMap } catch { Write-Host "step-up detector failed: $($_.Exception.Message)" }
if ($mgmtToken -and $subIds.Count) {
    try { $findings += Get-OrphanedResources -CostMap $costMap -MgmtToken $mgmtToken -SubscriptionIds $subIds } catch { Write-Host "orphan detector failed: $($_.Exception.Message)" }
    try {
        # Which of the costliest VMs a reservation or savings plan already pays for. Downsizing
        # those saves nothing until the commitment is exchanged, so they must not be priced as
        # if they were pay-as-you-go. One query per subscription, filtered to the candidates.
        $costType = Get-CostTypeSetting -StorageToken $storageToken
        $vmIds = @($costMap.Keys | Where-Object { $_ -match '(?i)/providers/microsoft\.compute/virtualmachines/' })
        $covered = @()
        foreach ($s in $subsAll) {
            $idsHere = @($vmIds | Where-Object { $_ -match "(?i)/subscriptions/$([regex]::Escape($s.Id))/" })
            if (-not $idsHere.Count) { continue }
            $covered += @(Get-CommitmentCoveredResources -SubscriptionId $s.Id -MgmtToken $mgmtToken -ResourceIds $idsHere -CostType $costType)
        }
        if ($covered.Count) { Write-Host "$($covered.Count) VM(s) are covered by a reservation or savings plan — their resize findings are reported without a figure." }

        $findings += Get-LowUtilizationVms -CostMap $costMap -MgmtToken $mgmtToken -SubscriptionIds $subIds `
            -WindowStart ([datetime]::UtcNow.AddDays(-14)) -WindowEnd ([datetime]::UtcNow) -CoveredResourceIds $covered
    } catch { Write-Host "low-utilization detector failed: $($_.Exception.Message)" }

    # Non-production VMs that never stop. Needs the environment tag (Allocation.psm1) of each
    # VM with cost; the key is whichever configured allocation key means "environment".
    try {
        $vmIdsWithCost = @($costMap.Keys | Where-Object { $_ -match '(?i)/providers/microsoft\.compute/virtualmachines/' })
        if ($vmIdsWithCost.Count) {
            $envKey = @(Get-AllocationTagKeys -StorageToken $storageToken | Where-Object { $_ -match 'env|stage' }) | Select-Object -First 1
            if (-not $envKey) { $envKey = 'environment' }
            $vmTags = Get-ResourceTagIndex -MgmtToken $mgmtToken -SubscriptionIds $subIds -ResourceIds $vmIdsWithCost -Aliases (Get-AllocationValueAliases -StorageToken $storageToken)
            $findings += Get-NonProdAlwaysOnVms -CostMap $costMap -MgmtToken $mgmtToken -SubscriptionIds $subIds -TagIndex $vmTags -EnvironmentKey $envKey -CoveredResourceIds $covered
        }
    } catch { Write-Host "non-production schedule detector failed: $($_.Exception.Message)" }

    try { $findings += Get-HotStorageCandidates -CostMap $costMap -MgmtToken $mgmtToken -SubscriptionIds $subIds }
    catch { Write-Host "storage tier detector failed: $($_.Exception.Message)" }

    try { $findings += Get-LogAnalyticsTierFindings -MgmtToken $mgmtToken -SubscriptionIds $subIds }
    catch { Write-Host "Log Analytics tier detector failed: $($_.Exception.Message)" }

    # Reservations and savings plans: hours paid for and never used. Asked at the tenant cost
    # scope (a management group containing every included subscription) when there is one,
    # otherwise per subscription.
    try {
        $resolvedScope = Get-ResolvedCostScope -StorageToken $storageToken
        $isMg = ([string]$resolvedScope.Scope -match '(?i)managementGroups/')
        $unusedScopes = if ($isMg) { @([string]$resolvedScope.Scope) } else { @($subIds | ForEach-Object { "/subscriptions/$_" }) }
        $filterIds = if ($isMg -and ($subScope.Ids -or $resolvedScope.Extra -ne 0)) { @($subIds) } else { @() }
        $unused = Get-UnusedCommitmentCost -MgmtToken $mgmtToken -Scopes $unusedScopes -SubscriptionIds $filterIds
        foreach ($n in @($unused.Notes)) { Write-Host "  $n" }
        $findings += ConvertTo-UnusedCommitmentFindings -Unused $unused
    } catch { Write-Host "unused-commitment detector failed: $($_.Exception.Message)" }
} else {
    Write-Host "No management token / subscriptions — running cost-series detectors only."
}
# One saving per resource in the totals (e.g. an idle non-production VM: resize OR stop at night).
$findings = @(Resolve-OverlappingSavings -Findings $findings)
Write-Host "Found $($findings.Count) savings finding(s)."

# --- resolve display names once for all findings (best-effort) ---
$nameMap = @{}
if ($mgmtToken -and $findings.Count) {
    $nameMap = Resolve-ResourceDisplayNames -ResourceIds @($findings | ForEach-Object { $_.ResourceId }) -MgmtToken $mgmtToken
}
# Who owns each finding (Allocation.psm1): the allocation tags of the resource, or of its group.
$allocKeys = @(Get-AllocationTagKeys -StorageToken $storageToken)
$tagIndex = @{}
if ($mgmtToken -and $findings.Count -and $subIds.Count) {
    $tagIndex = Get-ResourceTagIndex -MgmtToken $mgmtToken -SubscriptionIds $subIds -ResourceIds @($findings | ForEach-Object { $_.ResourceId }) -Aliases (Get-AllocationValueAliases -StorageToken $storageToken)
}

# --- persist, tagged with this run ---
$runId = [datetime]::UtcNow.ToString('o')

# Collected and written in one batched pass (see Set-TableEntityBatch) instead of a REST
# round-trip per finding.
$findingEntities = @()
foreach ($f in $findings) {
    $rowKey = (Get-ShortHash -Value "$($f.Category)|$($f.ResourceId)")

    # Sorted so the stored JSON is stable run to run.
    $evidence = [ordered]@{}
    foreach ($k in @($f.Evidence.Keys | Sort-Object)) { $evidence[[string]$k] = $f.Evidence[$k] }

    $findingEntities += @{
        PartitionKey         = 'savings'
        RowKey               = $rowKey
        RunId                = $runId
        Category             = $f.Category
        ResourceId           = $f.ResourceId
        ResourceName         = if ($nameMap[([string]$f.ResourceId).ToLower()]) { [string]$nameMap[([string]$f.ResourceId).ToLower()] } elseif ($f.Evidence -and $f.Evidence.resourceName) { [string]$f.Evidence.resourceName } else { '' }
        SubscriptionName     = if ([string]$f.ResourceId -match '(?i)/subscriptions/([0-9a-f-]{36})') { [string]$subNames[$Matches[1].ToLower()] } else { '' }
        # '' (not omitted) when unknown: a MERGE would keep a stale owner otherwise.
        AllocationJson       = if ([string]$f.ResourceId -match '(?i)/providers/') { ConvertTo-AllocationJson (Get-ResourceAllocation -Index $tagIndex -ResourceId $f.ResourceId -TagKeys $allocKeys) } else { '' }
        ResourceType         = $f.ResourceType
        Sku                  = $f.Sku
        Location             = $f.Location
        Title                = $f.Title
        Detail               = $f.Detail
        # Cleared rather than omitted: a MERGE keeps an omitted property, so the old AI
        # rewording would otherwise linger on every row that had one.
        Narrative            = ''
        Grounded             = $true
        EstMonthlySavingsUsd = $f.EstMonthlySavingsUsd
        Confidence           = $f.Confidence
        # What the figure is worth: 'certain' (measured waste), 'likely' (a priced change),
        # 'indicative' (shown but never totalled), 'not-a-saving' (a cost increase, reported on
        # Cost changes). Only certain + likely are added up anywhere.
        Tier                 = if ($f.Tier) { [string]$f.Tier } else { 'indicative' }
        Evidence             = ($evidence | ConvertTo-Json -Compress)
        DetectedAt           = $runId
    }
}
Set-TableEntityBatch -Table 'SavingsFindings' -Entities $findingEntities -Token $storageToken

# --- mark this run as the latest (GetSavings filters to it) ---
Set-TableEntity -Table 'SavingsFindings' -Token $storageToken -Entity @{
    PartitionKey = 'savings-meta'; RowKey = 'latest'; LatestRunId = $runId; At = $runId; FindingCount = $findings.Count
}

# ============================================================================
# Settle what was actually saved
# ============================================================================
# A finding an admin marked 'done' is a claim; this is where it becomes a fact. The claim is
# settled only when the money really stopped: the finding is gone from tonight's run (the disk
# was deleted, the VM no longer qualifies) or its figure has fallen by at least half (it was
# resized to something smaller than we suggested, or partly shut down).
#
# The realised amount is the figure AS IT STOOD when the admin marked it done, not tonight's —
# the whole point is that tonight's is lower. It is written once; RealisedAt never moves, so
# "realised this month" is a stable historical number rather than something that re-counts
# itself every night.
$current = @{}
foreach ($e in $findingEntities) { $current[[string]$e.RowKey] = [double]$e.EstMonthlySavingsUsd }

$settled = 0
try {
    foreach ($s in @(Get-TableEntities -Table 'SavingsStatus' -Filter "PartitionKey eq 'status'" -Token $storageToken)) {
        if ([string]$s.Status -ne 'done' -or $s.RealisedAt) { continue }
        $key = [string]$s.RowKey
        $was = [double]$s.AmountAtStatusUsd
        if ($was -le 0) { continue }
        $now = if ($current.ContainsKey($key)) { $current[$key] } else { 0.0 }
        if ($now -gt ($was * 0.5)) { continue }   # still costing what it did — not done yet
        Set-TableEntity -Table 'SavingsStatus' -Token $storageToken -Entity @{
            PartitionKey = 'status'; RowKey = $key
            RealisedUsd  = [Math]::Round($was, 2)
            RealisedAt   = ([datetime]::UtcNow.ToString('o'))
            # Kept for the audit trail: what it still costs at the moment we settled it.
            AmountWhenRealisedUsd = [Math]::Round($now, 2)
        }
        $settled++
    }
} catch { Write-Host "savings status settlement failed: $($_.Exception.Message)" }
if ($settled) { Write-Host "Settled $settled saving(s) as realised." }

$tiers = @($findingEntities | Group-Object -Property { [string]$_.Tier } | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
Write-Host "=== Savings finder finished: $($findings.Count) finding(s) for run $runId ($tiers) ==="
