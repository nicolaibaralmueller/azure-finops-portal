using namespace System.Net
param($Request, $TriggerMetadata)

# Reservations and savings plans for the Reservations page: each one from the inventory
# (utilisation, expiry, renewal — CostSummary 'commitments'/'current') joined with the resources
# that used it over the last 30 days and its unused cost (CostSummary 'commitment-usage', both
# written by SyncCommitments-Timer). Resources in subscriptions outside the portal's scope are
# not listed; their share is summed as otherSubscriptions so the percentages still add up.
# Served from storage; read-only; members allowed.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
function Read-JsonList { param($Value) if (-not $Value) { return @() } try { return @([string]$Value | ConvertFrom-Json) } catch { return @() } }

$row = $null; $usageRows = @()
try { $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'commitments' and RowKey eq 'current'" -Token $token) | Select-Object -First 1 }
catch { Write-Host "commitments read failed: $($_.Exception.Message)" }
try { $usageRows = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'commitment-usage'" -Token $token) }
catch { Write-Host "commitment usage read failed: $($_.Exception.Message)" }

$subScope = Get-SubscriptionScope -Token $token
$subNames = @{}
foreach ($s in @(Get-QuerySubscriptions -Token $token -Scope $subScope)) { $subNames[([string]$s.Id).ToLowerInvariant()] = [string]$s.Name }

$usageById = @{}
foreach ($u in $usageRows) { if ($u.BenefitId) { $usageById[([string]$u.BenefitId).ToLowerInvariant()] = $u } }

function Join-Commitment {
    param($Inv, $Usage)
    $listed = @(); $other = @{ count = 0; cost30dUsd = 0.0; sharePct = 0.0 }
    foreach ($r in @(Read-JsonList $Usage.ResourcesJson)) {
        if ($r.subscriptionId -and -not (Test-InSubscriptionScope -Scope $subScope -Value ([string]$r.subscriptionId))) {
            $other.count++; $other.cost30dUsd += [double]$r.cost30dUsd; $other.sharePct += [double]$r.sharePct
            continue
        }
        $r | Add-Member -NotePropertyName subscriptionName -NotePropertyValue ($subNames[[string]$r.subscriptionId] ?? '') -Force
        $listed += $r
    }
    $id = if ($Inv) { [string]$Inv.id } else { ([string]$Usage.BenefitId).ToLowerInvariant() }
    $name = if ($Inv -and $Inv.name) { [string]$Inv.name } elseif ($Usage -and $Usage.Name) { [string]$Usage.Name } else { ($id -split '/')[-1] }
    [PSCustomObject]@{
        id = $id; name = $name
        kind = if ($Inv) { [string]$Inv.kind } elseif ($Usage) { [string]$Usage.Kind } else { 'commitment' }
        inInventory = ($null -ne $Inv)
        # active | cancelled | expired; 'unknown' = seen only in cost data (no Reservations Reader
        # role, or it is no longer listed).
        status = if ($Inv) { if ($Inv.status) { [string]$Inv.status } else { 'active' } } else { 'unknown' }
        sku = [string]$Inv.sku; location = [string]$Inv.location; quantity = $Inv.quantity; commitment = $Inv.commitment
        term = [string]$Inv.term; appliedScope = [string]$Inv.appliedScope; renew = $Inv.renew
        expiryDate = $Inv.expiryDate; daysToExpiry = $Inv.daysToExpiry; expiringSoon = [bool]$Inv.expiringSoon
        utilisation7d = $Inv.utilisation7d; utilisation30d = $Inv.utilisation30d
        hasUsageData = ($null -ne $Usage)
        used30dUsd = if ($Usage) { [double]$Usage.Used30dUsd } else { $null }
        used7dUsd = if ($Usage) { [double]$Usage.Used7dUsd } else { $null }
        unused30dUsd = if ($Usage -and [bool]$Usage.UnusedKnown) { [double]$Usage.Unused30dUsd } else { $null }
        unused7dUsd = if ($Usage -and [bool]$Usage.UnusedKnown) { [double]$Usage.Unused7dUsd } else { $null }
        lastUsed = if ($Usage) { [string]$Usage.LastUsed } else { $null }
        resourceCount = if ($Usage) { [int]$Usage.ResourceCount } else { 0 }
        resources = @($listed)
        otherSubscriptions = if ($other.count) { [PSCustomObject]@{ count = $other.count; cost30dUsd = [Math]::Round($other.cost30dUsd, 2); sharePct = [Math]::Round($other.sharePct, 1) } } else { $null }
    }
}

$items = @()
$seen = @{}
foreach ($inv in @(Read-JsonList $row.InventoryJson)) {
    $id = ([string]$inv.id).ToLowerInvariant()
    $seen[$id] = $true
    $items += Join-Commitment -Inv $inv -Usage $usageById[$id]
}
# Commitments seen in cost data but not in the inventory (no Reservations Reader role, or the
# commitment ended in the last 30 days).
foreach ($k in $usageById.Keys) { if (-not $seen.ContainsKey($k)) { $items += Join-Commitment -Inv $null -Usage $usageById[$k] } }

$perSubscription = [bool](@($usageRows | Where-Object { [bool]$_.PerSubscription }).Count)
$usageSynced = @($usageRows | ForEach-Object { [string]$_.SyncedAt } | Sort-Object -Descending | Select-Object -First 1)
$result = [PSCustomObject]@{
    ready           = ($null -ne $row -or $usageRows.Count -gt 0)
    items           = @($items)
    perSubscription = $perSubscription
    days            = 30
    notes           = @(Read-JsonList $row.NotesJson)
    lastSynced      = if ($row) { [string]$row.SyncedAt } elseif ($usageSynced.Count) { $usageSynced[0] } else { $null }
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 8)
    Headers    = @{ "Content-Type" = "application/json" }
})
