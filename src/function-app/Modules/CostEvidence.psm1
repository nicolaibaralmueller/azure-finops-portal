# ============================================================================
# CostEvidence.psm1 — WHY did a cost change? Evidence first, explanation second.
#
# The first version of the product handed the model four numbers (typical, this period,
# increase, %) plus a resource type and asked it for "the likely cause". With nothing to go
# on it could only guess, and a guess with a confidence badge reads like analysis. This
# module fixes that by gathering the evidence DETERMINISTICALLY before any model is involved:
#
#   drivers        which meters (for one resource), resources (for a meter category) or
#                  services (for a subscription) moved, and each one's share of the increase.
#   volume / rate  for metered usage: did it use MORE (quantity), or did each unit COST more
#                  (SKU, tier or price change)? The split is exact — the two effects add up to
#                  the cost change of every meter that has a quantity in both windows.
#   changes        what the Azure change log recorded in and just before the window: creates,
#                  updates, deletes and actions (Activity Log, 90 days), and configuration
#                  diffs such as sku.name old -> new (Resource Graph change history, 14 days).
#   new resources  resources with cost now and none in the baseline.
#   owner          owner / cost-centre tags, so the recommendation can name who to ask.
#
# The evidence is stored with the finding and shown in the portal even with no AI at all —
# on its own it answers most "why" questions. When AI is configured, the model explains the
# change FROM that evidence and must cite the facts it used (Invoke-CostChangeExplanation).
#
# Rules carried over from the rest of the app:
#   - all arithmetic is here; the model never produces a figure, and is told not to write
#     currency amounts at all (the page renders them in the viewer's currency);
#   - every Azure call is best-effort; a failed step leaves a note, never an exception;
#   - identities are pseudonymised before anything leaves the tenant for the model.
#
# COST MANAGEMENT QUERIES carry ONE aggregation each. A request with two aggregations was seen
# on a live tenant to label its columns in one order and fill them in another (see
# Get-CostTotalsByPeriod in CostAnalysis.psm1), so cost and quantity are separate requests.
#
# Depends on CostAnalysis.psm1 (Invoke-CostQueryRest, Resolve-CostColumn, Test-NarrativeGrounding,
# Get-NarrationKey, ConvertTo-PseudonymousActor) and AiAdapter.psm1 (Invoke-AiCompletion,
# Test-AiBudgetExceeded). profile.ps1 imports all modules globally.
# ============================================================================

# 2: meter findings also carry subscription-level changes of the meter's provider (e.g. a
#    Defender plan switched on or off), which no single resource's Activity Log records.
# 3: meter findings break down by meter inside the category first (a rise spread over many
#    resources left only noise in a per-resource table), plus a 'spread' fact.
$script:EvidenceVersion = 3
function Get-CostEvidenceVersion { return [int]$script:EvidenceVersion }

# Meter categories whose cost is switched on and off at SUBSCRIPTION level, by a resource
# provider's own setting rather than by changing a resource — so the change is only in the
# subscription's Activity Log. Category (lower case) -> provider namespace.
$script:MeterProviderMap = @{
    'microsoft defender for cloud' = 'Microsoft.Security'
    'advanced threat protection'   = 'Microsoft.Security'
    'security center'              = 'Microsoft.Security'
    'microsoft sentinel'           = 'Microsoft.SecurityInsights'
    'sentinel'                     = 'Microsoft.SecurityInsights'
}
$script:EvidenceTimeMarker = 'EVIDENCE_TIME_BUDGET'

# Resource Graph keeps change history for 14 days; the Activity Log for 90.
$script:ResourceChangeHistoryDays = 14
$script:ActivityLogDays = 89

# Configuration paths worth reporting from a Resource Graph change. Everything else
# (etags, provisioning state, timestamps) is noise for a cost question.
$script:CostRelevantPathPattern = '(?i)(sku|tier|size|capacity|instancecount|replica|throughput|retention|autoscale|maxsize|family|vcores|dtu|storageprofile|accesstier|redundancy|kind)'
$script:NoisePathPattern = '(?i)(etag|provisioningstate|lastmodified|timecreated|changedtime|lastupdated|systemdata|statusof|powerstate)'

# Activity Log operations that say nothing about cost.
$script:NoiseOperationPattern = '(?i)(/read$|listkeys|/locks/|^microsoft\.authorization/|/diagnosticsettings/|^microsoft\.resources/tags/|/providers/microsoft\.insights/|regeneratekey|/listconnectionstrings|getaccesstoken)'

# ----------------------------------------------------------------------------
# Pure helpers
# ----------------------------------------------------------------------------

# Split a cost change into a VOLUME effect (more units at the old price) and a RATE effect
# (the price change applied to the new quantity). The two add up to the cost change exactly:
#   volume = (Qc - Qb) * Pb
#   rate   = (Pc - Pb) * Qc
#   volume + rate = Qc*Pc - Qb*Pb = Cc - Cb
# Returns $null when either window has no quantity — a meter that started or stopped has no
# unit price on one side, so the split is undefined (it shows up as a new/stopped driver instead).
function Measure-VolumeRateEffect {
    param(
        [double]$CurrentCost,
        [double]$BaselineCost,
        [double]$CurrentQuantity,
        [double]$BaselineQuantity
    )
    if ($CurrentQuantity -le 0 -or $BaselineQuantity -le 0) { return $null }
    $pB = $BaselineCost / $BaselineQuantity
    $pC = $CurrentCost / $CurrentQuantity
    return [PSCustomObject]@{
        VolumeUsd          = ($CurrentQuantity - $BaselineQuantity) * $pB
        RateUsd            = ($pC - $pB) * $CurrentQuantity
        QuantityChangePct  = (($CurrentQuantity - $BaselineQuantity) / $BaselineQuantity) * 100
        UnitPriceChangePct = if ($pB -gt 0) { (($pC - $pB) / $pB) * 100 } else { $null }
    }
}

# Bucket { Key; Date; Value } rows into the current window and the baseline windows.
# The baseline is the AVERAGE per baseline window (total / number of windows), so it is on the
# same footing as one current window. Detection itself uses the median of the windows; the
# evidence uses the mean because means ADD UP across drivers, and a breakdown whose parts do
# not sum to its total is worse than one on a slightly different basis. The basis is stated
# alongside the figures.
# Returns hashtable lower(key) -> { Key; Current; Baseline }.
function Measure-WindowTotals {
    param(
        $Rows,
        [Parameter(Mandatory)][datetime]$CurrentStart,
        [Parameter(Mandatory)][datetime]$CurrentEnd,
        [Parameter(Mandatory)]$BaselineRanges
    )
    $ranges = @($BaselineRanges)
    $n = [Math]::Max(1, $ranges.Count)
    $acc = @{}
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $d = ([datetime]$r.Date).Date
        $inCurrent = ($d -ge $CurrentStart.Date -and $d -le $CurrentEnd.Date)
        $inBaseline = $false
        if (-not $inCurrent) {
            foreach ($b in $ranges) { if ($d -ge ([datetime]$b.Start).Date -and $d -le ([datetime]$b.End).Date) { $inBaseline = $true; break } }
        }
        if (-not $inCurrent -and -not $inBaseline) { continue }

        $key = if ([string]::IsNullOrWhiteSpace([string]$r.Key)) { '(unattributed)' } else { [string]$r.Key }
        $kl = $key.ToLowerInvariant()
        if (-not $acc.ContainsKey($kl)) { $acc[$kl] = @{ Key = $key; Current = 0.0; BaselineTotal = 0.0 } }
        if ($inCurrent) { $acc[$kl].Current += [double]$r.Value } else { $acc[$kl].BaselineTotal += [double]$r.Value }
    }
    $out = @{}
    foreach ($kl in $acc.Keys) {
        $e = $acc[$kl]
        $out[$kl] = [PSCustomObject]@{ Key = $e.Key; Current = [double]$e.Current; Baseline = [double]$e.BaselineTotal / $n }
    }
    return $out
}

