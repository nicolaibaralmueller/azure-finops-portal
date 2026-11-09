# ============================================================================
# Commitments.psm1 — reservations and savings plans: what is wasted, how well each is used,
# when each ends, and what Azure recommends buying.
#
# Commitments are usually the largest saving on a tenant and the easiest to get wrong, so every
# figure here is Azure's own:
#   Get-UnusedCommitmentCost   the cost of commitment hours nothing used (charge types
#                              UnusedReservation / UnusedSavingsPlan in amortized cost data).
#                              Measured money, so it becomes a savings finding.
#   Get-CommitmentInventory    each reservation / savings plan with its 7- and 30-day
#                              utilisation and expiry. Needs the optional tenant-level
#                              Reservations Reader / Savings plan Reader roles; without them it
#                              says so and returns nothing.
#   Get-CommitmentConsumption  which resources use each commitment: amortized usage by benefit
#                              and resource, plus its unused cost (Reservations page).
#   Get-CommitmentRecommendations  Azure's purchase recommendations per subscription (Consumption
#                              reservationRecommendations + Cost Management benefitRecommendations),
#                              with the effective discount: what the same usage costs WITH the
#                              commitment as a share of pay-as-you-go. Informational — Advisor
#                              lists the same recommendations, and those are what the totals count.
# ============================================================================

$script:DaysPerMonth = 30.4

