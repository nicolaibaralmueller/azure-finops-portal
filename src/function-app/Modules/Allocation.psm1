# ============================================================================
# Allocation.psm1 — WHO spends it: cost by owner / cost centre / environment / application tag,
# and by resource group.
#
# A finding nobody owns doesn't get acted on. This module answers "whose is this?" twice:
#   - per resource, for stamping the owner (and the other allocation tags) on every finding:
#     Get-ResourceTagIndex + Get-ResourceAllocation;
#   - in aggregate, for the Overview's "Who spends it": Measure-AllocationRollup over the
#     per-resource cost the ingest already stores, so it costs no Cost Management queries.
#
# Tags come from Resource Graph as they are NOW, with the resource group's tag used when the
# resource has none (the same inheritance Cost Management offers as a tenant setting). Tag KEYS
# are matched loosely — 'Owner', 'owner' and 'cost-center' match 'owner' and 'costcenter' —
# because real tenants are inconsistent and an exact match would report most spend as untagged.
#
# The rollup covers RESOURCE-ATTRIBUTED cost only (what CostSnapshots holds): marketplace,
# support and most reservation purchases have no resource and so no owner. Callers say so.
# ============================================================================

$script:DefaultTagKeys = @('owner', 'costcenter', 'environment', 'application')
$script:Untagged = '(untagged)'
$script:Gone = '(resource no longer exists)'

