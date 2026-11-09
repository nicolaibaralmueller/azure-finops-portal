# ============================================================================
# Fx.psm1 — exchange rates, in ONE place.
#
# Two callers, one source of truth:
#   1. GetFxRates      — the portal's display-currency selector (all figures are stored in
#                        USD and converted at display time).
#   2. SyncAdvisor     — Azure Advisor reports savings in the BILLING currency, not USD.
#                        Those amounts must be converted BEFORE they are stored or summed
#                        with the app's own USD figures; a EUR number added to a USD number
#                        and then re-converted for display is simply wrong.
#
# Source: ECB daily reference rates (official, free, no key), cached in the PortalConfig
# table for 12 hours. Rates are stored as USD -> currency multipliers, so:
#     display  = usdAmount * Rates[cur]
#     toUsd    = amount / Rates[cur]
# Every ECB currency is cached (not just the ones the UI offers) so Advisor amounts in any
# common billing currency can be converted.
#
# Degrades gracefully: a failed fetch serves the stale cache; no cache at all returns
# $null rates and callers must then refuse to convert rather than guess.
# ============================================================================

$script:EcbDailyUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'

# ----------------------------------------------------------------------------
# Get-FxRates — cached USD-based rate table.
# Returns [PSCustomObject]@{ Rates = @{ USD = 1.0; EUR = 0.92; ... } (or $null); AsOf;
#                            FetchedAt; Source }
# ----------------------------------------------------------------------------
function Get-FxRates {
    param(
        [Parameter(Mandatory)][string]$StorageToken,
        [double]$MaxAgeHours = 12
    )

    $cache = $null
    try {
        $cache = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'fx' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1
    } catch { Write-Host "fx cache read failed: $($_.Exception.Message)" }

    $fresh = $false
    if ($cache -and $cache.FetchedAt) {
        try { $fresh = ([datetime]::UtcNow - [datetime]::Parse([string]$cache.FetchedAt).ToUniversalTime()).TotalHours -lt $MaxAgeHours } catch {}
    }

    if (-not $fresh) {
        try {
            $xml = Invoke-RestMethod -Method GET -Uri $script:EcbDailyUrl -TimeoutSec 15
            $day = $xml.Envelope.Cube.Cube
            $asOf = [string]$day.time
            $perEur = @{}
            foreach ($c in @($day.Cube)) { if ($c.currency) { $perEur[[string]$c.currency] = [double]$c.rate } }
            if (-not $perEur.ContainsKey('USD')) { throw "ECB feed missing USD" }
            $usdPerEur = [double]$perEur['USD']
            if ($usdPerEur -le 0) { throw "ECB feed returned a non-positive USD rate" }

            # Convert the EUR-based feed to USD-based multipliers.
            $rates = @{ USD = 1.0; EUR = [Math]::Round(1.0 / $usdPerEur, 6) }
            foreach ($k in $perEur.Keys) {
                if ($k -eq 'USD') { continue }
                $rates[$k] = [Math]::Round([double]$perEur[$k] / $usdPerEur, 6)
            }

            $ratesJson = ($rates | ConvertTo-Json -Compress)
            $fetchedAt = [datetime]::UtcNow.ToString('o')
            Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{
                PartitionKey = 'fx'
                RowKey       = 'current'
                RatesJson    = $ratesJson
                AsOf         = $asOf
                FetchedAt    = $fetchedAt
            }
            $cache = [PSCustomObject]@{ RatesJson = $ratesJson; AsOf = $asOf; FetchedAt = $fetchedAt }
        } catch {
            Write-Host "ECB rate fetch failed (serving cache if any): $($_.Exception.Message)"
        }
    }

    if ($cache -and $cache.RatesJson) {
        $rates = @{}
        try {
            $parsed = $cache.RatesJson | ConvertFrom-Json
            foreach ($p in $parsed.PSObject.Properties) { $rates[$p.Name] = [double]$p.Value }
        } catch {
            Write-Host "fx cache is unparseable — treating as no rates: $($_.Exception.Message)"
            $rates = $null
        }
        return [PSCustomObject]@{ Rates = $rates; AsOf = [string]$cache.AsOf; FetchedAt = [string]$cache.FetchedAt; Source = 'ECB reference rates' }
    }

    return [PSCustomObject]@{ Rates = $null; AsOf = $null; FetchedAt = $null; Source = $null }
}