# Rank what moved. -Cost / -Quantity are Measure-WindowTotals outputs keyed the same way.
# Returns { Increases; Decreases; NetDeltaUsd; GrossIncreaseUsd; RisingCount; TopSharePct;
#           CurrentUsd; BaselineUsd; VolumeUsd; RateUsd; UnsplitUsd }.
# Increases carry SharePct = their share of the GROSS increase (all rising parts together), so
# the shares of the listed drivers can be read as "how much of the rise this explains".
# Increases smaller than 1% of the gross increase are dropped as noise.
function Get-ChangeDrivers {
    param(
        [Parameter(Mandatory)][hashtable]$Cost,
        [hashtable]$Quantity,
        [int]$TopIncreases = 6,
        [int]$TopDecreases = 2
    )
    $all = foreach ($kl in $Cost.Keys) {
        $c = $Cost[$kl]
        $delta = [double]$c.Current - [double]$c.Baseline
        $vr = $null
        if ($Quantity -and $Quantity.ContainsKey($kl)) {
            $q = $Quantity[$kl]
            $vr = Measure-VolumeRateEffect -CurrentCost $c.Current -BaselineCost $c.Baseline `
                -CurrentQuantity $q.Current -BaselineQuantity $q.Baseline
        }
        [PSCustomObject]@{
            Key                = $c.Key
            CurrentUsd         = [double]$c.Current
            BaselineUsd        = [double]$c.Baseline
            DeltaUsd           = $delta
            IsNew              = ([double]$c.Baseline -le 0 -and [double]$c.Current -gt 0)
            Stopped            = ([double]$c.Current -le 0 -and [double]$c.Baseline -gt 0)
            VolumeUsd          = if ($vr) { $vr.VolumeUsd } else { $null }
            RateUsd            = if ($vr) { $vr.RateUsd } else { $null }
            QuantityChangePct  = if ($vr) { $vr.QuantityChangePct } else { $null }
            UnitPriceChangePct = if ($vr) { $vr.UnitPriceChangePct } else { $null }
            SharePct           = $null
        }
    }
    $all = @($all)

    $gross = 0.0; $net = 0.0; $cur = 0.0; $base = 0.0; $vol = 0.0; $rate = 0.0; $split = 0.0
    foreach ($d in $all) {
        $net += $d.DeltaUsd; $cur += $d.CurrentUsd; $base += $d.BaselineUsd
        if ($d.DeltaUsd -gt 0) { $gross += $d.DeltaUsd }
        if ($null -ne $d.VolumeUsd) { $vol += $d.VolumeUsd; $rate += $d.RateUsd; $split += $d.DeltaUsd }
    }
    $noise = [Math]::Max(0.01, $gross * 0.01)
    $rising = 0; $topShare = 0.0
    foreach ($d in $all) {
        if ($d.DeltaUsd -gt 0 -and $gross -gt 0) {
            $d.SharePct = ($d.DeltaUsd / $gross) * 100
            $rising++
            if ($d.SharePct -gt $topShare) { $topShare = $d.SharePct }
        }
    }

    return [PSCustomObject]@{
        Increases        = @($all | Where-Object { $_.DeltaUsd -ge $noise } | Sort-Object DeltaUsd -Descending | Select-Object -First $TopIncreases)
        Decreases        = @($all | Where-Object { $_.DeltaUsd -le -$noise } | Sort-Object DeltaUsd | Select-Object -First $TopDecreases)
        NetDeltaUsd      = $net
        GrossIncreaseUsd = $gross
        # How thinly the rise is spread: how many parts rose at all, and the largest one's share.
        # A rise spread over many parts lists few drivers (each is below the noise floor), so the
        # page must say so instead of showing only the few that cleared it.
        RisingCount      = $rising
        TopSharePct      = $topShare
        CurrentUsd       = $cur
        BaselineUsd      = $base
        # Split only when at least one meter had a quantity on both sides. UnsplitUsd is the
        # part of the change that came from meters that started or stopped (no unit price on
        # one side), so VolumeUsd + RateUsd + UnsplitUsd = NetDeltaUsd.
        VolumeUsd        = if ($split -ne 0 -or $vol -ne 0 -or $rate -ne 0) { $vol } else { $null }
        RateUsd          = if ($split -ne 0 -or $vol -ne 0 -or $rate -ne 0) { $rate } else { $null }
        UnsplitUsd       = if ($split -ne 0 -or $vol -ne 0 -or $rate -ne 0) { $net - $vol - $rate } else { $null }
    }
}

# Owner-like tags from a Resource Graph tags object. Keys are matched loosely because every
# organisation spells them differently.
function Get-OwnerTags {
    param($Tags)
    $out = [ordered]@{}
    if (-not $Tags) { return $out }
    $props = if ($Tags -is [hashtable]) { $Tags.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = $_.Key; Value = $_.Value } } }
             else { $Tags.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; Value = $_.Value } } }
    # The configured allocation tags (e.g. ServiceLead) count as owner-like too.
    $configured = @(Get-AllocationTagKeys)
    foreach ($p in @($props | Sort-Object Name)) {
        if ((ConvertTo-TagKeyNorm ([string]$p.Name)) -in $configured -or [string]$p.Name -match '(?i)^(owner|owners|ownedby|technicalowner|businessowner|contact|team|costcent(er|re)|cost[-_ ]?cent(er|re)|department|project|application|app|environment|env)$') {
            $v = [string]$p.Value
            if ($v.Length -gt 120) { $v = $v.Substring(0, 120) }
            $out[[string]$p.Name] = $v
        }
    }
    return $out
}

# Subscription GUID from an ARM resource id or a bare GUID; $null otherwise.
function Get-SubscriptionIdFrom {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '^[0-9a-fA-F-]{36}$') { return $Value.ToLowerInvariant() }
    if ($Value -match '(?i)/subscriptions/([0-9a-f-]{36})') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Get-ColumnIndex {
    param($Columns, [string]$Name)
    $cols = @($Columns)
    for ($i = 0; $i -lt $cols.Count; $i++) { if ([string]$cols[$i] -ieq $Name) { return $i } }
    return -1
}

function Round2 { param($v) if ($null -eq $v) { return $null } return [Math]::Round([double]$v, 2) }
function Round1 { param($v) if ($null -eq $v) { return $null } return [Math]::Round([double]$v, 1) }

# ----------------------------------------------------------------------------
# Time budget. Evidence is secondary to detection, so it gets its own deadline: a throttled
# Cost Management API must not be able to eat the timer's 30 minutes (or an HTTP request's
# 230 seconds). Returns splat parameters for Invoke-CostQueryRest, or throws the time marker.
# ----------------------------------------------------------------------------
function Get-EvidenceQueryPolicy {
    param([Parameter(Mandatory)][datetime]$Deadline, [switch]$Interactive)
    $remaining = ($Deadline - [datetime]::UtcNow).TotalSeconds
    if ($remaining -lt 5) { throw "$($script:EvidenceTimeMarker): no time left for another query" }
    if ($Interactive) { return @{ MaxAttempts = 3; MaxWaitSeconds = 15; TimeoutSec = 45; BudgetSeconds = $remaining } }
    return @{ MaxAttempts = 3; MaxWaitSeconds = 30; TimeoutSec = 60; BudgetSeconds = $remaining }
}

# ----------------------------------------------------------------------------
# Get-GroupedCostSeries — one Cost Management query, one grouping, one aggregation.
# Returns rows { Key; Date; Value }. Throws on API error (callers turn it into a note).
# ----------------------------------------------------------------------------
function Get-GroupedCostSeries {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [ValidateSet('Daily', 'Monthly')][string]$Granularity = 'Daily',
        [Parameter(Mandatory)][string]$GroupBy,
        [ValidateSet('CostUSD', 'UsageQuantity')][string]$Aggregation = 'CostUSD',
        [hashtable]$Filter,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = 'AmortizedCost',
        [Parameter(Mandatory)][datetime]$Deadline,
        [switch]$Interactive
    )
    $dataset = @{
        granularity = $Granularity
        aggregation = @{ total = @{ name = $Aggregation; function = 'Sum' } }
        grouping    = @(@{ type = 'Dimension'; name = $GroupBy })
    }
    if ($Filter -and $Filter.Count) {
        $parts = @(foreach ($k in @($Filter.Keys | Sort-Object)) {
            @{ dimensions = @{ name = [string]$k; operator = 'In'; values = @($Filter[$k] | ForEach-Object { [string]$_ }) } }
        })
        $dataset.filter = if ($parts.Count -eq 1) { $parts[0] } else { @{ and = $parts } }
    }
    $body = @{
        type       = $CostType
        timeframe  = 'Custom'
        timePeriod = @{ from = $From.ToString('yyyy-MM-dd'); to = $To.ToString('yyyy-MM-dd') }
        dataset    = $dataset
    } | ConvertTo-Json -Depth 12

    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $rows = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    do {
        $policy = Get-EvidenceQueryPolicy -Deadline $Deadline -Interactive:$Interactive
        $resp = Invoke-CostQueryRest -Uri $uri -Token $MgmtToken -Body $body @policy
        $pages++
        $cols = @($resp.properties.columns.name)
        $iVal = Get-ColumnIndex $cols $Aggregation
        if ($iVal -lt 0 -and $Aggregation -eq 'CostUSD') { $iVal = (Resolve-CostColumn -Columns $cols -Context "evidence [$GroupBy]").Index }
        if ($iVal -lt 0 -and $Aggregation -eq 'UsageQuantity') { $iVal = Get-ColumnIndex $cols 'Quantity' }
        $iKey   = Get-ColumnIndex $cols $GroupBy
        $iDay   = Get-ColumnIndex $cols 'UsageDate'
        $iMonth = Get-ColumnIndex $cols 'BillingMonth'
        if ($iVal -lt 0 -or $iKey -lt 0) {
            throw "unexpected columns from Cost Management for $GroupBy/$Aggregation`: [$($cols -join ', ')]"
        }
        foreach ($r in $resp.properties.rows) {
            $date = $null
            if ($iDay -ge 0 -and $null -ne $r[$iDay]) {
                $raw = [string]$r[$iDay]
                if ($raw -match '^\d{8}$') { $date = [datetime]::ParseExact($raw, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) }
                else { $p = [datetime]::MinValue; if ([datetime]::TryParse($raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$p)) { $date = $p } }
            }
            if (-not $date -and $iMonth -ge 0 -and $null -ne $r[$iMonth]) {
                $p = [datetime]::MinValue
                if ([datetime]::TryParse([string]$r[$iMonth], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$p)) { $date = $p }
            }
            if (-not $date) { continue }
            $rows.Add([PSCustomObject]@{ Key = [string]$r[$iKey]; Date = $date.Date; Value = [double]$r[$iVal] })
        }
        $uri = $resp.properties.nextLink
    } while ($uri -and $pages -lt 20)
    return $rows.ToArray()
}