# 'Cost-Center', 'cost_center', 'CostCenter' -> 'costcenter'.
function ConvertTo-TagKeyNorm {
    param([string]$Key)
    return (([string]$Key).ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# The configured allocation tag keys as written, in order: PortalConfig settings/current
# AllocationTagKeys (set through SavePortalConfig), else the ALLOCATION_TAG_KEYS app setting (the
# deploy parameter allocationTagKeys), else the defaults. The FIRST key is the one that says who is
# responsible: it is the "owner" shown on every finding and in the brief.
function Get-AllocationTagSetting {
    param([string]$StorageToken)
    if ($StorageToken) {
        try {
            $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1
            if ($row -and $row.AllocationTagKeys) { return [string]$row.AllocationTagKeys }
        } catch { Write-Host "allocation tag keys read failed (using the app setting or defaults): $($_.Exception.Message)" }
    }
    if ($env:ALLOCATION_TAG_KEYS) { return [string]$env:ALLOCATION_TAG_KEYS }
    return ($script:DefaultTagKeys -join ',')
}

function Get-AllocationTagKeys {
    param([string]$StorageToken)
    $keys = @(([string](Get-AllocationTagSetting -StorageToken $StorageToken)) -split '[,;]' | ForEach-Object { ConvertTo-TagKeyNorm $_ } | Where-Object { $_ } | Select-Object -Unique -First 6)
    if ($keys.Count) { return $keys }
    return $script:DefaultTagKeys
}

# Display names for the tag keys, from the names as configured: 'ServiceLead' -> 'Service
# lead', 'cost-center' -> 'Cost center'. Normalised key -> label.
function Get-AllocationTagLabels {
    param([string]$StorageToken)
    $labels = [ordered]@{}
    foreach ($raw in @(([string](Get-AllocationTagSetting -StorageToken $StorageToken)) -split '[,;]')) {
        $name = ([string]$raw).Trim()
        $k = ConvertTo-TagKeyNorm $name
        if (-not $k -or $labels.Contains($k)) { continue }
        $words = (($name -creplace '([a-z0-9])([A-Z])', '$1 $2') -replace '[_\-.:]+', ' ' -replace '\s+', ' ').Trim()
        $labels[$k] = if ($words -ceq $words.ToLowerInvariant() -or $words -ceq $words.ToUpperInvariant() -or $words -match ' ') {
            $w = $words.ToLowerInvariant(); $w.Substring(0, 1).ToUpperInvariant() + $w.Substring(1)
        } else { $words }
    }
    return $labels
}

# Tag VALUES are messy too: 'Team-Payments', 'team-payments ' and 'payments' are one owner.
# Values are trimmed, inner whitespace collapsed and lower-cased — deterministic whichever subset
# of resources a timer reads — unless the alias map (PortalConfig AllocationValueAliases) names a
# canonical value, which is then used verbatim (so an admin can keep 'CC-100' as written).
#
# -Aliases: normalised tag key -> @{ lower-cased variant -> canonical } (ConvertTo-AllocationAliasMap).
function ConvertTo-TagValueNorm {
    param([string]$Value, [string]$Key, [hashtable]$Aliases)
    $v = (([string]$Value).Trim() -replace '\s+', ' ')
    if (-not $v) { return '' }
    $lower = $v.ToLowerInvariant()
    if ($Aliases -and $Key -and $Aliases.ContainsKey($Key) -and $Aliases[$Key].ContainsKey($lower)) { return [string]$Aliases[$Key][$lower] }
    return $lower
}

# The alias setting (JSON { "<tag key>": { "<variant>": "<canonical>" } }, or the parsed object)
# as the lookup ConvertTo-TagValueNorm uses. Canonical values map to themselves too, so a tag
# written 'cc-100' still lands on 'CC-100'. Bad input gives an empty map, never a throw.
function ConvertTo-AllocationAliasMap {
    param($Setting)
    $map = @{}
    if (-not $Setting) { return $map }
    try { $obj = if ($Setting -is [string]) { $Setting | ConvertFrom-Json -AsHashtable } else { $Setting } } catch { return $map }
    $pairsOf = { param($o) if ($o -is [System.Collections.IDictionary]) { @($o.GetEnumerator() | ForEach-Object { ,@($_.Key, $_.Value) }) } else { @($o.PSObject.Properties | ForEach-Object { ,@($_.Name, $_.Value) }) } }
    foreach ($kv in @(& $pairsOf $obj)) {
        $k = ConvertTo-TagKeyNorm $kv[0]
        if (-not $k -or $null -eq $kv[1]) { continue }
        if (-not $map.ContainsKey($k)) { $map[$k] = @{} }
        foreach ($vv in @(& $pairsOf $kv[1])) {
            $canonical = (([string]$vv[1]).Trim() -replace '\s+', ' ')
            $variant = (([string]$vv[0]).Trim() -replace '\s+', ' ').ToLowerInvariant()
            if (-not $canonical -or -not $variant) { continue }
            $map[$k][$variant] = $canonical
            $map[$k][$canonical.ToLowerInvariant()] = $canonical
        }
    }
    return $map
}

# The configured alias map (PortalConfig settings/current AllocationValueAliases); empty when unset.
function Get-AllocationValueAliases {
    param([string]$StorageToken)
    if (-not $StorageToken) { return @{} }
    try {
        $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1
        if ($row -and $row.AllocationValueAliases) { return (ConvertTo-AllocationAliasMap -Setting ([string]$row.AllocationValueAliases)) }
    } catch { Write-Host "allocation value aliases read failed (none used): $($_.Exception.Message)" }
    return @{}
}

# A tag object (Resource Graph returns a PSCustomObject; tests may pass a hashtable) as
# normalised-key -> normalised value.
function ConvertTo-NormalisedTags {
    param($Tags, [hashtable]$Aliases)
    $out = @{}
    if ($null -eq $Tags) { return $out }
    $pairs = if ($Tags -is [System.Collections.IDictionary]) { $Tags.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = $_.Value } } }
             else { $Tags.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Value = $_.Value } } }
    foreach ($p in $pairs) {
        $k = ConvertTo-TagKeyNorm $p.Name
        $v = ConvertTo-TagValueNorm -Value ([string]$p.Value) -Key $k -Aliases $Aliases
        if ($k -and $v -and -not $out.ContainsKey($k)) { $out[$k] = $v }
    }
    return $out
}