# ----------------------------------------------------------------------------
# ConvertTo-Usd — convert an amount in $Currency to USD using a Get-FxRates table.
# Returns $null when it cannot be converted (no rates, unknown currency, bad rate) so the
# caller can EXCLUDE the figure instead of silently mislabelling it as USD.
# An empty/absent currency is treated as USD (Advisor omits it on some rec types).
# ----------------------------------------------------------------------------
# -AssumeCurrency is what an amount is taken to be when the source didn't say. It defaults to
# USD only because that is the safe reading for a USD-billed tenant; on any other tenant that
# assumption is wrong by the whole exchange rate. Advisor omits `savingsCurrency` on some
# recommendation types, so for a non-USD tenant the old unconditional "no currency means USD" turned
# 1,000 in the billing currency into $1,000 — off by the exchange rate, and then converted back
# for display, off by it again. Callers
# that know the tenant's billing currency should pass it; callers that don't should pass $null
# and let the figure be excluded rather than mislabelled.
function ConvertTo-Usd {
    param(
        [Parameter(Mandatory)][double]$Amount,
        [string]$Currency,
        $Rates,
        [string]$AssumeCurrency = 'USD'
    )
    $cur = ([string]$Currency).Trim().ToUpper()
    if ([string]::IsNullOrWhiteSpace($cur)) {
        $cur = ([string]$AssumeCurrency).Trim().ToUpper()
        if ([string]::IsNullOrWhiteSpace($cur)) {
            Write-Host "  fx: an amount arrived with no currency and no assumption to fall back on — excluding it rather than guessing."
            return $null
        }
        if ($cur -ne 'USD') { Write-Host "  fx: amount had no currency; treating it as the tenant's billing currency ($cur)." }
    }
    if ($cur -eq 'USD') { return $Amount }
    if (-not $Rates) { return $null }
    $rate = $null
    if ($Rates -is [hashtable]) {
        if ($Rates.ContainsKey($cur)) { $rate = [double]$Rates[$cur] }
    } else {
        $p = $Rates.PSObject.Properties[$cur]
        if ($p) { $rate = [double]$p.Value }
    }
    if ($null -eq $rate -or $rate -le 0) { return $null }
    return $Amount / $rate
}

# ----------------------------------------------------------------------------
# Get-BillingCurrencyRate — the tenant's billing currency, and Azure's OWN USD->billing ratio.
#
# Figures the portal only has in USD (per-resource cost, findings, evidence) used to be shown in
# the billing currency by multiplying with the ECB rate. That lands about 1.4% away from what
# Cost analysis and the invoice say, because Azure normalised to USD with its own rate, and it
# drifts daily even for closed months. The daily totals carry BOTH figures for the same days,
# so their ratio is the rate Azure actually used: converting with it puts every USD figure on
# the same basis as the billed ones next to it.
#
# Only when the whole tenant bills in ONE currency (a mixed tenant has no single billing
# currency to show). Returns $null otherwise, and the UI falls back to ECB for any conversion.
# ----------------------------------------------------------------------------
function Get-BillingCurrencyRate {
    param([Parameter(Mandatory)][string]$StorageToken, [int]$Days = 45)
    $from = [datetime]::UtcNow.Date.AddDays(-$Days).ToString('yyyy-MM-dd')
    $rows = @()
    try {
        $rows = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailytotal' and RowKey ge '$from'" -Token $StorageToken)
    } catch {
        Write-Host "billing-rate read failed: $($_.Exception.Message)"
        return $null
    }
    $currencies = @{}
    $usd = 0.0; $billing = 0.0; $n = 0
    foreach ($r in $rows) {
        if ($null -eq $r.TotalBilling -or -not $r.Currency -or [double]$r.TotalUsd -le 0) { continue }
        $currencies[[string]$r.Currency] = $true
        $usd += [double]$r.TotalUsd
        $billing += [double]$r.TotalBilling
        $n++
    }
    if ($currencies.Count -ne 1 -or $n -lt 1 -or $usd -le 0) { return $null }
    return [PSCustomObject]@{
        Currency = @($currencies.Keys)[0]
        Rate     = [Math]::Round($billing / $usd, 6)
        Days     = $n
    }
}

Export-ModuleMember -Function Get-FxRates, ConvertTo-Usd, Get-BillingCurrencyRate
