using namespace System.Net
param($Request, $TriggerMetadata)

# Currency information for the portal's display selector. Read-only; members allowed.
#
#   billing  The tenant's billing currency and Azure's own USD->billing ratio, derived from the
#            stored daily totals (Get-BillingCurrencyRate). This is the portal's DEFAULT display
#            currency: figures stored in both currencies are shown as billed, and USD-only
#            figures are converted with the rate Azure itself used, so everything on a page
#            agrees with Cost analysis and the invoice.
#   rates    ECB reference rates (Fx.psm1), used only when the viewer picks a currency that is
#            neither USD nor the billing currency. On fetch failure the stale cache is served;
#            with no cache at all only USD and the billing currency are selectable.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

$fx = Get-FxRates -StorageToken $token
$billing = $null
try { $billing = Get-BillingCurrencyRate -StorageToken $token } catch { Write-Host "billing-rate failed: $($_.Exception.Message)" }

$result = @{
    base    = 'USD'
    rates   = $fx.Rates
    asOf    = $fx.AsOf
    source  = $fx.Source
    billing = if ($billing) { @{ currency = $billing.Currency; rate = $billing.Rate; days = $billing.Days } } else { $null }
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = ($result | ConvertTo-Json -Depth 4)
    Headers    = @{ "Content-Type" = "application/json" }
})
