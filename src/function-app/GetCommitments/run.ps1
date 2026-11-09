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

$result = [PSCustomObject]@{
    ready           = ($null -ne $row)
    # Active ones only here; the Reservations page lists cancelled and expired ones too.
    inventory       = @(Read-JsonList $row.InventoryJson | Where-Object { -not $_.status -or $_.status -eq 'active' })
    recommendations = $recs
    notes           = @(Read-JsonList $row.NotesJson)
    lastSynced      = if ($row) { [string]$row.SyncedAt } else { $null }
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 6)
    Headers    = @{ "Content-Type" = "application/json" }
})
