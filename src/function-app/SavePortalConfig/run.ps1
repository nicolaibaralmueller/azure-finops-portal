using namespace System.Net
param($Request, $TriggerMetadata)

# Update non-secret portal settings (thresholds, windows, cost basis, AI call limit). Admin-only.
# The AI provider KEY is NEVER set here — that goes to Key Vault via
# Setup/Configure-AiProvider.ps1. Any attempt to pass a secret through this endpoint is
# rejected.

$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller -Error 'admin required'); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$body = $Request.Body
if (-not $body) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = '{"error":"body required"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

# Reject any secret-bearing field outright — this endpoint only manages thresholds.
foreach ($k in @('apiKey', 'aiApiKey', 'AI_API_KEY', 'secret', 'key')) {
    if ($body.PSObject.Properties.Name -contains $k) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = '{"error":"secrets are not accepted here — use Setup/Configure-AiProvider.ps1"}'; Headers = @{ "Content-Type" = "application/json" } })
        return
    }
}

# Validate + clamp.
#
# EVERY setting starts as $null and is written only when the caller actually sent it. This is a
# PATCH, not a PUT: the three below used to default to 25 / 50 / 7 and then be written
# unconditionally, so POST {"costType":"ActualCost"} silently reset the detection thresholds and
# dropped BaselineDays to 7 — which shrinks the nightly ingest window, because the cost ingest
# derives it as baselineDays + 2. A caller that never mentioned those fields would have had no
# way to know. Keep the pattern: validate into a $null-initialised variable, add to the entity
# only if non-null, and let the table MERGE preserve the stored value.
$errors = @()
$minDeltaUsd = $null; $minDeltaPct = $null; $baselineDays = $null
if ($null -ne $body.minDeltaUsd)  { if ([double]$body.minDeltaUsd -lt 0) { $errors += 'minDeltaUsd must be >= 0' } else { $minDeltaUsd = [double]$body.minDeltaUsd } }
if ($null -ne $body.minDeltaPct)  { if ([double]$body.minDeltaPct -lt 0) { $errors += 'minDeltaPct must be >= 0' } else { $minDeltaPct = [double]$body.minDeltaPct } }
if ($null -ne $body.baselineDays) { $bd = [int]$body.baselineDays; if ($bd -lt 2 -or $bd -gt 90) { $errors += 'baselineDays must be 2-90' } else { $baselineDays = $bd } }
# How long raw CostSnapshots rows are kept (the cost ingest (CostIngest.psm1) prunes older ones). 0 = keep
# forever. The floor is 160 days — what monthly detection needs for its baseline — and the
# ingest applies it again at prune time, so a stale value here can never delete data a
# detector needs.
# ActualCost (invoice tie-out) vs AmortizedCost (correct basis for trends/anomalies/
# allocation). Changing it makes the next ingest rebuild the 90-day daily-total history so
# the trend chart isn't left with two different definitions of a day's spend.
$costType = $null
if ($null -ne $body.costType) {
    $ct = [string]$body.costType
    if ($ct -notin @('ActualCost', 'AmortizedCost')) { $errors += 'costType must be ActualCost or AmortizedCost' }
    else { $costType = $ct }
}
$snapshotRetentionDays = $null
if ($null -ne $body.snapshotRetentionDays) {
    $rd = [int]$body.snapshotRetentionDays
    # 160 is what monthly detection needs (~4 complete months of baseline). The ingest floors
    # it again at prune time, so a lower value here can't delete the baseline — but rejecting
    # it up front is clearer than silently ignoring what the operator asked for.
    if ($rd -ne 0 -and ($rd -lt 160 -or $rd -gt 3650)) { $errors += 'snapshotRetentionDays must be 0 (never prune) or 160-3650 — monthly detection needs ~4 months of history' }
    else { $snapshotRetentionDays = $rd }
}
# How far back the one-time per-resource backfill reaches. The floor is 35 because that is the
# weekly grain's trailing window; anything less can't unblock detection any sooner than simply
# waiting. The ingest clamps it to the retention window, so it can never fill days the same run
# would prune.
$snapshotBackfillDays = $null
if ($null -ne $body.snapshotBackfillDays) {
    $bd2 = [int]$body.snapshotBackfillDays
    if ($bd2 -ne 0 -and ($bd2 -lt 35 -or $bd2 -gt 400)) { $errors += 'snapshotBackfillDays must be 0 (no backfill) or 35-400' }
    else { $snapshotBackfillDays = $bd2 }
}

