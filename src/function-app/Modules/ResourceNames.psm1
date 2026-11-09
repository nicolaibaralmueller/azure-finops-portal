# ============================================================================
# ResourceNames.psm1 — server-side display-name resolution for resource ids.
#
# The billing data identifies resources by ARM id. For most resources the last id
# segment IS the name, but two classes are opaque GUIDs that the UI cannot make
# readable on its own:
#   - reservation orders:  /providers/microsoft.capacity/reservationorders/{guid}
#     Best name = the CHILD reservation's displayName (Reservations API LIST — needs the
#     OPTIONAL tenant-level 'Reservations Reader' role; reservations have their own RBAC
#     and management-group Reader does not include them). Without the role, falls back to
#     the ReservationName dimension of the Cost Management Query API (covered by the Cost
#     Management Reader role the identity already has) — for purchase rows that is usually
#     the auto-generated numeric order number, still far better than a GUID.
#   - Advisor billing-scope recommendations that carry a bare GUID (not resolvable)
# and for everything else the authoritative display name (exact casing) lives in
# Resource Graph.
#
# Depends on Invoke-CostQueryRest (exported by CostAnalysis.psm1; both modules are
# imported globally by profile.ps1). The guard below also makes this module work when
# imported standalone (tools, tests): -Global so a test can still stub the function by
# redefining it in the global scope afterwards.
if (-not (Get-Command Invoke-CostQueryRest -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'CostAnalysis.psm1') -Global -ErrorAction SilentlyContinue
}
#
# Resolve-ResourceDisplayNames batch-resolves a set of ids to display names so the
# timers can PERSIST the name next to each row they write (resolution is done once
# per daily run, never per portal request). Best-effort: anything it cannot resolve
# is simply absent from the returned map and the UI falls back to parsing the id.
# ============================================================================

# --- private: chunked Resource Graph lookup: id -> name for ARM + container ids ---
function Resolve-ViaResourceGraph {
    param([string[]]$Ids, [string]$MgmtToken)
    $map = @{}
    if (-not $Ids.Count) { return $map }
    for ($i = 0; $i -lt $Ids.Count; $i += 100) {
        $chunk = @($Ids[$i..([Math]::Min($i + 99, $Ids.Count - 1))])
        # Ids never legitimately contain quotes; drop any that do rather than escape.
        $list = ($chunk | Where-Object { $_ -notmatch "'" } | ForEach-Object { "'$_'" }) -join ','
        if (-not $list) { continue }
        # union covers plain resources AND containers (resource groups, subscriptions).
        # NOTE: must be the PIPED form — Resource Graph rejects a leading "union resources, ..."
        # with 400 Operator_FailedToResolveEntity.
        $query = "resources | union resourcecontainers | where id in~ ($list) | project id, name"
        try {
            $resp = Invoke-RestMethod -Method POST `
                -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
                -Headers @{ Authorization = "Bearer $MgmtToken" } `
                -Body (@{ query = $query } | ConvertTo-Json) -ContentType 'application/json'
            foreach ($row in @($resp.data)) {
                if ($row.id -and $row.name) { $map[([string]$row.id).ToLower()] = [string]$row.name }
            }
        } catch {
            # ErrorDetails carries the response body — for 4xx it names the actual problem
            # (e.g. InvalidQuery), which the bare exception message does not.
            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { " — $($_.ErrorDetails.Message)" } else { '' }
            Write-Host "Resource Graph name lookup failed for a chunk of $($chunk.Count): $($_.Exception.Message)$detail"
        }
    }
    return $map
}