# ----------------------------------------------------------------------------
# Get-ActivityLogChanges — what the Activity Log recorded for one resource. 90-day retention,
# needs only Reader (no Log Analytics workspace). Returns
#   @({ time; resourceId; operation; action; actor })  newest last, at most -Max.
# Repeated identical operations on the same day collapse into one entry with a count.
# ----------------------------------------------------------------------------
# -ResourceProvider instead of -ResourceId: every operation of that provider in the subscription
# (-SubscriptionId), for settings that live at subscription level such as Defender plans.
function Get-ActivityLogChanges {
    param(
        [string]$ResourceId,
        [string]$SubscriptionId,
        [string]$ResourceProvider,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [Parameter(Mandatory)][string]$MgmtToken,
        [int]$Max = 10
    )
    if ($ResourceProvider) {
        $sub = Get-SubscriptionIdFrom $SubscriptionId
        if (-not $sub -or $ResourceProvider -notmatch '^[A-Za-z0-9.]+$') { return @() }
    } else {
        $sub = Get-SubscriptionIdFrom $ResourceId
        if (-not $sub -or $ResourceId -match "['""]") { return @() }
    }
    $floor = [datetime]::UtcNow.AddDays(-$script:ActivityLogDays)
    if ($From -lt $floor) { $From = $floor }
    if ($To -le $From) { return @() }

    $target = if ($ResourceProvider) { "resourceProvider eq '$ResourceProvider'" } else { "resourceUri eq '$ResourceId'" }
    $filter = "eventTimestamp ge '$($From.ToUniversalTime().ToString('o'))' and eventTimestamp le '$($To.ToUniversalTime().ToString('o'))' and $target"
    $select = 'eventTimestamp,operationName,resourceId,status,caller'
    $uri = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))&`$select=$([uri]::EscapeDataString($select))"

    $seen = [ordered]@{}
    $pages = 0
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" } -TimeoutSec 30
        $pages++
        foreach ($e in @($resp.value)) {
            if ([string]$e.status.value -ne 'Succeeded') { continue }
            $op = [string]$e.operationName.value
            if (-not $op -or $op -match $script:NoiseOperationPattern) { continue }
            $action = if ($op -match '(?i)/write$') { 'created or updated' }
                      elseif ($op -match '(?i)/delete$') { 'deleted' }
                      elseif ($op -match '(?i)/([^/]+)/action$') { $Matches[1] }
                      else { continue }
            $time = ([datetime]$e.eventTimestamp).ToUniversalTime()
            $k = "$($time.ToString('yyyy-MM-dd'))|$op"
            if ($seen.Contains($k)) { $seen[$k].count++; continue }
            $seen[$k] = [PSCustomObject]@{
                time       = $time.ToString('yyyy-MM-ddTHH:mmZ')
                resourceId = if ($e.resourceId) { [string]$e.resourceId } elseif ($ResourceId) { $ResourceId } else { "/subscriptions/$sub" }
                operation  = $op
                action     = $action
                actor      = (ConvertTo-PseudonymousActor -Upn ([string]$e.caller))
                count      = 1
            }
        }
        $uri = $resp.nextLink
    } while ($uri -and $pages -lt 5)

    return @($seen.Values | Sort-Object time | Select-Object -Last $Max)
}

# ----------------------------------------------------------------------------
# Get-ResourcePropertyChanges — configuration diffs from Resource Graph change history
# (14-day retention). Only cost-relevant paths are kept (SKU, tier, size, capacity, ...).
# Returns @({ time; resourceId; changeType; path; from; to }).
# ----------------------------------------------------------------------------
function Get-ResourcePropertyChanges {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To,
        [Parameter(Mandatory)][string]$MgmtToken,
        [int]$Max = 10
    )
    $sub = Get-SubscriptionIdFrom $ResourceId
    if (-not $sub -or $ResourceId -match "['""\\]") { return @() }
    $floor = [datetime]::UtcNow.AddDays(-$script:ResourceChangeHistoryDays)
    if ($From -lt $floor) { $From = $floor }
    if ($To -le $From) { return @() }

    $query = @"
resourcechanges
| extend ts = todatetime(properties.changeAttributes.timestamp), target = tostring(properties.targetResourceId), changeType = tostring(properties.changeType)
| where target =~ '$ResourceId' and ts between (datetime($($From.ToUniversalTime().ToString('o'))) .. datetime($($To.ToUniversalTime().ToString('o'))))
| project ts, changeType, changes = properties.changes
| order by ts asc
| take 50
"@
    $body = @{ subscriptions = @($sub); query = $query } | ConvertTo-Json -Depth 5
    $resp = Invoke-RestMethod -Method POST -TimeoutSec 30 `
        -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01' `
        -Headers @{ Authorization = "Bearer $MgmtToken" } -Body $body -ContentType 'application/json'

    $out = foreach ($row in @($resp.data)) {
        $time = ([datetime]$row.ts).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
        $type = [string]$row.changeType
        if ($type -in @('Create', 'Delete')) {
            [PSCustomObject]@{ time = $time; resourceId = $ResourceId; changeType = $type.ToLowerInvariant(); path = $null; from = $null; to = $null }
            continue
        }
        if (-not $row.changes) { continue }
        foreach ($p in $row.changes.PSObject.Properties) {
            $path = [string]$p.Name
            if ($path -notmatch $script:CostRelevantPathPattern -or $path -match $script:NoisePathPattern) { continue }
            $prev = [string]$p.Value.previousValue; $new = [string]$p.Value.newValue
            if ($prev -eq $new) { continue }
            if ($prev.Length -gt 80) { $prev = $prev.Substring(0, 80) + '…' }
            if ($new.Length -gt 80) { $new = $new.Substring(0, 80) + '…' }
            [PSCustomObject]@{ time = $time; resourceId = $ResourceId; changeType = 'update'; path = $path; from = $prev; to = $new }
        }
    }
    return @($out | Select-Object -Last $Max)
}