# Daily ceiling on AI calls made with the customer's key (AiAdapter.psm1). 0 switches AI off
# entirely — the portal then shows its deterministic text everywhere.
$aiDailyCallLimit = $null
if ($null -ne $body.aiDailyCallLimit) {
    $al = 0
    if (-not [int]::TryParse([string]$body.aiDailyCallLimit, [ref]$al) -or $al -lt 0 -or $al -gt 10000) {
        $errors += 'aiDailyCallLimit must be a whole number from 0 (AI off) to 10000'
    } else { $aiDailyCallLimit = $al }
}

# Which tags say who owns spend (Allocation.psm1): up to 6 keys, as a list or a comma-separated
# string. Matching is loose (case and punctuation ignored), so 'Cost-Center' finds 'costcenter'.
$allocationTagKeys = $null
if ($null -ne $body.allocationTagKeys) {
    $keys = @(@($body.allocationTagKeys) | ForEach-Object { ([string]$_) -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $keys.Count -or $keys.Count -gt 6 -or @($keys | Where-Object { $_ -notmatch '^[A-Za-z0-9 _.:\-]{1,64}$' }).Count) {
        $errors += 'allocationTagKeys must be 1-6 tag names (letters, digits, space, _ . : -)'
    } else { $allocationTagKeys = ($keys | Select-Object -Unique) -join ',' }
}

# Tag VALUE aliases (Allocation.psm1): { "<tag key>": { "<variant>": "<canonical>" } } so that
# 'payments' and 'Team Payments' count as 'team-payments'. Up to 6 keys and 500 pairs; strings
# 1-128 characters. An empty object clears it.
$allocationValueAliases = $null
if ($null -ne $body.allocationValueAliases) {
    $a = $body.allocationValueAliases
    $bad = $false; $pairs = 0; $clean = [ordered]@{}
    if ($a -isnot [System.Management.Automation.PSCustomObject]) { $bad = $true }
    else {
        $keys = @($a.PSObject.Properties)
        if ($keys.Count -gt 6) { $bad = $true }
        foreach ($k in $keys) {
            if ([string]$k.Name -notmatch '^[A-Za-z0-9 _.:\-]{1,64}$' -or $k.Value -isnot [System.Management.Automation.PSCustomObject]) { $bad = $true; break }
            $inner = [ordered]@{}
            foreach ($v in @($k.Value.PSObject.Properties)) {
                $pairs++
                $from = ([string]$v.Name).Trim(); $to = ([string]$v.Value).Trim()
                if ($v.Value -isnot [string] -or $from.Length -lt 1 -or $from.Length -gt 128 -or $to.Length -lt 1 -or $to.Length -gt 128) { $bad = $true; break }
                $inner[$from] = $to
            }
            if ($bad) { break }
            $clean[[string]$k.Name] = $inner
        }
        if ($pairs -gt 500) { $bad = $true }
    }
    if ($bad) { $errors += 'allocationValueAliases must be { "<tag key>": { "<variant>": "<canonical>" } } — up to 6 keys, 500 pairs, strings of 1-128 characters' }
    else { $allocationValueAliases = ($clean | ConvertTo-Json -Compress -Depth 4) }
}

# Per-period detection thresholds.
$periodThresholds = @{}
foreach ($f in @(
    @{ Key = 'weekMinDeltaUsd';  Prop = 'WeekMinDeltaUsd';  Min = 0;   Max = 1000000 }
    @{ Key = 'weekMinDeltaPct';  Prop = 'WeekMinDeltaPct';  Min = 0;   Max = 10000 }
    @{ Key = 'monthMinDeltaUsd'; Prop = 'MonthMinDeltaUsd'; Min = 0;   Max = 1000000 }
    @{ Key = 'monthMinDeltaPct'; Prop = 'MonthMinDeltaPct'; Min = 0;   Max = 10000 }
)) {
    if ($null -ne $body.($f.Key)) {
        $v = [double]$body.($f.Key)
        if ($v -lt $f.Min -or $v -gt $f.Max) { $errors += "$($f.Key) must be between $($f.Min) and $($f.Max)" }
        else { $periodThresholds[$f.Prop] = $v }
    }
}
if ($errors.Count) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = (@{ error = 'validation failed'; details = $errors } | ConvertTo-Json); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

$entity = @{
    PartitionKey = 'settings'; RowKey = 'current'
    UpdatedBy    = $caller.Upn
    UpdatedAt    = ([datetime]::UtcNow.ToString('o'))
}
# MERGE keeps the stored value when a property is absent, so only write a setting when the
# caller actually set it. A partial POST must never disturb a field it didn't mention.
if ($null -ne $minDeltaUsd)  { $entity.MinDeltaUsd  = $minDeltaUsd }
if ($null -ne $minDeltaPct)  { $entity.MinDeltaPct  = $minDeltaPct }
if ($null -ne $baselineDays) { $entity.BaselineDays = $baselineDays }
if ($null -ne $snapshotRetentionDays) { $entity.SnapshotRetentionDays = $snapshotRetentionDays }
if ($null -ne $snapshotBackfillDays) { $entity.SnapshotBackfillDays = $snapshotBackfillDays }
if ($null -ne $costType) { $entity.CostType = $costType }
if ($null -ne $aiDailyCallLimit) { $entity.AiDailyCallLimit = $aiDailyCallLimit }
if ($null -ne $allocationTagKeys) { $entity.AllocationTagKeys = $allocationTagKeys }
if ($null -ne $allocationValueAliases) { $entity.AllocationValueAliases = $allocationValueAliases }
foreach ($k in $periodThresholds.Keys) { $entity[$k] = $periodThresholds[$k] }
Set-TableEntity -Table 'PortalConfig' -Token $token -Entity $entity

# Audit the change. Only the fields the caller actually changed — a null here means "not part
# of this change", which is exactly what the audit trail should record.
Write-AuditEntry -Caller $caller -Action 'SavePortalConfig' -StorageToken $token -Details @{
    minDeltaUsd = $minDeltaUsd; minDeltaPct = $minDeltaPct; baselineDays = $baselineDays
    snapshotRetentionDays = $snapshotRetentionDays; snapshotBackfillDays = $snapshotBackfillDays
    costType = $costType; aiDailyCallLimit = $aiDailyCallLimit; allocationTagKeys = $allocationTagKeys; allocationValueAliases = $allocationValueAliases; periodThresholds = $periodThresholds
}

# Echoes what this request CHANGED, not the full effective config — null means "left alone".
# Call GetPortalConfig for the settings as they now stand.
$result = [PSCustomObject]@{ minDeltaUsd = $minDeltaUsd; minDeltaPct = $minDeltaPct; baselineDays = $baselineDays; snapshotRetentionDays = $snapshotRetentionDays; snapshotBackfillDays = $snapshotBackfillDays; costType = $costType; aiDailyCallLimit = $aiDailyCallLimit; changed = @($entity.Keys | Where-Object { $_ -notin @('PartitionKey', 'RowKey', 'UpdatedBy', 'UpdatedAt') } | Sort-Object); saved = $true }
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 4)
    Headers    = @{ "Content-Type" = "application/json" }
})
