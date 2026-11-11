using namespace System.Net
param($Request, $TriggerMetadata)

# Reservations and savings plans for the Savings page: each one's utilisation and expiry, and
# Azure's purchase recommendations (SyncCommitments-Timer). Unused commitment cost is a savings
# finding and comes from GetSavings. Served from storage; read-only; members allowed.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$row = $null
try { $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'commitments' and RowKey eq 'current'" -Token $token) | Select-Object -First 1 }
catch { Write-Host "commitments read failed: $($_.Exception.Message)" }

function Read-JsonList { param($Value) if (-not $Value) { return @() } try { return @([string]$Value | ConvertFrom-Json) } catch { return @() } }
$subScope = Get-SubscriptionScope -Token $token
$recs = @(Read-JsonList $row.RecommendationsJson | Where-Object { Test-InSubscriptionScope -Scope $subScope -Value ([string]$_.subscriptionId) })

# Names: the inventory's displayName, else the billing data's name (CostSummary
# 'commitment-usage'), else "Reservation 1a2b3c4d" — never a bare GUID.
$usageNames = @{}
try {
    foreach ($u in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'commitment-usage'" -Select 'BenefitId,Name' -Token $token)) {
        if ($u.BenefitId -and $u.Name) { $usageNames[([string]$u.BenefitId).ToLowerInvariant()] = [string]$u.Name }
    }
} catch { Write-Host "commitment usage names read failed: $($_.Exception.Message)" }
$inventory = @(Read-JsonList $row.InventoryJson | Where-Object { -not $_.status -or $_.status -eq 'active' } | ForEach-Object {
    $id = ([string]$_.id).ToLowerInvariant()
    $_ | Add-Member -NotePropertyName name -NotePropertyValue (Get-CommitmentDisplayName -Candidates @([string]$_.name, [string]$usageNames[$id]) -Id $id -Kind ([string]$_.kind)) -Force -PassThru
})

$result = [PSCustomObject]@{
    ready           = ($null -ne $row)
    # Active ones only here; the Reservations page lists cancelled and expired ones too.
    inventory       = $inventory
    recommendations = $recs
    notes           = @(Read-JsonList $row.NotesJson)
    lastSynced      = if ($row) { [string]$row.SyncedAt } else { $null }
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 6)
    Headers    = @{ "Content-Type" = "application/json" }
})