# ----------------------------------------------------------------------------
# New-EvidenceFacts — number every piece of evidence (F1, F2, ...) so the explanation can cite
# exactly what it relied on and the portal can show those facts next to it. Pure.
# ----------------------------------------------------------------------------
function New-EvidenceFacts {
    param(
        [string]$DriverKind,
        $Drivers,
        $ResourceDrivers,
        $NewResources,
        $PropertyChanges,
        $ActivityChanges,
        $OwnerTags,
        # Resource drivers below this share of the rise are left out (a meter finding lists its
        # meters first; a resource only earns a row when it carries a real part of the rise).
        [double]$ResourceMinSharePct = 0
    )
    $facts =[System.Collections.Generic.List[object]]::new()
    $add = {
        param($f)
        $f.Insert(0, 'id', "F$($facts.Count + 1)")
        $facts.Add([PSCustomObject]$f)
    }
    $driverFact = {
        param($d, [string]$kind, [string]$direction)
        $f = [ordered]@{
            kind = 'driver'; driverKind = $kind; direction = $direction; name = [string]$d.Key
            resourceId = if ($kind -eq 'resource') { [string]$d.Key } else { $null }
            currentUsd = (Round2 $d.CurrentUsd); baselineUsd = (Round2 $d.BaselineUsd); deltaUsd = (Round2 $d.DeltaUsd)
            sharePct = (Round1 $d.SharePct); isNew = [bool]$d.IsNew; stopped = [bool]$d.Stopped
        }
        if ($null -ne $d.QuantityChangePct) {
            $f.quantityChangePct = (Round1 $d.QuantityChangePct)
            $f.unitPriceChangePct = (Round1 $d.UnitPriceChangePct)
            $f.volumeUsd = (Round2 $d.VolumeUsd)
            $f.rateUsd = (Round2 $d.RateUsd)
        }
        & $add $f
    }

    if ($Drivers) {
        foreach ($d in @($Drivers.Increases)) { & $driverFact $d $DriverKind 'increase' }
        foreach ($d in @($Drivers.Decreases)) { & $driverFact $d $DriverKind 'decrease' }
        if ($null -ne $Drivers.VolumeUsd) {
            & $add ([ordered]@{
                kind = 'volume-rate'
                volumeUsd = (Round2 $Drivers.VolumeUsd); rateUsd = (Round2 $Drivers.RateUsd)
                newOrStoppedUsd = (Round2 $Drivers.UnsplitUsd); netDeltaUsd = (Round2 $Drivers.NetDeltaUsd)
            })
        }
    }
    if ($ResourceDrivers) {
        foreach ($d in @($ResourceDrivers.Increases | Where-Object { -not $_.IsNew -and [double]$_.SharePct -ge $ResourceMinSharePct } | Select-Object -First 5)) { & $driverFact $d 'resource' 'increase' }
        # A rise spread over several resources: say how many, and how big the largest part is.
        if ([int]$ResourceDrivers.RisingCount -ge 2 -and [double]$ResourceDrivers.GrossIncreaseUsd -gt 0) {
            & $add ([ordered]@{
                kind = 'spread'; resourceCount = [int]$ResourceDrivers.RisingCount
                topSharePct = (Round1 $ResourceDrivers.TopSharePct); grossIncreaseUsd = (Round2 $ResourceDrivers.GrossIncreaseUsd)
            })
        }
    }
    foreach ($n in @($NewResources)) {
        if ($null -eq $n) { continue }
        & $add ([ordered]@{ kind = 'new-resource'; resourceId = [string]$n.Key; name = [string]$n.Key; currentUsd = (Round2 $n.CurrentUsd) })
    }
    foreach ($c in @($PropertyChanges)) {
        if ($null -eq $c) { continue }
        & $add ([ordered]@{ kind = 'property-change'; time = $c.time; resourceId = $c.resourceId; changeType = $c.changeType; path = $c.path; from = $c.from; to = $c.to })
    }
    foreach ($c in @($ActivityChanges)) {
        if ($null -eq $c) { continue }
        & $add ([ordered]@{ kind = 'change'; time = $c.time; resourceId = $c.resourceId; operation = $c.operation; action = $c.action; actor = $c.actor; count = $c.count })
    }
    if ($OwnerTags -and $OwnerTags.Count) {
        & $add ([ordered]@{ kind = 'owner'; tags = [PSCustomObject]$OwnerTags })
    }
    return @($facts.ToArray())
}