# Resource group id ('/subscriptions/<id>/resourcegroups/<rg>', lower-case) from any resource id.
function Get-ResourceGroupId {
    param([string]$ResourceId)
    if ([string]$ResourceId -match '(?i)^(/subscriptions/[0-9a-f-]{36}/resourcegroups/[^/]+)') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Invoke-AllocationGraphQuery {
    param([Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds)
    $results = @()
    $skipToken = $null
    do {
        $options = @{ '$top' = 1000 }
        if ($skipToken) { $options['$skipToken'] = $skipToken }
        $body = @{ subscriptions = @($SubscriptionIds); query = $Query; options = $options } | ConvertTo-Json -Depth 6
        $resp = Invoke-RestMethod -Method POST `
            -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
            -Headers @{ Authorization = "Bearer $MgmtToken" } -Body $body -ContentType 'application/json'
        if ($resp.data) { $results += @($resp.data) }
        $skipToken = $resp.'$skipToken'
    } while ($skipToken)
    return @($results)
}

# lower(resourceId) -> @{ Tags = normalised tags (resource's own, else its group's) }, plus the
# groups themselves under their own ids. -ResourceIds limits the resource query to those ids (in
# chunks); without it every resource is read. Never throws: a failure returns what was read and
# the caller shows the rest as untagged.
function Get-ResourceTagIndex {
    param(
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [string[]]$ResourceIds,
        [hashtable]$Aliases
    )
    $index = @{}
    if (-not $SubscriptionIds.Count) { return $index }
    $rgTags = @{}
    try {
        foreach ($g in @(Invoke-AllocationGraphQuery -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query @"
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| project id = tolower(id), tags
"@)) { $rgTags[[string]$g.id] = ConvertTo-NormalisedTags -Tags $g.tags -Aliases $Aliases }
    } catch { Write-Host "  resource-group tag read failed: $($_.Exception.Message)" }

    $rows = @()
    try {
        if ($ResourceIds) {
            $ids = @($ResourceIds | Where-Object { $_ -match '(?i)/providers/' } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
            for ($i = 0; $i -lt $ids.Count; $i += 100) {
                $chunk = @($ids[$i..([Math]::Min($i + 99, $ids.Count - 1))])
                $list = ($chunk | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
                $rows += @(Invoke-AllocationGraphQuery -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query "resources | where tolower(id) in ($list) | project id = tolower(id), tags")
            }
        } else {
            $rows = @(Invoke-AllocationGraphQuery -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query 'resources | project id = tolower(id), tags')
        }
    } catch { Write-Host "  resource tag read failed: $($_.Exception.Message)" }

    foreach ($r in $rows) {
        $own = ConvertTo-NormalisedTags -Tags $r.tags -Aliases $Aliases
        $rg = Get-ResourceGroupId -ResourceId ([string]$r.id)
        # Inherit from the resource group key by key: a resource tagged with an application but
        # not an owner still gets its group's owner.
        if ($rg -and $rgTags.ContainsKey($rg)) {
            foreach ($k in $rgTags[$rg].Keys) { if (-not $own.ContainsKey($k)) { $own[$k] = $rgTags[$rg][$k] } }
        }
        $index[[string]$r.id] = @{ Tags = $own; Exists = $true }
    }
    foreach ($k in $rgTags.Keys) { if (-not $index.ContainsKey($k)) { $index[$k] = @{ Tags = $rgTags[$k]; Exists = $true } } }
    return $index
}

# The allocation of one resource: an ordered map of each tag key to its value, plus the
# resource group. A resource missing from the index is reported as gone rather than untagged.
function Get-ResourceAllocation {
    param([hashtable]$Index, [string]$ResourceId, [string[]]$TagKeys)
    # Nothing could be read (Resource Graph failed): unknown, not "untagged" or "gone".
    if (-not $Index -or -not $Index.Count) { return $null }
    $id = ([string]$ResourceId).ToLowerInvariant()
    $entry = if ($Index) { $Index[$id] } else { $null }
    if (-not $entry) {
        # Not a resource we could read — use its group's tags if the group still exists.
        $rg = Get-ResourceGroupId -ResourceId $id
        if ($rg -and $Index -and $Index[$rg]) { $entry = @{ Tags = $Index[$rg].Tags; Exists = $false } }
    }
    $out = [ordered]@{}
    foreach ($k in $TagKeys) {
        $out[$k] = if ($entry -and $entry.Tags.ContainsKey($k)) { [string]$entry.Tags[$k] }
                   elseif ($entry) { $script:Untagged }
                   else { $script:Gone }
    }
    $rgId = Get-ResourceGroupId -ResourceId $id
    $out['resourceGroup'] = if ($rgId) { ($rgId -split '/')[-1] } else { '' }
    return $out
}

# Compact JSON of the allocation for a stored row ('' when there is nothing to say).
function ConvertTo-AllocationJson {
    param($Allocation)
    if (-not $Allocation) { return '' }
    return ($Allocation | ConvertTo-Json -Compress)
}

# ----------------------------------------------------------------------------
# Measure-AllocationRollup — pure.
#
# -PerResource: lower(resourceId) -> @{ Current; PreviousSameDays; PreviousMonth; SubscriptionId }
#   (USD; Current = this month to the settled day, PreviousSameDays = the same days of last
#   month, PreviousMonth = the whole of last month).
# Returns an ordered map dimension -> rows, where dimension is 'tag:<key>' for every tag key and
# 'resourceGroup'. Each row: { key; label; subscriptionId; currentUsd; previousSameDaysUsd;
# previousMonthUsd; deltaUsd; deltaPct; sharePct; resources }. Sorted by currentUsd, largest first.
# ----------------------------------------------------------------------------
function Measure-AllocationRollup {
    param(
        [Parameter(Mandatory)][hashtable]$PerResource,
        [hashtable]$Index,
        [Parameter(Mandatory)][string[]]$TagKeys,
        [hashtable]$SubscriptionNames = @{}
    )
    $dims = [ordered]@{}
    foreach ($k in $TagKeys) { $dims["tag:$k"] = @{} }
    $dims['resourceGroup'] = @{}
    $total = 0.0

    foreach ($id in $PerResource.Keys) {
        $c = $PerResource[$id]
        $total += [double]$c.Current
        $alloc = Get-ResourceAllocation -Index $Index -ResourceId $id -TagKeys $TagKeys
        if (-not $alloc) { $alloc = @{}; foreach ($k in $TagKeys) { $alloc[$k] = '(tags unavailable)' } }
        $rgId = Get-ResourceGroupId -ResourceId $id
        foreach ($dim in @($dims.Keys)) {
            if ($dim -eq 'resourceGroup') {
                if (-not $rgId) { continue }
                $key = $rgId
                $sid = ($rgId -split '/')[2]
                $subName = if ($SubscriptionNames[$sid]) { $SubscriptionNames[$sid] } else { $sid }
                $label = "$(($rgId -split '/')[-1]) ($subName)"
            } else {
                $key = [string]$alloc[$dim.Substring(4)]
                $label = $key
                $sid = ''
            }
            $bucket = $dims[$dim]
            if (-not $bucket.ContainsKey($key)) {
                $bucket[$key] = [ordered]@{ key = $key; label = $label; subscriptionId = $sid; currentUsd = 0.0; previousSameDaysUsd = 0.0; previousMonthUsd = 0.0; resources = 0 }
            }
            $b = $bucket[$key]
            $b.currentUsd += [double]$c.Current
            $b.previousSameDaysUsd += [double]$c.PreviousSameDays
            $b.previousMonthUsd += [double]$c.PreviousMonth
            if ([double]$c.Current -gt 0) { $b.resources++ }
        }
    }

    $out = [ordered]@{}
    foreach ($dim in $dims.Keys) {
        $out[$dim] = @($dims[$dim].Values | ForEach-Object {
            $cur = [Math]::Round([double]$_.currentUsd, 2); $prev = [Math]::Round([double]$_.previousSameDaysUsd, 2)
            [PSCustomObject]@{
                key = $_.key; label = $_.label; subscriptionId = $_.subscriptionId
                currentUsd = $cur; previousSameDaysUsd = $prev; previousMonthUsd = [Math]::Round([double]$_.previousMonthUsd, 2)
                deltaUsd = [Math]::Round($cur - $prev, 2)
                deltaPct = if ($prev -gt 0) { [Math]::Round((($cur - $prev) / $prev) * 100, 1) } else { $null }
                sharePct = if ($total -gt 0) { [Math]::Round(($cur / $total) * 100, 1) } else { 0 }
                resources = $_.resources
            }
        } | Where-Object { $_.currentUsd -gt 0 -or $_.previousSameDaysUsd -gt 0 -or $_.previousMonthUsd -gt 0 } |
            Sort-Object -Property @{ Expression = 'currentUsd'; Descending = $true }, @{ Expression = 'previousMonthUsd'; Descending = $true })
    }
    return $out
}

# ----------------------------------------------------------------------------
# Measure-AllocationStatement — pure. The monthly statement per owner / cost centre / … value.
#
# -PerResource: lower(resourceId) -> @{ LastMonth; MonthBefore; Meters = @{ meter -> @(last, before) } }
#   (USD, the last COMPLETE month and the one before it).
# -Savings: open, totalled savings (Get-BriefSavings items: id, title, resourceId, resourceName,
#   monthlyUsd, source, tier). Mapped to a value through the resource's tags; savings with no
#   resource belong to nobody and are left out.
# -BilledUsd: the month's billed total (dailytotal), or $null when unknown. What it holds beyond
#   the resource-attributed sum is SHARED spend (marketplace, support, reservation and
#   savings-plan purchases) — shown separately, never spread across owners.
#
# Returns @{ reconciliation; dims = ordered 'tag:<key>' -> @{ index = rows; statements = key -> statement } }.
# Untagged, gone and unreadable spend stay rows of their own ('(…)' keys) so the page can list
# them apart from the owners. Everything is sorted largest first.
# ----------------------------------------------------------------------------
function Measure-AllocationStatement {
    param(
        [Parameter(Mandatory)][hashtable]$PerResource,
        [hashtable]$Index,
        [Parameter(Mandatory)][string[]]$TagKeys,
        [object[]]$Savings = @(),
        $BilledUsd = $null,
        [int]$TopServices = 8,
        [int]$TopResources = 10,
        [int]$TopSavings = 5
    )
    $attributed = 0.0; $attributedPrev = 0.0
    foreach ($e in $PerResource.Values) { $attributed += [double]$e.LastMonth; $attributedPrev += [double]$e.MonthBefore }
    $billed = if ($null -ne $BilledUsd) { [double]$BilledUsd } else { $null }
    # The bill is the denominator for shares when known, so owners + untagged + shared = 100%.
    $denominator = if ($null -ne $billed -and $billed -ge $attributed) { $billed } else { $attributed }

    $allocOf = @{}
    $valueOf = {
        param([string]$Id, [string]$Key)
        if (-not $allocOf.ContainsKey($Id)) { $allocOf[$Id] = Get-ResourceAllocation -Index $Index -ResourceId $Id -TagKeys $TagKeys }
        $a = $allocOf[$Id]
        if ($a) { [string]$a[$Key] } else { '(tags unavailable)' }
    }

    $dims = [ordered]@{}
    foreach ($k in $TagKeys) {
        $groups = @{}
        foreach ($id in $PerResource.Keys) {
            $c = $PerResource[$id]
            if ([double]$c.LastMonth -eq 0 -and [double]$c.MonthBefore -eq 0) { continue }
            $v = & $valueOf $id $k
            if (-not $groups.ContainsKey($v)) { $groups[$v] = @{ total = 0.0; prev = 0.0; resources = 0; services = @{}; items = [System.Collections.Generic.List[object]]::new(); savings = [System.Collections.Generic.List[object]]::new() } }
            $g = $groups[$v]
            $g.total += [double]$c.LastMonth
            $g.prev += [double]$c.MonthBefore
            if ([double]$c.LastMonth -gt 0) { $g.resources++ }
            $g.items.Add([PSCustomObject]@{ resourceId = $id; usd = [double]$c.LastMonth; previousUsd = [double]$c.MonthBefore })
            if ($c.Meters) {
                foreach ($m in $c.Meters.Keys) {
                    $name = if ($m) { [string]$m } else { '(no meter)' }
                    if (-not $g.services.ContainsKey($name)) { $g.services[$name] = @(0.0, 0.0) }
                    $g.services[$name][0] += [double]$c.Meters[$m][0]
                    $g.services[$name][1] += [double]$c.Meters[$m][1]
                }
            }
        }
        foreach ($s in @($Savings)) {
            if ([string]$s.resourceId -notmatch '(?i)/providers/') { continue }
            $v = & $valueOf (([string]$s.resourceId).ToLowerInvariant()) $k
            if (-not $groups.ContainsKey($v)) { $groups[$v] = @{ total = 0.0; prev = 0.0; resources = 0; services = @{}; items = [System.Collections.Generic.List[object]]::new(); savings = [System.Collections.Generic.List[object]]::new() } }
            $groups[$v].savings.Add($s)
        }

        $statements = @{}
        $indexRows = foreach ($v in $groups.Keys) {
            $g = $groups[$v]
            $total = [Math]::Round($g.total, 2); $prev = [Math]::Round($g.prev, 2)
            $svc = @($g.services.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ name = $_.Key; usd = [Math]::Round($_.Value[0], 2); previousUsd = [Math]::Round($_.Value[1], 2) } } |
                Where-Object { $_.usd -gt 0 -or $_.previousUsd -gt 0 } | Sort-Object -Property @{ Expression = 'usd'; Descending = $true }, 'name')
            if ($svc.Count -gt $TopServices) {
                $rest = @($svc | Select-Object -Skip ($TopServices - 1))
                $svc = @($svc | Select-Object -First ($TopServices - 1)) + [PSCustomObject]@{
                    name = "Other ($($rest.Count))"
                    usd = [Math]::Round((($rest | Measure-Object -Property usd -Sum).Sum), 2)
                    previousUsd = [Math]::Round((($rest | Measure-Object -Property previousUsd -Sum).Sum), 2)
                }
            }
            $top = @($g.items | Sort-Object -Property @{ Expression = 'usd'; Descending = $true }, 'resourceId' | Select-Object -First $TopResources | ForEach-Object {
                [PSCustomObject]@{ resourceId = $_.resourceId; usd = [Math]::Round($_.usd, 2); previousUsd = [Math]::Round($_.previousUsd, 2); deltaUsd = [Math]::Round($_.usd - $_.previousUsd, 2) }
            })
            $open = 0.0; foreach ($s in $g.savings) { $open += [double]$s.monthlyUsd }
            $sv = @($g.savings | Sort-Object -Property @{ Expression = { [double]$_.monthlyUsd }; Descending = $true } | Select-Object -First $TopSavings | ForEach-Object {
                [PSCustomObject]@{ id = [string]$_.id; title = [string]$_.title; resourceId = [string]$_.resourceId; resourceName = [string]$_.resourceName
                    monthlyUsd = [Math]::Round([double]$_.monthlyUsd, 2); source = [string]$_.source; tier = [string]$_.tier }
            })
            # For untagged spend: the resource groups holding most of it. Tagging a group tags every
            # resource in it (resources inherit their group's tags), so this is the to-do list.
            $groupsToTag = @()
            if ($v -eq $script:Untagged) {
                $byRg = @{}
                foreach ($it in $g.items) {
                    $rgId = Get-ResourceGroupId -ResourceId $it.resourceId
                    if (-not $rgId) { continue }
                    if (-not $byRg.ContainsKey($rgId)) { $byRg[$rgId] = @{ usd = 0.0; resources = 0 } }
                    $byRg[$rgId].usd += $it.usd
                    if ($it.usd -gt 0) { $byRg[$rgId].resources++ }
                }
                $groupsToTag = @($byRg.GetEnumerator() | Where-Object { $_.Value.usd -gt 0 } | ForEach-Object {
                    [PSCustomObject]@{ resourceGroupId = $_.Key; name = ($_.Key -split '/')[-1]; usd = [Math]::Round($_.Value.usd, 2); resources = $_.Value.resources }
                } | Sort-Object -Property @{ Expression = 'usd'; Descending = $true }, 'resourceGroupId' | Select-Object -First 10)
            }
            $row = [PSCustomObject]@{
                key            = $v
                label          = $v
                totalUsd       = $total
                previousUsd    = $prev
                deltaUsd       = [Math]::Round($total - $prev, 2)
                deltaPct       = if ($prev -gt 0) { [Math]::Round((($total - $prev) / $prev) * 100, 1) } else { $null }
                sharePct       = if ($denominator -gt 0) { [Math]::Round(($total / $denominator) * 100, 1) } else { 0 }
                resources      = $g.resources
                openSavingsUsd = [Math]::Round($open, 2)
                savingsCount   = $g.savings.Count
                separate       = $v.StartsWith('(')
            }
            $statements[$v] = [PSCustomObject]@{
                key = $row.key; label = $row.label; totalUsd = $row.totalUsd; previousUsd = $row.previousUsd
                deltaUsd = $row.deltaUsd; deltaPct = $row.deltaPct; sharePct = $row.sharePct; resources = $row.resources
                openSavingsUsd = $row.openSavingsUsd; savingsCount = $row.savingsCount; separate = $row.separate
                byService = $svc; topResources = $top; savings = $sv; untaggedGroups = $groupsToTag
            }
            $row
        }
        # Tag coverage: the share of resource-attributed spend that carries a real value for this key.
        $tagged = 0.0; foreach ($r in @($indexRows)) { if (-not $r.separate) { $tagged += [double]$r.totalUsd } }
        $dims["tag:$k"] = @{
            coveragePct = if ($attributed -gt 0) { [Math]::Round(($tagged / $attributed) * 100, 1) } else { $null }
            index      = @($indexRows | Where-Object { $_.totalUsd -gt 0 -or $_.previousUsd -gt 0 -or $_.openSavingsUsd -gt 0 } |
                Sort-Object -Property @{ Expression = 'separate'; Descending = $false }, @{ Expression = 'totalUsd'; Descending = $true }, 'key')
            statements = $statements
        }
    }

    $shared = if ($null -ne $billed) { [Math]::Round([Math]::Max(0, $billed - $attributed), 2) } else { $null }
    return @{
        reconciliation = [PSCustomObject]@{
            billedUsd             = if ($null -ne $billed) { [Math]::Round($billed, 2) } else { $null }
            attributedUsd         = [Math]::Round($attributed, 2)
            attributedPreviousUsd = [Math]::Round($attributedPrev, 2)
            sharedUsd             = $shared
            sharedPct             = if ($null -ne $shared -and $denominator -gt 0) { [Math]::Round(($shared / $denominator) * 100, 1) } else { $null }
        }
        dims = $dims
    }
}

# ----------------------------------------------------------------------------
# Measure-AllocationDailySeries — pure. One month's spend per tag value, CUMULATIVE by day, so
# the statement trend can show "1st to day N" of any month whatever day it is read on.
#
# -PerResourceDaily: lower(resourceId) -> double[] of the day's cost (USD), index 0 = the 1st.
# -Days: how many days the series holds (the month's length, or the settled day so far).
# Values resolve exactly as in Measure-AllocationStatement (resource-group inheritance,
# '(untagged)', '(resource no longer exists)', '(tags unavailable)').
# Returns ordered 'tag:<key>' -> @{ value -> double[] cumulative, rounded to cents }.
# ----------------------------------------------------------------------------
function Measure-AllocationDailySeries {
    param(
        [Parameter(Mandatory)][hashtable]$PerResourceDaily,
        [hashtable]$Index,
        [Parameter(Mandatory)][string[]]$TagKeys,
        [Parameter(Mandatory)][int]$Days
    )
    $allocOf = @{}
    $dims = [ordered]@{}
    foreach ($k in $TagKeys) {
        $sums = @{}
        foreach ($id in $PerResourceDaily.Keys) {
            $daily = $PerResourceDaily[$id]
            if (-not $allocOf.ContainsKey($id)) { $allocOf[$id] = Get-ResourceAllocation -Index $Index -ResourceId $id -TagKeys $TagKeys }
            $a = $allocOf[$id]
            $v = if ($a) { [string]$a[$k] } else { '(tags unavailable)' }
            if (-not $sums.ContainsKey($v)) { $sums[$v] = [double[]]::new($Days) }
            $s = $sums[$v]
            for ($i = 0; $i -lt $Days -and $i -lt $daily.Count; $i++) { $s[$i] += [double]$daily[$i] }
        }
        $series = @{}
        foreach ($v in $sums.Keys) {
            $run = 0.0
            $series[$v] = @(foreach ($x in $sums[$v]) { $run += $x; [Math]::Round($run, 2) })
        }
        $dims["tag:$k"] = $series
    }
    return $dims
}

# ----------------------------------------------------------------------------
# RESOURCE COST INDEX — every resource's cost this month and last month, for questions.
#
# Cost Management cannot answer management-group questions for CSP / MCA subscriptions, and
# asking 40+ subscriptions one by one is too slow for a question someone is waiting on. The
# nightly allocation pass already adds up each resource's cost from the stored snapshots, so it
# writes that out too: CostSummary, PartitionKey 'resourcecost', RowKey 'meta' plus chunks
# 'c0000', 'c0001', … each holding up to ~120 resources as compact arrays
#   [ resourceId, currentUsd, previousSameDaysUsd, previousMonthUsd, monthBeforeUsd|null, owner ]
# Resource-attributed cost only (purchases and charges not tied to a resource are not in it).
# ----------------------------------------------------------------------------
function Write-ResourceCostIndex {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][hashtable]$PerResource,
        [hashtable]$MonthBefore,
        [hashtable]$Index,
        [string]$OwnerKey,
        [Parameter(Mandatory)][datetime]$Month,
        [Parameter(Mandatory)][datetime]$SettledThrough,
        [Parameter(Mandatory)][datetime]$PreviousSameDaysThrough,
        [string]$ScopeHash
    )
    $items = foreach ($id in $PerResource.Keys) {
        $e = $PerResource[$id]
        $mb = if ($MonthBefore -and $MonthBefore.ContainsKey($id)) { [Math]::Round([double]$MonthBefore[$id].MonthBefore, 4) } elseif ($MonthBefore) { 0.0 } else { $null }
        $owner = ''
        if ($OwnerKey) { $a = Get-ResourceAllocation -Index $Index -ResourceId $id -TagKeys @($OwnerKey); if ($a) { $owner = [string]$a[$OwnerKey] } }
        , @([string]$id, [Math]::Round([double]$e.Current, 4), [Math]::Round([double]$e.PreviousSameDays, 4), [Math]::Round([double]$e.PreviousMonth, 4), $mb, $owner)
    }
    $chunks = [System.Collections.Generic.List[string]]::new()
    $batch = [System.Collections.Generic.List[object]]::new(); $len = 2
    foreach ($it in @($items)) {
        $j = ConvertTo-Json -InputObject $it -Compress
        if ($batch.Count -and ($len + $j.Length + 1) -gt 28000) {
            $chunks.Add((ConvertTo-Json -InputObject @($batch) -Compress -Depth 4)); $batch.Clear(); $len = 2
        }
        $batch.Add($it); $len += $j.Length + 1
    }
    if ($batch.Count) { $chunks.Add((ConvertTo-Json -InputObject @($batch) -Compress -Depth 4)) }
    $now = [datetime]::UtcNow.ToString('o')
    $entities = @(for ($i = 0; $i -lt $chunks.Count; $i++) { @{ PartitionKey = 'resourcecost'; RowKey = ('c{0:d4}' -f $i); RowsJson = $chunks[$i] } })
    $entities += @{
        PartitionKey = 'resourcecost'; RowKey = 'meta'; Chunks = $chunks.Count; Resources = $PerResource.Count
        Month = $Month.ToString('yyyy-MM'); PreviousMonth = $Month.AddMonths(-1).ToString('yyyy-MM')
        MonthBeforeKnown = [bool]$MonthBefore; OwnerKey = [string]$OwnerKey
        SettledThrough = $SettledThrough.ToString('yyyy-MM-dd'); PreviousSameDaysThrough = $PreviousSameDaysThrough.ToString('yyyy-MM-dd')
        ScopeHash = $ScopeHash; SyncedAt = $now
    }
    Set-TableEntityBatch -Table 'CostSummary' -Entities $entities -Token $Token
    # Chunks left over from a night with more resources.
    try {
        $stale = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'resourcecost'" -Select 'PartitionKey,RowKey' -Token $Token |
            Where-Object { [string]$_.RowKey -like 'c*' -and [int](([string]$_.RowKey).Substring(1)) -ge $chunks.Count })
        if ($stale.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $stale -Token $Token }
    } catch { Write-Host "  resource cost index cleanup failed: $($_.Exception.Message)" }
    return $PerResource.Count
}

# Read the index: { Meta; Rows = [{ Id; Sub; Rg; Name; Current; PrevSame; PrevMonth; MonthBefore; Owner }] } or $null.
function Read-ResourceCostIndex {
    param([Parameter(Mandatory)][string]$Token)
    $all = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'resourcecost'" -Token $Token)
    $meta = @($all | Where-Object { $_.RowKey -eq 'meta' }) | Select-Object -First 1
    if (-not $meta) { return $null }
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($all | Where-Object { [string]$_.RowKey -like 'c*' } | Sort-Object RowKey)) {
        foreach ($a in @([string]$c.RowsJson | ConvertFrom-Json)) {
            $id = [string]$a[0]
            $rows.Add([PSCustomObject]@{
                Id = $id; Sub = (Get-RowSubscriptionId -Row $id); Rg = $(if ($id -match '(?i)/resourcegroups/([^/]+)') { $Matches[1] } else { '' })
                Name = ($id -split '/')[-1]
                Current = [double]$a[1]; PrevSame = [double]$a[2]; PrevMonth = [double]$a[3]
                MonthBefore = if ($null -ne $a[4]) { [double]$a[4] } else { $null }; Owner = [string]$a[5]
            })
        }
    }
    return [PSCustomObject]@{ Meta = $meta; Rows = $rows }
}

Export-ModuleMember -Function `
    Write-ResourceCostIndex, Read-ResourceCostIndex, `
    ConvertTo-TagKeyNorm, Get-AllocationTagKeys, ConvertTo-NormalisedTags, Get-ResourceGroupId, `
    ConvertTo-TagValueNorm, ConvertTo-AllocationAliasMap, Get-AllocationValueAliases, `
    Get-AllocationTagSetting, Get-AllocationTagLabels, `
    Get-ResourceTagIndex, Get-ResourceAllocation, ConvertTo-AllocationJson, Measure-AllocationRollup, `
    Measure-AllocationStatement, Measure-AllocationDailySeries
