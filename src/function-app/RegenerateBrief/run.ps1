using namespace System.Net
param($Request, $TriggerMetadata)

# Rebuild the executive brief now. Admin-only: it spends one AI call on the customer's key.
# Body: { grain: 'week' | 'month' }. Over the daily AI limit the brief is still rebuilt with
# fresh figures, and the response is 429 so the page can say why there is no new text.

$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller -Error 'admin required'); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$grain = if ($Request.Body -and [string]$Request.Body.grain -eq 'month') { 'month' } else { 'week' }
$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
Write-AuditEntry -Caller $caller -Action 'RegenerateBrief' -Target $grain -StorageToken $token

try {
    $doc = Update-PortfolioBrief -Grain $grain -Token $token -Force
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadGateway; Body = (Write-ErrorBody -Message 'The brief could not be rebuilt.' -Exception $_ -TriggerMetadata $TriggerMetadata); Headers = @{ "Content-Type" = "application/json" } })
    return
}

if ($doc.aiStatus -eq 'budget-exceeded') {
    $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'brief' and RowKey eq '$grain'" -Token $token) | Select-Object -First 1
    $msg = if ($row -and $row.AiError) { ([string]$row.AiError -replace '^AI_BUDGET_EXCEEDED:\s*', '') } else { 'The daily AI limit has been reached.' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::TooManyRequests
        Body       = (@{ error = $msg; brief = $doc } | ConvertTo-Json -Depth 16)
        Headers    = @{ "Content-Type" = "application/json" }
    })
    return
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{ grain = $grain; available = $true; canRegenerate = $true; brief = $doc } | ConvertTo-Json -Depth 16)
    Headers    = @{ "Content-Type" = "application/json" }
})