# ----------------------------------------------------------------------------
# Get-CostChangeEvidence — gather everything above for ONE cost-change finding.
#
#   -Finding          object with Dimension ('resource'|'meter'|'subscription'), Scope
#                     (subscription GUID), ResourceId, Meter (meter CATEGORY), PeriodType
#   -CurrentStart/End the analysed window
#   -BaselineRanges   @(@{Start;End}, ...) — the windows it was compared against
#   -Granularity      'Daily' for rolling weeks, 'Monthly' for calendar months
#   -ResourceContext  Get-ResourceContext output (for owner tags), optional
#   -Deadline         UTC time after which no further Azure call is started
#
# Query cost: resource 2 Cost Management queries, meter 2, subscription 2; plus Activity Log /
# Resource Graph calls (a different, far less constrained API).
# Returns a JSON-ready ordered hashtable. Never throws: failures become notes and
# complete = $false.
# ----------------------------------------------------------------------------
function Get-CostChangeEvidence {
    param(
        [Parameter(Mandatory)]$Finding,
        [Parameter(Mandatory)][string]$MgmtToken,
        [Parameter(Mandatory)][datetime]$CurrentStart,
        [Parameter(Mandatory)][datetime]$CurrentEnd,
        [Parameter(Mandatory)]$BaselineRanges,
        [ValidateSet('Daily', 'Monthly')][string]$Granularity = 'Daily',
        $ResourceContext,
        [ValidateSet('ActualCost', 'AmortizedCost')][string]$CostType = 'AmortizedCost',
        [datetime]$Deadline = ([datetime]::UtcNow.AddMinutes(2)),
        [switch]$Interactive
    )
    $ranges = @($BaselineRanges | Sort-Object { [datetime]$_.Start })
    $dimension = if ($Finding.Dimension) { [string]$Finding.Dimension } else { 'resource' }
    $periodWord = if ($Finding.PeriodType -eq 'month') { 'month' } else { '7-day window' }
    $notes = [System.Collections.Generic.List[string]]::new()
    $complete = $true

    $ev = [ordered]@{
        version         = $script:EvidenceVersion
        dimension       = $dimension
        basis           = "Compared with the average of the $($ranges.Count) preceding $periodWord$(if ($ranges.Count -ne 1) { 's' }) (detection itself uses their median, so totals can differ slightly)."
        currentStart    = $CurrentStart.ToString('yyyy-MM-dd')
        currentEnd      = $CurrentEnd.ToString('yyyy-MM-dd')
        baselineStart   = if ($ranges.Count) { ([datetime]$ranges[0].Start).ToString('yyyy-MM-dd') } else { $null }
        baselineEnd     = if ($ranges.Count) { ([datetime]$ranges[-1].End).ToString('yyyy-MM-dd') } else { $null }
        baselinePeriods = $ranges.Count
        costType        = $CostType
        currentUsd      = $null
        baselineUsd     = $null
        netDeltaUsd     = $null
        facts           = @()
        complete        = $true
        notes           = @()
        gatheredAt      = [datetime]::UtcNow.ToString('o')
    }

    $sub = Get-SubscriptionIdFrom ([string]$Finding.Scope)
    if (-not $sub) { $sub = Get-SubscriptionIdFrom ([string]$Finding.ResourceId) }
    if (-not $sub -or -not $ranges.Count) {
        $ev.complete = $false
        $ev.notes = @('No subscription or baseline window to query, so no evidence could be gathered.')
        return $ev
    }

    $queryFrom = [datetime]$ranges[0].Start
    $common = @{
        SubscriptionId = $sub; MgmtToken = $MgmtToken; From = $queryFrom; To = $CurrentEnd
        Granularity = $Granularity; CostType = $CostType; Deadline = $Deadline; Interactive = $Interactive
    }
    $bucket = @{ CurrentStart = $CurrentStart; CurrentEnd = $CurrentEnd; BaselineRanges = $ranges }

    # Changes are looked for in the window itself and the week before it: a change made on the
    # last day of the baseline shows up as cost in the current window.
    $changeFrom = $CurrentStart.AddDays(-7)
    $changeTo = $CurrentEnd.AddDays(1)

    $drivers = $null; $resourceDrivers = $null; $newResources = @()
    $propertyChanges = @(); $activityChanges = @(); $owner = $null
    $changeTargets = @()

    # Runs one gathering step and returns its output; a failure becomes a note and $null.
    $state = @{ Incomplete = $false }
    $step = {
        param([string]$What, [scriptblock]$Body)
        try { return (& $Body) }
        catch {
            $msg = $_.Exception.Message
            $state.Incomplete = $true
            if ($msg -like "$($script:EvidenceTimeMarker)*") { $notes.Add("$What skipped: the evidence time budget ran out.") }
            elseif ($msg -like 'COST_QUERY_THROTTLED*') { $notes.Add("$What unavailable: Azure is rate-limiting cost queries.") }
            else {
                $notes.Add("$What unavailable.")
                Write-Host "  evidence: $What failed for $($Finding.ResourceId)$($Finding.Meter): $msg"
            }
            return $null
        }
    }

    switch ($dimension) {
        'resource' {
            $id = [string]$Finding.ResourceId
            $drivers = & $step 'Meter breakdown' {
                $filter = @{ ResourceId = @($id) }
                $costRows = Get-GroupedCostSeries @common -GroupBy 'Meter' -Aggregation 'CostUSD' -Filter $filter
                $costT = Measure-WindowTotals -Rows $costRows @bucket
                $qtyT = $null
                try {
                    $qtyRows = Get-GroupedCostSeries @common -GroupBy 'Meter' -Aggregation 'UsageQuantity' -Filter $filter
                    $qtyT = Measure-WindowTotals -Rows $qtyRows @bucket
                } catch {
                    $notes.Add('Usage quantities unavailable, so the change could not be split into volume and price.')
                    $state.Incomplete = $true
                }
                Get-ChangeDrivers -Cost $costT -Quantity $qtyT
            }
            $changeTargets = @($id)
            if ($ResourceContext -and $ResourceContext.tags) { $owner = Get-OwnerTags $ResourceContext.tags }
            $propertyChanges = @(& $step 'Configuration change history' {
                Get-ResourcePropertyChanges -ResourceId $id -From $changeFrom -To $changeTo -MgmtToken $MgmtToken -Max 8
            } | Where-Object { $_ })
        }
        'meter' {
            # A meter-category finding exists because no single resource explains the rise, so
            # the breakdown that answers "what moved" is by METER inside the category (e.g.
            # Defender "Standard P2 Node" vs "Standard Node"). The resources come second: the
            # spread, new resources, and any one resource that carries a real share.
            $meterFilter = @{ MeterCategory = @([string]$Finding.Meter) }
            $drivers = & $step 'Meter breakdown' {
                $costRows = Get-GroupedCostSeries @common -GroupBy 'Meter' -Aggregation 'CostUSD' -Filter $meterFilter
                Get-ChangeDrivers -Cost (Measure-WindowTotals -Rows $costRows @bucket) -TopIncreases 6 -TopDecreases 3
            }
            $resourceDrivers = & $step 'Resource breakdown' {
                $costRows = Get-GroupedCostSeries @common -GroupBy 'ResourceId' -Aggregation 'CostUSD' -Filter $meterFilter
                Get-ChangeDrivers -Cost (Measure-WindowTotals -Rows $costRows @bucket) -TopIncreases 8 -TopDecreases 0
            }
            if ($resourceDrivers) {
                $newResources = @($resourceDrivers.Increases | Where-Object { $_.IsNew } | Select-Object -First 5)
                $changeTargets = @($resourceDrivers.Increases | Where-Object { $_.Key -like '/subscriptions/*' } | Select-Object -First 3 | ForEach-Object { [string]$_.Key })
            }
        }
        'subscription' {
            $drivers = & $step 'Service breakdown' {
                $costRows = Get-GroupedCostSeries @common -GroupBy 'ServiceName' -Aggregation 'CostUSD'
                Get-ChangeDrivers -Cost (Measure-WindowTotals -Rows $costRows @bucket)
            }
            $resourceDrivers = & $step 'Resource breakdown' {
                $costRows = Get-GroupedCostSeries @common -GroupBy 'ResourceId' -Aggregation 'CostUSD'
                Get-ChangeDrivers -Cost (Measure-WindowTotals -Rows $costRows @bucket) -TopIncreases 15 -TopDecreases 0
            }
            if ($resourceDrivers) {
                $newResources = @($resourceDrivers.Increases | Where-Object { $_.IsNew } | Select-Object -First 5)
                $changeTargets = @($resourceDrivers.Increases | Where-Object { $_.Key -like '/subscriptions/*' } | Select-Object -First 3 | ForEach-Object { [string]$_.Key })
            }
        }
    }

    foreach ($t in $changeTargets) {
        $max = if ($dimension -eq 'resource') { 10 } else { 4 }
        $activityChanges += @(& $step 'Activity log' {
            if (([datetime]$Deadline - [datetime]::UtcNow).TotalSeconds -lt 5) { throw "$($script:EvidenceTimeMarker): no time left" }
            Get-ActivityLogChanges -ResourceId $t -From $changeFrom -To $changeTo -MgmtToken $MgmtToken -Max $max
        } | Where-Object { $_ })
    }
    # A meter switched on or off at subscription level (a Defender plan, say) is recorded against
    # the subscription's provider settings, not against any of the resources it bills.
    $provider = if ($dimension -eq 'meter' -and $Finding.Meter) { $script:MeterProviderMap[([string]$Finding.Meter).ToLowerInvariant()] } else { $null }
    if ($provider) {
        $activityChanges += @(& $step 'Subscription activity log' {
            if (([datetime]$Deadline - [datetime]::UtcNow).TotalSeconds -lt 5) { throw "$($script:EvidenceTimeMarker): no time left" }
            Get-ActivityLogChanges -SubscriptionId $sub -ResourceProvider $provider -From $changeFrom -To $changeTo -MgmtToken $MgmtToken -Max 6
        } | Where-Object { $_ })
    }
    if ($changeFrom -lt [datetime]::UtcNow.AddDays(-$script:ActivityLogDays)) {
        $notes.Add('Part of the window is older than the 90 days the Activity Log keeps, so earlier changes may be missing.')
    }
    if ($dimension -eq 'resource' -and $changeFrom -lt [datetime]::UtcNow.AddDays(-$script:ResourceChangeHistoryDays)) {
        $notes.Add('Configuration diffs (old -> new values) are only kept for 14 days; older changes appear as operations without values.')
    }

    if ($state.Incomplete) { $complete = $false }
    # De-duplicate notes, keep order.
    $uniqueNotes = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $notes) { if (-not $uniqueNotes.Contains($n)) { $uniqueNotes.Add($n) } }

    $totals = if ($drivers) { $drivers } else { $resourceDrivers }
    if ($totals) {
        $ev.currentUsd = Round2 $totals.CurrentUsd
        $ev.baselineUsd = Round2 $totals.BaselineUsd
        $ev.netDeltaUsd = Round2 $totals.NetDeltaUsd
    }
    $driverKind = switch ($dimension) { 'subscription' { 'service' } default { 'meter' } }
    $ev.facts = @(New-EvidenceFacts -DriverKind $driverKind -Drivers $drivers -ResourceDrivers $resourceDrivers `
        -NewResources $newResources -PropertyChanges $propertyChanges -ActivityChanges $activityChanges -OwnerTags $owner `
        -ResourceMinSharePct $(if ($dimension -eq 'meter') { 10 } else { 0 }))
    $ev.complete = $complete
    $ev.notes = @($uniqueNotes.ToArray())
    return $ev
}

