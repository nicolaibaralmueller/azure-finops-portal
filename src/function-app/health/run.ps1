using namespace System.Net
param($Request, $TriggerMetadata)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{ status = "healthy"; timestamp = [DateTime]::UtcNow.ToString("o") } | ConvertTo-Json)
    Headers    = @{ "Content-Type" = "application/json" }
})
