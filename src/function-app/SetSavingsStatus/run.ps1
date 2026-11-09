using namespace System.Net
param($Request, $TriggerMetadata)

# Set what is happening with one savings finding. Admin-only, audited.
#
# Body: { id, status: 'open'|'in-progress'|'done'|'dismissed', reason? }
#
# The figure AS IT STANDS NOW is stored alongside the status, and that is what makes the rest
# work: 'done' is settled against it by DetectSavings-Timer (the money really stopped only if
# the finding's figure has since fallen by at least half), and a dismissal applies to a finding
# of that size — if it later moves by more than half, GetSavings surfaces it again rather than
# hiding something that is no longer the thing that was dismissed.

$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller -Error 'admin required'); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$id = [string]$Request.Body.id
$status = [string]$Request.Body.status
$reason = [string]$Request.Body.reason
if ($reason.Length -gt 300) { $reason = $reason.Substring(0, 300) }

# The id is a Get-ShortHash value — 16 hex characters — so it is pinned exactly rather than
# escaped, the same rule ExplainSpike follows for the one other id that reaches a filter.
if ($id -notmatch '^[0-9a-fA-F]{16}$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = '{"error":"a valid finding id is required"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}
if ($status -notin @('open', 'in-progress', 'done', 'dismissed')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = '{"error":"status must be open, in-progress, done or dismissed"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# The finding must exist in the latest run — a status on something nothing reports would never
# be seen again, and it is the current figure this status is being set against.
$row = $null
try {
    $row = @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings' and RowKey eq '$(ConvertTo-ODataLiteral -Value $id)'" -Token $token) | Select-Object -First 1
} catch { Write-Host "finding read failed: $($_.Exception.Message)" }
# A finding of a subscription outside the operator's scope is treated as not there.
if ($row -and -not (Test-InSubscriptionScope -Scope (Get-SubscriptionScope -Token $token) -Value $row)) { $row = $null }
if (-not $row) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::NotFound; Body = '{"error":"finding not found"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

$now = [datetime]::UtcNow.ToString('o')
$entity = @{
    PartitionKey        = 'status'
    RowKey              = $id
    Status              = $status
    Reason              = $reason
    SetBy               = if ($caller.Upn) { [string]$caller.Upn } else { 'anonymous' }
    SetAt               = $now
    AmountAtStatusUsd   = [Math]::Round([double]$row.EstMonthlySavingsUsd, 2)
    ResourceId          = [string]$row.ResourceId
    Category            = [string]$row.Category
}
# Re-opening clears a previous settlement, otherwise the realised figure would keep counting
# for something that is back on the list. '' rather than $null: a MERGE keeps a null property.
if ($status -ne 'done') {
    $entity.RealisedUsd = 0.0
    $entity.RealisedAt = ''
}
Set-TableEntity -Table 'SavingsStatus' -Token $token -Entity $entity

Write-AuditEntry -Caller $caller -Action 'SetSavingsStatus' -Target $id -StorageToken $token `
    -Details @{ status = $status; reason = $reason; amountUsd = $entity.AmountAtStatusUsd; resourceId = $entity.ResourceId }

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        id = $id; status = $status; reason = $reason
        amountAtStatusUsd = $entity.AmountAtStatusUsd
        setBy = $entity.SetBy; setAt = $now
        note = if ($status -eq 'done') { 'Counted as realised once the finding stops being reported (or its figure halves) on a later nightly run.' } else { '' }
    } | ConvertTo-Json -Depth 4)
    Headers    = @{ "Content-Type" = "application/json" }
})