# --- private: full reservation-order ids -> display name from the BILLING DATA itself.
# The Cost Management Query API exposes a ReservationName dimension, and the identity
# already has Cost Management Reader — so this needs NO extra RBAC, unlike the
# Reservations API. Queries the tenant scope (COST_QUERY_SCOPE) when configured, else
# every accessible subscription, filtered to just the ids in question. ---
function Resolve-ReservationNamesViaCostData {
    param([string[]]$FullIds, [string]$MgmtToken)
    $map = @{}
    if (-not $FullIds.Count) { return $map }

    $scopes = @()
    if ($env:COST_QUERY_SCOPE) {
        $scopes = @($env:COST_QUERY_SCOPE)
    } else {
        try {
            $uri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
            do {
                $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" }
                foreach ($s in @($resp.value)) { if ([string]$s.state -eq 'Enabled') { $scopes += "/subscriptions/$($s.subscriptionId)" } }
                $uri = $resp.nextLink
            } while ($uri)
        } catch { Write-Host "subscription enumeration for reservation names failed: $($_.Exception.Message)" }
    }

    $to = [datetime]::UtcNow.Date
    $body = @{
        # DELIBERATELY ActualCost, and not configurable like the analysis queries are: this
        # looks up reservation PURCHASE rows to recover their names. AmortizedCost spreads a
        # purchase across its term instead of emitting it as a purchase, so those rows simply
        # don't exist there and name resolution would silently return nothing.
        type       = 'ActualCost'
        timeframe  = 'Custom'
        timePeriod = @{ from = $to.AddDays(-60).ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd') }
        dataset    = @{
            granularity = 'None'
            aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
            grouping    = @(
                @{ type = 'Dimension'; name = 'ResourceId' }
                @{ type = 'Dimension'; name = 'ReservationName' }
            )
            filter      = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = @($FullIds) } }
        }
    } | ConvertTo-Json -Depth 10

    foreach ($scope in $scopes) {
        if ($map.Keys.Count -ge $FullIds.Count) { break }   # everything resolved
        try {
            $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body `
                -Uri "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
            $cols  = @($resp.properties.columns.name)
            $iRes  = [array]::IndexOf($cols, 'ResourceId')
            $iName = [array]::IndexOf($cols, 'ReservationName')
            if ($iRes -lt 0 -or $iName -lt 0) { continue }
            foreach ($r in $resp.properties.rows) {
                $id = ([string]$r[$iRes]).ToLower()
                $name = [string]$r[$iName]
                if ($id -and $name -and -not $map.ContainsKey($id)) { $map[$id] = $name }
            }
        } catch {
            Write-Host "reservation-name cost query failed for scope ${scope}: $($_.Exception.Message)"
        }
    }
    return $map
}

# --- private: order guid -> combined CHILD reservation display name(s), via ONE paged
# LIST of all reservations the identity can read. Child names are the informative ones
# (e.g. "Standard_D8ds_v5_App01_06-01-2025"); order display names are often
# just auto-generated purchase-order numbers. Needs the optional tenant-level
# 'Reservations Reader' role — returns $null when access is denied so callers can
# distinguish "no access" from "no reservations". ---
function Resolve-ReservationChildNames {
    param([Parameter(Mandatory)][string]$MgmtToken)
    $byOrder = @{}
    $uri = 'https://management.azure.com/providers/Microsoft.Capacity/reservations?api-version=2022-11-01'
    try {
        do {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" }
            foreach ($r in @($resp.value)) {
                if ([string]$r.id -match '(?i)reservationorders/([0-9a-f-]{36})') {
                    $orderGuid = $Matches[1].ToLower()
                    $name = [string]$r.properties.displayName
                    if ($name) {
                        if (-not $byOrder.ContainsKey($orderGuid)) { $byOrder[$orderGuid] = @() }
                        $byOrder[$orderGuid] += $name
                    }
                }
            }
            $uri = $resp.nextLink
        } while ($uri)
    } catch {
        if ($_.Exception.Message -match '403|Forbidden') { return $null }
        Write-Host "reservation list failed: $($_.Exception.Message)"
        return $null
    }
    $map = @{}
    foreach ($k in $byOrder.Keys) {
        $names = @($byOrder[$k])
        $map[$k] = if ($names.Count -gt 1) { "$($names[0]) (+$($names.Count - 1) more)" } else { $names[0] }
    }
    return $map
}

# --- private: reservation order GUID -> the ORDER's displayName via the Reservations API.
# Last-resort path: same RBAC requirement as the LIST above, and order names are often just
# purchase-order numbers. ---
function Resolve-ReservationOrderNames {
    param([string[]]$OrderIds, [string]$MgmtToken)
    $map = @{}
    $denied = 0
    foreach ($orderId in $OrderIds) {
        try {
            $resp = Invoke-RestMethod -Method GET `
                -Uri "https://management.azure.com/providers/Microsoft.Capacity/reservationOrders/${orderId}?api-version=2022-11-01" `
                -Headers @{ Authorization = "Bearer $MgmtToken" }
            if ($resp.properties.displayName) { $map[$orderId.ToLower()] = [string]$resp.properties.displayName }
        } catch {
            if ($_.Exception.Message -match '403|Forbidden') { $denied++ }
            else { Write-Host "Reservation order name lookup failed for ${orderId}: $($_.Exception.Message)" }
        }
    }
    if ($denied) {
        Write-Host ("Reservations API denied for $denied order(s) — expected without the tenant-level " +
            "'Reservations Reader' role (optional; Assign-AzureRbac.ps1 -IncludeReservationsReader). " +
            "Names are resolved from cost data where possible; otherwise the UI shows a short-id fallback.")
    }
    return $map
}

# ----------------------------------------------------------------------------
# Resolve-ResourceDisplayNames — batch: resource ids -> hashtable lower(id) -> name.
# Handles subscription-scoped ARM ids (Resource Graph, incl. resource groups) and
# tenant-scoped reservation orders (Reservations API). Never throws.
# ----------------------------------------------------------------------------
function Resolve-ResourceDisplayNames {
    param([string[]]$ResourceIds, [Parameter(Mandatory)][string]$MgmtToken)

    $ids = @($ResourceIds | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $ids.Count) { return @{} }

    $armIds = @()
    $reservationIds = @()   # full reservation-order ids as stored
    foreach ($id in $ids) {
        if ($id -match '(?i)^/providers/microsoft\.capacity/reservationorders/') {
            $reservationIds += $id
        } elseif ($id -match '(?i)/subscriptions/') {
            $armIds += $id
        }
        # anything else (bare GUIDs, billing scopes) is not resolvable here
    }

    $map = Resolve-ViaResourceGraph -Ids $armIds -MgmtToken $MgmtToken

    if ($reservationIds.Count) {
        # Name precedence per order:
        #   1. CHILD reservation display name(s) — the informative ones (Reservations API
        #      LIST; optional tenant-level Reservations Reader role).
        #   2. The billing data's ReservationName dimension (no extra RBAC; for purchase
        #      rows this is usually just the auto-generated order number).
        #   3. The order's own displayName (Reservations API GET; same optional role).
        # The LIST runs FIRST: one request answers everything when the role is granted;
        # the much slower per-scope cost queries only run for ids it didn't cover.
        $childMap = Resolve-ReservationChildNames -MgmtToken $MgmtToken   # $null = access denied
        if ($null -eq $childMap) {
            Write-Host ("Reservations API denied — child reservation names unavailable without the optional " +
                "tenant-level 'Reservations Reader' role (Assign-AzureRbac.ps1 -IncludeReservationsReader). " +
                "Using names from billing data instead (often the numeric order number).")
        }

        $needCostLookup = @()
        foreach ($id in $reservationIds) {
            $orderGuid = if ($id -match '(?i)reservationorders/([0-9a-f-]{36})') { $Matches[1].ToLower() } else { $null }
            $child = if ($childMap -and $orderGuid) { $childMap[$orderGuid] } else { $null }
            if ($child) { $map[$id.ToLower()] = $child } else { $needCostLookup += $id }
        }

        if ($needCostLookup.Count) {
            $fromCost = Resolve-ReservationNamesViaCostData -FullIds $needCostLookup -MgmtToken $MgmtToken
            $unresolvedOrderIds = @()
            foreach ($id in $needCostLookup) {
                $key = $id.ToLower()
                if ($fromCost.ContainsKey($key)) { $map[$key] = $fromCost[$key] }
                elseif ($id -match '(?i)reservationorders/([0-9a-f-]{36})') { $unresolvedOrderIds += $Matches[1] }
            }

            if ($unresolvedOrderIds.Count -and $null -ne $childMap) {
                # LIST worked but didn't cover these orders (and cost data had nothing) — try the
                # order-level GET. Skipped entirely when LIST was denied (GET would 403 the same way).
                $orderNames = Resolve-ReservationOrderNames -OrderIds @($unresolvedOrderIds | Sort-Object -Unique) -MgmtToken $MgmtToken
                foreach ($id in $needCostLookup) {
                    if (-not $map.ContainsKey($id.ToLower()) -and $id -match '(?i)reservationorders/([0-9a-f-]{36})') {
                        $name = $orderNames[$Matches[1].ToLower()]
                        if ($name) { $map[$id.ToLower()] = $name }
                    }
                }
            }
        }
    }
    return $map
}

Export-ModuleMember -Function Resolve-ResourceDisplayNames
