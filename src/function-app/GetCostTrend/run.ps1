using namespace System.Net
param($Request, $TriggerMetadata)

# Long-range daily-spend series for the dashboard trend chart. Served from the
# 'dailytotal' rows in CostSummary, which DetectCostSpikes-Timer accumulates one per day
# (so history grows over time, independent of the short detection window).
# Query params: ?days=<n> (default 90, clamped 1..366). Read-only; members allowed.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$days = 90
if ($Request.Query -and $Request.Query['days']) {
    $parsed = 0
    if ([int]::TryParse([string]$Request.Query['days'], [ref]$parsed)) { $days = $parsed }
}
$days = [Math]::Min([Math]::Max($days, 1), 366)
$cutoff = ([datetime]::UtcNow.Date).AddDays(-$days).ToString('yyyy-MM-dd')

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$rows = @()
try {
    # RowKey is the yyyy-MM-dd date, so the range filter is the indexed path.
    $rows = @(Get-TableEntities -Table 'CostSummary' `
        -Filter "PartitionKey eq 'dailytotal' and RowKey ge '$cutoff'" -Token $token)
} catch {
    Write-Host "dailytotal read failed: $($_.Exception.Message)"
}

# Drop the still-settling tail. Azure keeps billing the newest day or two, so plotting them
# draws a cliff at the right edge of every chart that isn't a real drop in spend. The same
# cut-off drives detection and the dashboard headline, so all three agree.
$settledThrough = (Get-RollingWindowEndDate).ToString('yyyy-MM-dd')
$points = @($rows | Where-Object { [string]$_.RowKey -le $settledThrough } | Sort-Object -Property RowKey | ForEach-Object {
    $pt = [ordered]@{ date = [string]$_.RowKey; usd = [double]$_.TotalUsd }
    # The billing-currency figure, when the ingest stored one. The UI shows it as-is whenever
    # the display currency matches — the only way a number here ties out exactly against Cost
    # analysis, since converting USD back with ECB rates lands ~1.4% off and drifts daily.
    if ($null -ne $_.TotalBilling) { $pt.billing = [double]$_.TotalBilling }
    if ($_.Currency) { $pt.currency = [string]$_.Currency }
    [PSCustomObject]$pt
})

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{ points = $points; count = $points.Count; days = $days; settledThrough = $settledThrough
                    # True = the history was built for a different subscription scope; the next ingest rebuilds it.
                    scopePending = (Test-ScopeHashPending -Scope (Get-SubscriptionScope -Token $token) -Stored (Get-DailyTotalScopeHash -Token $token)) } | ConvertTo-Json -Depth 4)
    Headers    = @{ "Content-Type" = "application/json" }
})