# ----------------------------------------------------------------------------
# Set-EvidenceDailyShape — add (or replace) the 'daily-shape' fact: how the cost moved WITHIN
# the period, from the finding's ExitRunRateUsd / SteppedDownOn / DailyBeforeUsd /
# DailyAfterUsd / Resolved (DetectCostSpikes-Timer). Without it the evidence only has period
# totals and cannot tell "rose and stayed up" from "rose, then fell back mid-period".
# Removes the fact when the finding carries no shape. Works on the gathered hashtable and on
# evidence read back from storage.
# ----------------------------------------------------------------------------
function Set-EvidenceDailyShape {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$Finding)
    $facts = @(@($Evidence.facts) | Where-Object { $_ -and [string]$_.kind -ne 'daily-shape' })
    if ($null -ne $Finding.ExitRunRateUsd -and [double]$Finding.ExitRunRateUsd -ge 0) {
        $f = [ordered]@{
            id             = "F$($facts.Count + 1)"
            kind           = 'daily-shape'
            exitRunRateUsd = (Round2 $Finding.ExitRunRateUsd)
            resolved       = [bool]$Finding.Resolved
        }
        if ($Finding.SteppedDownOn) {
            $f.steppedDownOn = [string]$Finding.SteppedDownOn
            $f.dailyBeforeUsd = (Round2 $Finding.DailyBeforeUsd)
            $f.dailyAfterUsd = (Round2 $Finding.DailyAfterUsd)
        }
        # Where it stands NOW (the latest settled days, which for a closed month lie after it).
        $cur = $Finding.PSObject.Properties['CurrentDailyUsd']
        if ($cur -and $null -ne $cur.Value -and [string]$cur.Value -ne '' -and [double]$cur.Value -ge 0) {
            $f.state = [string]$Finding.State
            $f.currentDailyUsd = (Round2 $cur.Value)
            if ($Finding.CurrentAsOf) { $f.currentAsOf = [string]$Finding.CurrentAsOf }
            if ($f.state -eq 'resolved') { $f.resolved = $true }
        }
        $facts += [PSCustomObject]$f
    }
    $Evidence.facts = @($facts)
}