# 'value' or { value = n } (the Consumption API returns both shapes depending on 'kind').
function ConvertTo-Amount {
    param($v)
    if ($null -eq $v) { return $null }
    if ($v -is [System.Management.Automation.PSCustomObject] -and $v.PSObject.Properties['value']) { $v = $v.value }
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-CommitmentKind {
    param([string]$Id)
    if ($Id -match '(?i)savingsplanorders') { return 'savings plan' }
    if ($Id -match '(?i)reservationorders') { return 'reservation' }
    return 'commitment'
}

# ----------------------------------------------------------------------------
# Unused commitment cost over the last -Days, per reservation / savings plan, at each scope in
# -Scopes (a management group, or one subscription each). AmortizedCost regardless of the
# portal's cost type: unused hours only exist as separate charges on the amortized view.
# Returns @{ Items = [{ Id; Name; Kind; UnusedUsd; Days }]; Notes = [..] }. Never throws.
# ----------------------------------------------------------------------------
function Get-UnusedCommitmentCost {
    param(
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string[]]$Scopes,
        [string[]]$SubscriptionIds,
        [int]$Days = 30
    )
    $to = [datetime]::UtcNow.Date.AddDays(-1)
    $from = $to.AddDays(-($Days - 1))
    $byId = @{}
    $notes = @()
    foreach ($scope in @($Scopes | Where-Object { $_ })) {
        $filters = @(@{ dimensions = @{ name = 'ChargeType'; operator = 'In'; values = @('UnusedReservation', 'UnusedSavingsPlan') } })
        if ($SubscriptionIds -and $SubscriptionIds.Count -and $scope -notlike '/subscriptions/*') {
            $filters += @{ dimensions = @{ name = 'SubscriptionId'; operator = 'In'; values = @($SubscriptionIds) } }
        }
        $done = $false
        # BenefitId/BenefitName cover both kinds; older data only knows the reservation columns.
        foreach ($pair in @(@('BenefitId', 'BenefitName'), @('ReservationId', 'ReservationName'))) {
            if ($done) { break }
            $body = @{
                type = 'AmortizedCost'; timeframe = 'Custom'
                timePeriod = @{ from = $from.ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd') }
                dataset = @{
                    granularity = 'None'
                    aggregation = @{ totalCost = @{ name = 'CostUSD'; function = 'Sum' } }
                    grouping = @(@{ type = 'Dimension'; name = $pair[0] }, @{ type = 'Dimension'; name = $pair[1] })
                    filter = if ($filters.Count -eq 1) { $filters[0] } else { @{ and = $filters } }
                }
            } | ConvertTo-Json -Depth 12
            try {
                $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body `
                    -Uri "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
                $cols = @($resp.properties.columns.name)
                $iId = [array]::IndexOf($cols, $pair[0]); $iName = [array]::IndexOf($cols, $pair[1]); $iCost = [array]::IndexOf($cols, 'CostUSD')
                foreach ($r in $resp.properties.rows) {
                    $id = if ($iId -ge 0) { ([string]$r[$iId]).ToLowerInvariant() } else { '' }
                    if (-not $id -or $iCost -lt 0) { continue }
                    $cost = [double]$r[$iCost]
                    if (-not $byId.ContainsKey($id)) {
                        $byId[$id] = [PSCustomObject]@{ Id = $id; Name = if ($iName -ge 0) { [string]$r[$iName] } else { '' }; Kind = (Get-CommitmentKind $id); UnusedUsd = 0.0; Days = $Days }
                    }
                    $byId[$id].UnusedUsd += $cost
                }
                $done = $true
            } catch {
                if ($pair[0] -eq 'ReservationId') { $notes += "unused-commitment query failed at ${scope}: $($_.Exception.Message)" }
            }
        }
    }
    return [PSCustomObject]@{ Items = @($byId.Values | Where-Object { $_.UnusedUsd -gt 0 } | Sort-Object UnusedUsd -Descending); Notes = $notes }
}

# ----------------------------------------------------------------------------
# Which resources use each reservation / savings plan, over the last -Days (Reservations page).
# Amortized cost data, daily, at each scope in -Scopes (a management group, or one subscription
# each):
#   usage    PricingModel Reservation / SavingsPlan, charge type Usage, by benefit and resource:
#            the prorated commitment cost each resource consumed;
#   unused   charge types UnusedReservation / UnusedSavingsPlan, by benefit.
# The Query API allows two groupings, hence two queries. Pages are followed (properties.nextLink).
# Returns @{ Items = [{ id; name; kind; used30dUsd; used7dUsd; unused30dUsd; unused7dUsd;
#   unusedKnown; lastUsed; resourceCount; resources = [{ resourceId; subscriptionId;
#   resourceGroup; name; cost30dUsd; cost7dUsd; quantity30d; sharePct; lastUsed; days }] }];
#   Notes }. Never throws.
# ----------------------------------------------------------------------------
function ConvertFrom-CostUsageDate {
    param($Value)
    $s = [string]$Value
    $d = [datetime]::MinValue
    if ($s -match '^\d{8}$' -and [datetime]::TryParseExact($s, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d.Date }
    if ([datetime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { return $d.Date }
    return $null
}

# One daily amortized query, every page. Rows come back as hashtables keyed by column name.
function Invoke-CommitmentDailyQuery {
    param([Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)]$Filter,
          [Parameter(Mandatory)][string[]]$Grouping, [datetime]$From, [datetime]$To, [int]$MaxPages = 20)
    $body = @{
        type = 'AmortizedCost'; timeframe = 'Custom'
        timePeriod = @{ from = $From.ToString('yyyy-MM-dd'); to = $To.ToString('yyyy-MM-dd') }
        dataset = @{
            granularity = 'Daily'
            aggregation = @{ totalCost = @{ name = 'CostUSD'; function = 'Sum' }; totalQuantity = @{ name = 'UsageQuantity'; function = 'Sum' } }
            grouping = @($Grouping | ForEach-Object { @{ type = 'Dimension'; name = $_ } })
            filter = $Filter
        }
    } | ConvertTo-Json -Depth 12
    $uri = "https://management.azure.com$Scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    for ($page = 0; $page -lt $MaxPages -and $uri; $page++) {
        $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body -Uri $uri
        $cols = @($resp.properties.columns.name)
        foreach ($r in @($resp.properties.rows)) {
            $h = @{}
            for ($i = 0; $i -lt $cols.Count; $i++) { $h[[string]$cols[$i]] = $r[$i] }
            $rows.Add($h)
        }
        $uri = [string]$resp.properties.nextLink
    }
    return $rows
}

function Get-CommitmentConsumption {
    param(
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string[]]$Scopes,
        [int]$Days = 30
    )
    $to = [datetime]::UtcNow.Date.AddDays(-1)
    $from = $to.AddDays(-($Days - 1))
    $from7 = $to.AddDays(-6)
    $byId = @{}
    $notes = @()
    $unusedFailed = $false
    $get = {
        param([string]$Id, [string]$Name)
        if (-not $byId.ContainsKey($Id)) {
            $byId[$Id] = [PSCustomObject]@{ id = $Id; name = $Name; kind = (Get-CommitmentKind $Id)
                used30dUsd = 0.0; used7dUsd = 0.0; unused30dUsd = 0.0; unused7dUsd = 0.0; unusedKnown = $true; lastUsed = $null
                resourceCount = 0; resources = @{} }
        } elseif ($Name -and -not $byId[$Id].name) { $byId[$Id].name = $Name }
        return $byId[$Id]
    }
    $pricing = @{ dimensions = @{ name = 'PricingModel'; operator = 'In'; values = @('Reservation', 'SavingsPlan') } }
    foreach ($scope in @($Scopes | Where-Object { $_ })) {
        # BenefitId covers both kinds; older data only knows ReservationId (as in Get-UnusedCommitmentCost).
        $done = $false
        foreach ($idCol in @('BenefitId', 'ReservationId')) {
            if ($done) { break }
            try {
                $usageFilter = @{ and = @($pricing, @{ dimensions = @{ name = 'ChargeType'; operator = 'In'; values = @('Usage') } }) }
                $rows = Invoke-CommitmentDailyQuery -MgmtToken $MgmtToken -Scope $scope -Filter $usageFilter -Grouping @($idCol, 'ResourceId') -From $from -To $to
                foreach ($r in $rows) {
                    $id = ([string]$r[$idCol]).ToLowerInvariant(); $rid = ([string]$r['ResourceId']).ToLowerInvariant()
                    if (-not $id -or -not $rid) { continue }
                    $cost = [double]($r['CostUSD'] ?? 0); $qty = [double]($r['UsageQuantity'] ?? 0)
                    $day = ConvertFrom-CostUsageDate $r['UsageDate']
                    $c = & $get $id ''
                    if (-not $c.resources.ContainsKey($rid)) {
                        $sid = if ($rid -match '^/subscriptions/([0-9a-f-]{36})') { $Matches[1] } else { '' }
                        $rg = if ($rid -match '/resourcegroups/([^/]+)') { $Matches[1] } else { '' }
                        $c.resources[$rid] = [PSCustomObject]@{ resourceId = $rid; subscriptionId = $sid; resourceGroup = $rg; name = ($rid -split '/')[-1]
                            cost30dUsd = 0.0; cost7dUsd = 0.0; quantity30d = 0.0; sharePct = 0.0; lastUsed = $null; days = 0; dayKeys = @{} }
                    }
                    $res = $c.resources[$rid]
                    $res.cost30dUsd += $cost; $res.quantity30d += $qty; $c.used30dUsd += $cost
                    if ($day) {
                        if ($day -ge $from7) { $res.cost7dUsd += $cost; $c.used7dUsd += $cost }
                        $dk = $day.ToString('yyyy-MM-dd')
                        if ($cost -gt 0 -or $qty -gt 0) {
                            $res.dayKeys[$dk] = $true
                            if (-not $res.lastUsed -or $dk -gt $res.lastUsed) { $res.lastUsed = $dk }
                            if (-not $c.lastUsed -or $dk -gt $c.lastUsed) { $c.lastUsed = $dk }
                        }
                    }
                }
                $done = $true
            } catch {
                if ($idCol -eq 'ReservationId') { $notes += "commitment usage query failed at ${scope}: $($_.Exception.Message)" }
            }
        }
        $done = $false
        foreach ($pair in @(@('BenefitId', 'BenefitName'), @('ReservationId', 'ReservationName'))) {
            if ($done) { break }
            try {
                $unusedFilter = @{ dimensions = @{ name = 'ChargeType'; operator = 'In'; values = @('UnusedReservation', 'UnusedSavingsPlan') } }
                $rows = Invoke-CommitmentDailyQuery -MgmtToken $MgmtToken -Scope $scope -Filter $unusedFilter -Grouping $pair -From $from -To $to
                foreach ($r in $rows) {
                    $id = ([string]$r[$pair[0]]).ToLowerInvariant()
                    if (-not $id) { continue }
                    $cost = [double]($r['CostUSD'] ?? 0)
                    $c = & $get $id ([string]$r[$pair[1]])
                    $c.unused30dUsd += $cost
                    $day = ConvertFrom-CostUsageDate $r['UsageDate']
                    if ($day -and $day -ge $from7) { $c.unused7dUsd += $cost }
                }
                $done = $true
            } catch {
                if ($pair[0] -eq 'ReservationId') { $unusedFailed = $true; $notes += "unused-commitment query failed at ${scope}: $($_.Exception.Message)" }
            }
        }
    }
    $items = foreach ($c in $byId.Values) {
        $res = @($c.resources.Values | Sort-Object cost30dUsd -Descending | ForEach-Object {
            [PSCustomObject]@{ resourceId = $_.resourceId; subscriptionId = $_.subscriptionId; resourceGroup = $_.resourceGroup; name = $_.name
                cost30dUsd = [Math]::Round($_.cost30dUsd, 2); cost7dUsd = [Math]::Round($_.cost7dUsd, 2); quantity30d = [Math]::Round($_.quantity30d, 2)
                sharePct = if ($c.used30dUsd -gt 0) { [Math]::Round(100 * $_.cost30dUsd / $c.used30dUsd, 1) } else { 0.0 }
                lastUsed = $_.lastUsed; days = $_.dayKeys.Count }
        })
        [PSCustomObject]@{ id = $c.id; name = $c.name; kind = $c.kind
            used30dUsd = [Math]::Round($c.used30dUsd, 2); used7dUsd = [Math]::Round($c.used7dUsd, 2)
            unused30dUsd = [Math]::Round($c.unused30dUsd, 2); unused7dUsd = [Math]::Round($c.unused7dUsd, 2); unusedKnown = (-not $unusedFailed)
            lastUsed = $c.lastUsed; resourceCount = $res.Count; resources = $res; days = $Days }
    }
    return [PSCustomObject]@{ Items = @($items | Sort-Object used30dUsd -Descending); Notes = $notes }
}

# Savings findings from unused commitment cost: the monthly equivalent of what paid for nothing.
function ConvertTo-UnusedCommitmentFindings {
    param($Unused, [double]$MinMonthlyUsd = 10)
    $out = @()
    foreach ($u in @($Unused.Items)) {
        $monthly = [Math]::Round([double]$u.UnusedUsd / [double]$u.Days * $script:DaysPerMonth, 2)
        if ($monthly -lt $MinMonthlyUsd) { continue }
        $short = ([string]$u.Id -split '/')[-1]
        if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
        $name = if ($u.Name) { $u.Name } else { "$($u.Kind) $short" }
        $action = if ($u.Kind -eq 'savings plan') { Get-PortalText 'savings.unused.plan' } else { Get-PortalText 'savings.unused.reservation' }
        $kindText = Get-PortalText "kind.$($u.Kind)"
        $out += [PSCustomObject]@{
            Category = 'commitment-unused'; ResourceId = [string]$u.Id; ResourceType = "unused $($u.Kind)"; Sku = ''; Location = ''
            Title = (Get-PortalText 'savings.unused.title' @{ kind = $kindText; name = $name })
            # No amounts in the text: the page shows the saving in the display currency beside it.
            Detail = (Get-PortalText 'savings.unused.detail' @{ days = $u.Days; kind = $kindText; action = $action })
            EstMonthlySavingsUsd = $monthly
            Confidence = 'high'
            # LIKELY rather than certain: the money is measurably wasted, but getting it back
            # needs a change to the commitment itself.
            Tier = 'likely'
            Evidence = @{ unusedUsd = [Math]::Round([double]$u.UnusedUsd, 2); days = $u.Days; kind = $u.Kind; resourceName = $name }
        }
    }
    return @($out)
}

# Utilisation block -> @{ d1; d7; d30 } percentages (the APIs return aggregates by grain).
function Get-UtilisationAggregates {
    param($Utilization)
    $r = @{ d1 = $null; d7 = $null; d30 = $null }
    foreach ($a in @($Utilization.aggregates)) {
        $g = [int]$a.grain
        $v = ConvertTo-Amount $a.value
        if ($g -eq 1) { $r.d1 = $v } elseif ($g -eq 7) { $r.d7 = $v } elseif ($g -eq 30) { $r.d30 = $v }
    }
    return $r
}

# ----------------------------------------------------------------------------
# Every reservation and savings plan the identity can see, with utilisation and expiry. Cancelled
# and expired ones are kept with their status (the Reservations page lists them, filterable; the
# Savings page's panel shows active ones only); failed purchases are left out.
# Returns @{ Items; Notes }, active first. A 403 is a missing optional role, reported as a note.
# ----------------------------------------------------------------------------
function Get-CommitmentInventory {
    param([Parameter(Mandatory)][string]$MgmtToken, [int]$ExpiringWithinDays = 60)
    $h = @{ Authorization = "Bearer $MgmtToken" }
    $items = @(); $notes = @()
    $today = [datetime]::UtcNow.Date
    $sources = @(
        @{ Kind = 'reservation'; Role = 'Reservations Reader'; Uri = 'https://management.azure.com/providers/Microsoft.Capacity/reservations?api-version=2022-11-01' }
        @{ Kind = 'savings plan'; Role = 'Savings plan Reader'; Uri = 'https://management.azure.com/providers/Microsoft.BillingBenefits/savingsPlans?api-version=2022-11-01' }
    )
    foreach ($src in $sources) {
        $uri = $src.Uri
        try {
            do {
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $h -TimeoutSec 60
                foreach ($x in @($resp.value)) {
                    $p = $x.properties
                    $state = if ($p.displayProvisioningState) { [string]$p.displayProvisioningState } else { [string]$p.provisioningState }
                    if ($state -match '(?i)fail') { continue }
                    $exp = $null
                    $d = [datetime]::MinValue
                    if ($p.expiryDateTime -and [datetime]::TryParse([string]$p.expiryDateTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { $exp = $d.Date }
                    elseif ($p.expiryDate -and [datetime]::TryParse([string]$p.expiryDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { $exp = $d.Date }
                    $u = Get-UtilisationAggregates $p.utilization
                    $daysLeft = if ($exp) { [int]($exp - $today).TotalDays } else { $null }
                    $status = if ($state -match '(?i)cancel') { 'cancelled' }
                              elseif ($state -match '(?i)expir' -or ($null -ne $daysLeft -and $daysLeft -lt 0)) { 'expired' }
                              else { 'active' }
                    $items += [PSCustomObject]@{
                        kind = $src.Kind
                        id = ([string]$x.id).ToLowerInvariant()
                        name = if ($p.displayName) { [string]$p.displayName } else { [string]$x.name }
                        location = [string]$x.location
                        sku = if ($p.skuDescription) { [string]$p.skuDescription } elseif ($x.sku.name) { [string]$x.sku.name } else { '' }
                        quantity = if ($null -ne $p.quantity) { [int]$p.quantity } else { $null }
                        commitment = if ($p.commitment) { [PSCustomObject]@{ amount = (ConvertTo-Amount $p.commitment.amount); currency = [string]$p.commitment.currencyCode; grain = [string]$p.commitment.grain } } else { $null }
                        term = [string]$p.term
                        appliedScope = [string]$p.appliedScopeType
                        renew = [bool]$p.renew
                        expiryDate = if ($exp) { $exp.ToString('yyyy-MM-dd') } else { $null }
                        daysToExpiry = $daysLeft
                        status = $status
                        archived = [bool]$p.archived
                        expiringSoon = ($status -eq 'active' -and $null -ne $daysLeft -and $daysLeft -ge 0 -and $daysLeft -le $ExpiringWithinDays)
                        utilisation7d = $u.d7
                        utilisation30d = $u.d30
                    }
                }
                $uri = $resp.nextLink
            } while ($uri)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match '(?i)403|forbidden|authoriz') {
                $notes += Get-PortalText 'commit.missingRole' @{ kind = $src.Kind; role = $src.Role }
            } else { $notes += "$($src.Kind)s could not be listed: $msg" }
        }
    }
    # Active first (the stored list is capped), then lowest utilisation.
    return [PSCustomObject]@{ Items = @($items | Sort-Object -Property @{ Expression = { $_.status -ne 'active' } }, @{ Expression = { if ($null -ne $_.utilisation30d) { $_.utilisation30d } else { 101 } } }); Notes = $notes }
}

# ----------------------------------------------------------------------------
# Azure's purchase recommendations for each subscription (single-subscription scope, last 30
# days of usage). Returns @{ Items = [{ kind; subscriptionId; description; term; quantity or
# hourlyCommitment; monthlySavingsUsd; effectiveCostPct; lookback }]; Notes }. Never throws.
# ----------------------------------------------------------------------------
function Get-CommitmentRecommendations {
    param([Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds, [hashtable]$SubscriptionNames = @{})
    $h = @{ Authorization = "Bearer $MgmtToken" }
    $items = @(); $notes = @()
    foreach ($sid in @($SubscriptionIds)) {
        $subName = if ($SubscriptionNames[$sid]) { $SubscriptionNames[$sid] } else { $sid }
        # Reservations (Consumption API).
        $filter = [uri]::EscapeDataString("properties/scope eq 'Single' AND properties/lookBackPeriod eq 'Last30Days'")
        try {
            $uri = "https://management.azure.com/subscriptions/$sid/providers/Microsoft.Consumption/reservationRecommendations?api-version=2023-05-01&`$filter=$filter"
            do {
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $h -TimeoutSec 60
                foreach ($x in @($resp.value)) {
                    $p = $x.properties
                    $without = ConvertTo-Amount $p.costWithNoReservedInstances
                    $with = ConvertTo-Amount $p.totalCostWithReservedInstances
                    $net = ConvertTo-Amount $p.netSavings
                    if ($null -eq $net -or $net -le 0) { continue }
                    $sku = if ($p.normalizedSize) { [string]$p.normalizedSize } elseif ($p.skuProperties) { [string](@($p.skuProperties | Where-Object { $_.name -eq 'SkuName' })[0].value) } else { [string]$x.sku }
                    $items += [PSCustomObject]@{
                        kind = 'reservation'; subscriptionId = $sid; subscriptionName = $subName
                        description = (@($p.resourceType, $sku, $x.location) | Where-Object { $_ }) -join ' · '
                        term = [string]$p.term
                        quantity = (ConvertTo-Amount $p.recommendedQuantity)
                        hourlyCommitment = $null
                        monthlySavingsUsd = [Math]::Round($net / 30 * $script:DaysPerMonth, 2)
                        effectiveCostPct = if ($without -gt 0 -and $null -ne $with) { [Math]::Round($with / $without * 100, 1) } else { $null }
                        lookback = [string]$p.lookBackPeriod
                    }
                }
                $uri = $resp.nextLink
            } while ($uri)
        } catch { $notes += "reservation recommendations for ${subName}: $($_.Exception.Message)" }

        # Savings plans (Cost Management benefitRecommendations), 1- and 3-year.
        foreach ($term in @('P1Y', 'P3Y')) {
            $f = [uri]::EscapeDataString("properties/lookBackPeriod eq 'Last30Days' AND properties/term eq '$term'")
            try {
                $resp = Invoke-RestMethod -Method GET -Headers $h -TimeoutSec 60 `
                    -Uri "https://management.azure.com/subscriptions/$sid/providers/Microsoft.CostManagement/benefitRecommendations?api-version=2023-08-01&`$filter=$f"
                foreach ($x in @($resp.value)) {
                    $p = $x.properties
                    $d = $p.recommendationDetails
                    $saving = ConvertTo-Amount $d.savingsAmount
                    if ($null -eq $saving -or $saving -le 0) { continue }
                    $without = ConvertTo-Amount $p.costWithoutBenefit
                    $total = ConvertTo-Amount $d.totalCost
                    $items += [PSCustomObject]@{
                        kind = 'savings plan'; subscriptionId = $sid; subscriptionName = $subName
                        description = "Compute savings plan ($(if ($d.coveragePercentage) { "covers $([Math]::Round((ConvertTo-Amount $d.coveragePercentage), 0))% of eligible usage" } else { 'eligible compute' }))"
                        term = $term
                        quantity = $null
                        hourlyCommitment = (ConvertTo-Amount $d.commitmentAmount)
                        monthlySavingsUsd = [Math]::Round($saving / 30 * $script:DaysPerMonth, 2)
                        effectiveCostPct = if ($without -gt 0 -and $null -ne $total) { [Math]::Round($total / $without * 100, 1) } else { $null }
                        lookback = [string]$p.lookBackPeriod
                    }
                }
            } catch { $notes += "savings plan recommendations ($term) for ${subName}: $($_.Exception.Message)" }
        }
    }
    return [PSCustomObject]@{ Items = @($items | Sort-Object monthlySavingsUsd -Descending); Notes = $notes }
}

Export-ModuleMember -Function `
    Get-UnusedCommitmentCost, ConvertTo-UnusedCommitmentFindings, Get-CommitmentInventory, `
    Get-CommitmentRecommendations, Get-UtilisationAggregates, Get-CommitmentConsumption, ConvertFrom-CostUsageDate