# Stamp display names onto facts that carry a resourceId. -NameMap: lower(id) -> name.
function Set-EvidenceResourceNames {
    param($Evidence, [hashtable]$NameMap)
    if (-not $Evidence -or -not $NameMap) { return }
    foreach ($f in @($Evidence.facts)) {
        if (-not $f.resourceId) { continue }
        $n = $NameMap[([string]$f.resourceId).ToLowerInvariant()]
        if (-not $n) { continue }
        if ($f.PSObject.Properties['resourceName']) { $f.resourceName = [string]$n }
        else { $f | Add-Member -NotePropertyName resourceName -NotePropertyValue ([string]$n) }
        if ($f.kind -in @('driver', 'new-resource') -and $f.driverKind -ne 'meter' -and $f.driverKind -ne 'service') { $f.name = [string]$n }
    }
}

# Every resource id mentioned in the evidence (for one batched name lookup).
function Get-EvidenceResourceIds {
    param($Evidence)
    if (-not $Evidence) { return @() }
    return @($Evidence.facts | Where-Object { $_.resourceId } | ForEach-Object { [string]$_.resourceId } | Sort-Object -Unique)
}

# ----------------------------------------------------------------------------
# EXPLANATION — the model reasons over the evidence, and must cite it.
# ----------------------------------------------------------------------------
function Get-CostChangeExplanationSystemPrompt {
    return Add-AiLanguageLine @'
You are a FinOps analyst explaining ONE Azure cost change to the people who pay the bill.

You receive the change itself (period, scope, and how much it rose — already calculated), the
resource it concerns when there is one, and EVIDENCE: numbered facts (F1, F2, ...) gathered
from billing data and the Azure change log. Fact kinds:
- driver: a meter, resource or service whose cost moved, with its share of the rise.
  quantityChangePct / unitPriceChangePct, when present, tell you whether it used MORE (volume)
  or became MORE EXPENSIVE per unit (rate: a SKU, tier or price change). isNew = it had no
  cost before; stopped = it has none now.
- volume-rate: the whole change split into a volume effect, a rate effect, and the part from
  meters that started or stopped.
- change: an operation recorded in the Activity Log (created or updated, deleted, or an action
  such as start / deallocate / scale), with its date. actor is pseudonymous.
- property-change: a recorded configuration change with its old and new value (e.g. sku.name).
- new-resource: a resource that had no cost in the baseline.
- owner: owner / cost-centre tags on the resource.
- daily-shape: how the cost moved WITHIN the period. exitRunRateUsd is the level the period
  ended at, scaled to a whole period. steppedDownOn, when present, is the day the daily cost
  fell from about dailyBeforeUsd to about dailyAfterUsd. resolved = true means the cost is back
  at a normal level: the total was higher, but the increase has already stopped. state and
  currentDailyUsd, when present, say where it stands now (as of currentAsOf): open, decreasing
  or resolved.
- spread: the rise is spread over resourceCount resources, the largest carrying topSharePct
  percent of it. A low topSharePct means no single resource caused it — look at the meters and
  at subscription-level changes instead.

When a daily-shape fact says resolved, lead with that: say the cost was high early in the
period and fell on steppedDownOn, connect it to any change recorded around that date (for
example a plan switched off), and keep the recommendation to confirming it stays down.

Write:
- headline: one line naming what drove the change.
- cause: the most likely cause, reasoned ONLY from the facts, in at most three sentences.
  Connect facts where they fit together (for example a SKU change dated just before the unit
  price rose). Put the ids of every fact you relied on in citedFacts.
- explained: true only when the cited facts account for the change. When the facts show WHERE
  the money went but nothing records WHY, set it to false, say what is known and what is not,
  and do not guess.
- recommendation: one concrete next step based on the facts — what to check or change, and who
  to ask when an owner is known.

Rules:
- Never write currency amounts; the page shows every amount next to your text in the reader's
  currency. Percentages taken from the facts are fine.
- Never mention resources, dates or changes that are not in the facts.
- period_type is a trailing "week" (7 days) or a complete calendar "month". Speak of it as a
  settled period, never as one still running.
- Plain language for a non-specialist. No preamble.
'@
}

# EVERY property must also appear in `required`. OpenAI's strict structured-output mode (which
# Invoke-OpenAiCompatible turns on whenever a schema is passed) rejects a schema that omits one:
# "'required' is required to be supplied and to be an array including every key in properties".
# That is an HTTP 400, which is permanent — the provider never even sees the payload — so a
# schema with an optional property silently costs every finding its explanation. Anything that
# genuinely may be absent is declared NULLABLE and required instead of being left out of the
# list. The same rule applies to every schema in the app (QueryCosts, the brief, ...).
function Get-CostChangeExplanationSchema {
    return @{
        type                 = 'object'
        additionalProperties = $false
        required             = @('headline', 'cause', 'citedFacts', 'explained', 'recommendation')
        properties           = @{
            headline       = @{ type = 'string'; description = 'One line naming what drove the change. No currency amounts.' }
            cause          = @{ type = 'string'; description = 'Most likely cause, from the facts only. No currency amounts.' }
            citedFacts     = @{ type = 'array'; items = @{ type = 'string' }; description = 'Ids (F1, F2, ...) of the facts the cause relies on.' }
            explained      = @{ type = 'boolean'; description = 'True only when the cited facts account for the change.' }
            recommendation = @{ type = 'string'; description = 'One concrete next step. No currency amounts.' }
        }
    }
}

# The user payload for one explanation. Figures are pre-computed and rounded here.
function Build-CostChangePayload {
    param([Parameter(Mandatory)]$Finding, $ResourceContext, $Evidence)
    $change = [ordered]@{
        period_type      = if ($Finding.PeriodType) { [string]$Finding.PeriodType } else { $null }
        period_start     = if ($Evidence) { $Evidence.currentStart } else { $null }
        period_end       = if ($Evidence) { $Evidence.currentEnd } else { $null }
        dimension        = if ($Finding.Dimension) { [string]$Finding.Dimension } else { 'resource' }
        subscription     = if ($Finding.ScopeName) { [string]$Finding.ScopeName } else { [string]$Finding.Scope }
        meter_category   = if ($Finding.Meter) { [string]$Finding.Meter } else { $null }
        resource_name    = if ($Finding.ResourceName) { [string]$Finding.ResourceName } else { $null }
        this_period_usd  = (Round2 $Finding.SpikeUsd)
        typical_usd      = (Round2 $Finding.BaselineUsd)
        increase_usd     = (Round2 $Finding.DeltaUsd)
        increase_pct     = if ($null -ne $Finding.DeltaPct) { [Math]::Round([double]$Finding.DeltaPct, 0) } else { $null }
        is_new_spend     = [bool]$Finding.IsNew
    }
    if ($null -ne $Finding.UnexplainedUsd) { $change.not_from_flagged_resources_usd = (Round2 $Finding.UnexplainedUsd) }
    if ($null -ne $Finding.ExitRunRateUsd -and [double]$Finding.ExitRunRateUsd -ge 0) {
        $change.period_end_level_usd = (Round2 $Finding.ExitRunRateUsd)
        $change.already_fell_back = [bool]$Finding.Resolved
        if ($Finding.SteppedDownOn) { $change.fell_on = [string]$Finding.SteppedDownOn }
    }
    $resource = if ($ResourceContext) {
        [ordered]@{ type = $ResourceContext.type; sku = $ResourceContext.sku; location = $ResourceContext.location }
    } else { $null }
    return [PSCustomObject]@{
        change   = [PSCustomObject]$change
        resource = if ($resource) { [PSCustomObject]$resource } else { $null }
        evidence = if ($Evidence) {
            [PSCustomObject]@{ basis = $Evidence.basis; complete = [bool]$Evidence.complete; notes = @($Evidence.notes); facts = @($Evidence.facts) }
        } else { $null }
    }
}

# ----------------------------------------------------------------------------
# Invoke-CostChangeExplanation — explain one finding from its evidence.
#
# Returns { Headline; Cause; Recommendation; CitedFacts; Explained; Grounded; NarrationKey;
#           Status } where Status is one of
#   'reused'           the stored explanation matches this exact request (no call made)
#   'explained'        a fresh explanation was produced
#   'no-evidence'      nothing to explain from — no call made, by design
#   'not-configured'   no AI provider
#   'budget-exceeded'  the daily AI call limit is reached
#   'skipped'          -ReuseOnly and nothing reusable was stored
#   'failed'           the provider call failed (Error carries the message)
# -StoredRow is the CostSpikes row for this finding, if any (for reuse).
# ----------------------------------------------------------------------------
function Invoke-CostChangeExplanation {
    param(
        [Parameter(Mandatory)]$Finding,
        $ResourceContext,
        $Evidence,
        $StoredRow,
        [string]$Purpose = 'cost-change-explanation',
        # Ignore a stored explanation even when the request is unchanged (admin re-explain).
        [switch]$Force,
        # Return a stored explanation when it still matches, but never call the provider
        # (used after the daily AI limit was hit earlier in the same run). Status 'skipped'.
        [switch]$ReuseOnly
    )
    $result = [ordered]@{
        Headline = $null; Cause = $null; Recommendation = $null; CitedFacts = @(); Explained = $false
        Grounded = $true; NarrationKey = $null; Status = 'no-evidence'; Error = $null
    }
    $facts = if ($Evidence) { @($Evidence.facts) } else { @() }
    if (-not $facts.Count) { return [PSCustomObject]$result }

    $sysPrompt = Get-CostChangeExplanationSystemPrompt
    $payload = Build-CostChangePayload -Finding $Finding -ResourceContext $ResourceContext -Evidence $Evidence
    # gatheredAt is not in the payload, so re-gathering identical evidence keeps the same key.
    $payloadJson = $payload | ConvertTo-Json -Depth 10
    $result.NarrationKey = Get-NarrationKey -SystemPrompt $sysPrompt -PayloadJson $payloadJson -Model $env:AI_MODEL

    if (-not $Force -and $StoredRow -and [string]$StoredRow.NarrationKey -eq $result.NarrationKey -and
        -not [string]::IsNullOrWhiteSpace([string]$StoredRow.Headline)) {
        $result.Headline = [string]$StoredRow.Headline
        $result.Cause = [string]$StoredRow.Cause
        $result.Recommendation = [string]$StoredRow.Recommendation
        $result.CitedFacts = @(if ($StoredRow.CitedFactsJson) { try { @([string]$StoredRow.CitedFactsJson | ConvertFrom-Json) } catch { @() } })
        $result.Explained = [bool]$StoredRow.Explained
        $result.Grounded = if ($null -ne $StoredRow.Grounded) { [bool]$StoredRow.Grounded } else { $true }
        $result.Status = 'reused'
        return [PSCustomObject]$result
    }

    if (-not (Test-AiConfigured)) {
        $result.Status = 'not-configured'
        return [PSCustomObject]$result
    }
    if ($ReuseOnly) {
        $result.Status = 'skipped'
        return [PSCustomObject]$result
    }

    try {
        $r = Invoke-AiCompletion -System $sysPrompt -User $payloadJson -Schema (Get-CostChangeExplanationSchema) -MaxTokens 700 -Purpose $Purpose
    } catch {
        if (Test-AiBudgetExceeded -ErrorRecord $_) { $result.Status = 'budget-exceeded' }
        else { $result.Status = 'failed' }
        $result.Error = $_.Exception.Message
        return [PSCustomObject]$result
    }

    if (-not $r.Parsed) {
        $result.Status = 'failed'
        $result.Error = 'the model did not return the expected structure'
        return [PSCustomObject]$result
    }

    $validIds = @{}
    foreach ($f in $facts) { $validIds[[string]$f.id] = $true }
    $cited = @(@($r.Parsed.citedFacts) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } |
        Where-Object { $validIds.ContainsKey($_) } | Select-Object -Unique)

    $result.Headline = [string]$r.Parsed.headline
    $result.Cause = [string]$r.Parsed.cause
    $result.Recommendation = [string]$r.Parsed.recommendation
    $result.CitedFacts = $cited
    # "Explained" without a single valid citation is a claim with nothing behind it.
    $result.Explained = ([bool]$r.Parsed.explained) -and $cited.Count -gt 0
    $result.Grounded = Test-NarrativeGrounding -Narrative "$($result.Headline) $($result.Cause) $($result.Recommendation)" -Payload $payload
    if (-not $result.Grounded) { Write-Host "  explanation for $($Finding.Id) quoted a number that is not in the payload — flagged." }
    $result.Status = 'explained'
    return [PSCustomObject]$result
}

Export-ModuleMember -Function `
    Measure-VolumeRateEffect, Measure-WindowTotals, Get-ChangeDrivers, Get-OwnerTags, `
    Get-GroupedCostSeries, Get-ActivityLogChanges, Get-ResourcePropertyChanges, `
    New-EvidenceFacts, Get-CostChangeEvidence, Set-EvidenceResourceNames, Get-EvidenceResourceIds, `
    Get-CostEvidenceVersion, Set-EvidenceDailyShape, `
    Get-CostChangeExplanationSystemPrompt, Get-CostChangeExplanationSchema, Build-CostChangePayload, `
    Invoke-CostChangeExplanation
