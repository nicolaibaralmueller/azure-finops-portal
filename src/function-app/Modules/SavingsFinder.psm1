# ============================================================================
# SavingsFinder.psm1 — the app's OWN deterministic savings conclusions.
#
# This is what makes the product more than an Azure Advisor mirror: it inspects the
# ingested cost data (+ Resource Graph + Azure Monitor metrics) and forms its own
# conclusions about waste and sizing. Every dollar figure is computed HERE, and each finding
# carries its own deterministic Detail sentence — no AI is involved in savings findings.
#
# Detectors:
#   Get-OrphanedResources  — unattached disks / unassociated public IPs still costing
#                            money (Resource Graph + cost). The figure is the resource's own
#                            measured cost, so it is CERTAIN.
#   Get-LowUtilizationVms  — VMs idle on both average and 95th-percentile CPU → resize to the
#                            next size down, priced from the public Retail Prices API. LIKELY
#                            when both prices are known, INDICATIVE otherwise.
#   Find-CostStepUp        — a resource whose daily cost rose and stayed high. NOT a saving:
#                            it is reported on Cost changes and never counted in a total.
#
# Each detector returns finding objects with a common shape:
#   { Category, ResourceId, ResourceType, Sku, Location, Title, Detail,
#     EstMonthlySavingsUsd, Confidence, Tier, Evidence(hashtable) }
#
# TIER is what the totals are built on, and it is deliberately conservative:
#   certain      the money is measurably being spent on nothing (orphans)
#   likely       a priced change with a known before and after (right-sizing, Advisor)
#   indicative   real enough to show, not solid enough to add up (no published price, or a
#                reservation already pays for it) — always excluded from totals
#   not-a-saving reported elsewhere; never in a savings list
# ============================================================================

$script:DaysPerMonth = 30.4

# --- private: run a Resource Graph query across the given subscriptions, following paging ---
function Invoke-ResourceGraph {
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

# --- private: mean of a numeric array ---
function Get-Mean { param($Values) $a = @($Values); if (-not $a.Count) { return 0.0 } $s = 0.0; foreach ($v in $a) { $s += [double]$v }; return $s / $a.Count }

# ----------------------------------------------------------------------------
# The per-resource daily cost series the detectors read, built ONE DAY AT A TIME.
#
# Peak memory is what matters here, not tidiness. This covers a 14-day window of per-resource
# daily rows — on a mid-size tenant ~16k rows a day — and the savings timer can overlap with
# the detection timer on the same worker, on a B2 whose 3.5 GB is shared with the portal site.
# Accumulating into O(distinct resources) rather than holding O(rows) is the whole point, so
# the fold is exposed as a bare accumulator that a caller can feed a day at a time and then
# finalise: a caller that reads the entire window first has already paid the cost this design
# exists to avoid, before the fold even starts.
#
#   $acc = @{}
#   foreach ($day in $days) { Add-ResourceCostRows -Accumulator $acc -Rows (read $day) -Date $day }
#   $map = Complete-ResourceCostMap -Accumulator $acc
#
# Same shape as Update-PeriodRollup / Get-RollingWindowRows in DetectCostSpikes-Timer, which
# stream for the same reason.
# ----------------------------------------------------------------------------

# Fold one batch of raw snapshot rows into $Accumulator (mutated in place).
# -Date is the day the caller queried: when a batch is a single CostSnapshots partition the
# caller already knows the date authoritatively, so the row's own field never has to be trusted.
function Add-ResourceCostRows {
    param(
        [Parameter(Mandatory)][hashtable]$Accumulator,
        $Rows,
        [string]$Date
    )
    if (-not $Rows) { return }
    foreach ($r in $Rows) {
        $id = [string]$r.ResourceId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (-not $Accumulator.ContainsKey($id)) { $Accumulator[$id] = @{ PerDay = @{}; Scope = ''; Meter = '' } }
        $e = $Accumulator[$id]
        $d = if ($Date) { $Date } else { [string]$r.Date }
        if (-not $e.PerDay.ContainsKey($d)) { $e.PerDay[$d] = 0.0 }
        $e.PerDay[$d] += [double]$r.CostUsd
        $e.Scope = $r.Scope; $e.Meter = $r.Meter
    }
}

# Turn a filled accumulator into the map the detectors consume.
# Returns hashtable ResourceId -> { Days=@([{Date,Usd}]...ordered); AvgDaily; TotalDays; Scope; Meter }.
function Complete-ResourceCostMap {
    param([hashtable]$Accumulator)
    $map = @{}
    if (-not $Accumulator) { return $map }
    foreach ($id in $Accumulator.Keys) {
        $e = $Accumulator[$id]
        $days = @($e.PerDay.GetEnumerator() | Sort-Object Name | ForEach-Object { [PSCustomObject]@{ Date = $_.Key; Usd = [double]$_.Value } })
        $avg = Get-Mean (@($days | ForEach-Object { $_.Usd }))
        $map[$id] = [PSCustomObject]@{ Days = $days; AvgDaily = $avg; TotalDays = $days.Count; Scope = $e.Scope; Meter = $e.Meter }
    }
    return $map
}

# One-shot form, for a caller that already holds every row (tests, small windows). Identical
# output to the streaming form above — it is the same fold.
function Get-ResourceCostMap {
    param($Rows)
    $acc = @{}
    Add-ResourceCostRows -Accumulator $acc -Rows $Rows
    return (Complete-ResourceCostMap -Accumulator $acc)
}

# ----------------------------------------------------------------------------
# Find-CostStepUp — pure. A resource whose recent daily cost is materially higher than
# its earlier baseline AND stable (not a one-day spike) = a new recurring cost worth
# investigating. Savings = the sustained monthly delta.
# ----------------------------------------------------------------------------
function Find-CostStepUp {
    param($CostMap, [double]$MinMonthlyUsd = 30, [double]$RatioThreshold = 1.4)
    $findings = @()
    foreach ($id in $CostMap.Keys) {
        $days = $CostMap[$id].Days
        if ($days.Count -lt 6) { continue }
        $half = [int][Math]::Floor($days.Count / 2)
        $eAvg = Get-Mean (@($days[0..($half - 1)] | ForEach-Object { $_.Usd }))
        $recent = @($days[$half..($days.Count - 1)])
        $rAvg = Get-Mean (@($recent | ForEach-Object { $_.Usd }))
        if ($eAvg -le 0 -or $rAvg -lt ($eAvg * $RatioThreshold)) { continue }
        $monthlyDelta = ($rAvg - $eAvg) * $script:DaysPerMonth
        if ($monthlyDelta -lt $MinMonthlyUsd) { continue }
        # stability: reject if the recent window is too volatile (that's a spike, not a step-up)
        $rStd = [Math]::Sqrt((Get-Mean (@($recent | ForEach-Object { [Math]::Pow($_.Usd - $rAvg, 2) }))))
        if ($rAvg -gt 0 -and ($rStd / $rAvg) -gt 0.5) { continue }
        $findings += [PSCustomObject]@{
            Category = 'step-up'; ResourceId = $id; ResourceType = ''; Sku = ''; Location = ''
            Title = (Get-PortalText 'savings.stepUp.title')
            # No amounts in the text: the page shows the increase in the display currency beside it.
            Detail = (Get-PortalText 'savings.stepUp.detail')
            EstMonthlySavingsUsd = [Math]::Round($monthlyDelta, 2)
            Confidence = 'medium'
            # NOT a saving: this is money now being spent, not money available to stop
            # spending. It belongs on Cost changes, and it is excluded from every savings
            # total — counting it once inflated the headline by whatever the tenant had
            # legitimately grown by.
            Tier = 'not-a-saving'
            Evidence = @{ earlierAvgDaily = [Math]::Round($eAvg, 2); recentAvgDaily = [Math]::Round($rAvg, 2); days = $days.Count }
        }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# Get-OrphanedResources — unattached disks / unassociated public IPs that still cost
# money. Savings = the resource's own cost (100% waste). High confidence.
# ----------------------------------------------------------------------------
function Get-OrphanedResources {
    param($CostMap, [Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds)
    $query = @"
resources
| where (type =~ 'microsoft.compute/disks' and tostring(properties.diskState) == 'Unattached')
   or (type =~ 'microsoft.network/publicipaddresses' and isnull(properties.ipConfiguration) and isnull(properties.natGateway))
| project id, type, name, location, sku = tostring(sku.name)
"@
    $rows = Invoke-ResourceGraph -Query $query -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds
    $findings = @()
    foreach ($r in $rows) {
        $id = [string]$r.id
        $avgDaily = if ($CostMap.ContainsKey($id)) { [double]$CostMap[$id].AvgDaily } else { 0.0 }
        $monthly = [Math]::Round($avgDaily * $script:DaysPerMonth, 2)
        $kind = if ($r.type -match 'disks') { Get-PortalText 'savings.orphan.disk' } else { Get-PortalText 'savings.orphan.ip' }
        $findings += [PSCustomObject]@{
            Category = 'orphaned'; ResourceId = $id; ResourceType = [string]$r.type; Sku = [string]$r.sku; Location = [string]$r.location
            Title = $kind
            Detail = (Get-PortalText 'savings.orphan.detail' @{ kind = $kind; name = [string]$r.name })
            EstMonthlySavingsUsd = $monthly
            Confidence = 'high'
            # CERTAIN: the resource is attached to nothing, and the figure is its own measured
            # cost — not an estimate of what a change might save.
            Tier = 'certain'
            Evidence = @{ avgDailyUsd = [Math]::Round($avgDaily, 2); resourceName = [string]$r.name }
        }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# VM SIZING — priced from the real price list, not a percentage of the bill.
#
# The old estimate was "half the VM's cost if CPU is very low, a quarter otherwise". That is a
# guess dressed as a figure: what a downsize actually saves is the price difference between the
# current size and the next one down, which Azure publishes. Two things follow:
#   - a saving can only be claimed when BOTH prices are known (otherwise the finding is
#     'indicative' and stays out of every total);
#   - a VM already covered by a reservation or savings plan saves nothing by being downsized
#     until that commitment is exchanged, so it is never counted either.
# ----------------------------------------------------------------------------

# Hours per month used to turn an hourly price into a monthly figure. 730 = 365 x 24 / 12,
# the same convention Azure's own pricing pages use.
$script:HoursPerMonth = 730

# The VM sizes Azure actually sells, per family, smallest first. A "downsize" is the next entry
# down in the SAME family and generation, so the CPU-to-memory ratio and the feature set stay
# the same — moving a D8s_v5 to a D4s_v5 is a size change, moving it to an E4s_v5 is a
# different machine and not something to recommend automatically.
$script:VmSizeLadder = @(1, 2, 4, 8, 16, 20, 32, 48, 64, 80, 96, 128)

# Next size down within the same family/generation, or $null when there is none (already the
# smallest, or a name shape we don't recognise — a custom or constrained-core SKU).
# 'Standard_D8s_v5' -> 'Standard_D4s_v5'; 'Standard_E2as_v5' -> $null (2 is the smallest listed
# for that shape only if 1 isn't sold, so the caller prices it and finds out).
function Get-NextSmallerVmSize {
    param([string]$VmSize)
    if ([string]::IsNullOrWhiteSpace($VmSize)) { return $null }
    # Standard_ <family letters> <cores> <suffix incl. generation>
    if ($VmSize -notmatch '^(?<prefix>Standard_)(?<family>[A-Za-z]+?)(?<cores>\d+)(?<suffix>[A-Za-z_\-0-9]*)$') { return $null }
    $cores = [int]$Matches['cores']
    # Constrained-core sizes ("Standard_E8-4s_v5" = 8 cores billed, 4 usable) are a deliberate
    # licensing choice; halving them is not a like-for-like change.
    if ($Matches['suffix'] -match '^-\d') { return $null }
    $smaller = @($script:VmSizeLadder | Where-Object { $_ -lt $cores } | Sort-Object -Descending | Select-Object -First 1)
    if (-not $smaller.Count) { return $null }
    return "$($Matches['prefix'])$($Matches['family'])$($smaller[0])$($Matches['suffix'])"
}

# Percentile of a numeric sample (linear interpolation). p95 of hourly CPU says "even at its
# busiest hours it barely worked", which is the question a right-sizing decision turns on —
# an average alone hides a nightly batch window, and a single peak condemns an idle VM.
function Get-Percentile {
    param($Values, [double]$Percentile = 95)
    $a = @($Values | Sort-Object)
    if (-not $a.Count) { return 0.0 }
    if ($a.Count -eq 1) { return [double]$a[0] }
    $rank = ($Percentile / 100) * ($a.Count - 1)
    $lo = [int][Math]::Floor($rank); $hi = [int][Math]::Ceiling($rank)
    if ($lo -eq $hi) { return [double]$a[$lo] }
    return [double]$a[$lo] + ($rank - $lo) * ([double]$a[$hi] - [double]$a[$lo])
}

# Hourly pay-as-you-go price for one VM size in one region, from the public Retail Prices API
# (keyless, unauthenticated, no RBAC needed). Returns $null when the size isn't sold there.
#
# Spot and low-priority meters are excluded: they are a different purchasing model, and their
# price would understate what the machine actually costs. Windows and Linux are priced
# separately — the Windows meters carry the licence, so comparing across them is meaningless.
function Get-VmHourlyPrice {
    param(
        [Parameter(Mandatory)][string]$VmSize,
        [Parameter(Mandatory)][string]$Region,
        [string]$OsType = 'Linux',
        [hashtable]$Cache
    )
    $key = "$VmSize|$Region|$OsType".ToLowerInvariant()
    if ($Cache -and $Cache.ContainsKey($key)) { return $Cache[$key] }

    $price = $null
    try {
        $filter = "serviceName eq 'Virtual Machines' and armSkuName eq '$VmSize' and armRegionName eq '$Region' and priceType eq 'Consumption'"
        $uri = "https://prices.azure.com/api/retail/prices?currencyCode='USD'&`$filter=$([uri]::EscapeDataString($filter))"
        $resp = Invoke-RestMethod -Method GET -Uri $uri -TimeoutSec 30
        $wantWindows = ($OsType -match '(?i)windows')
        $candidates = @($resp.Items | Where-Object {
            [double]$_.retailPrice -gt 0 -and
            [string]$_.skuName -notmatch '(?i)spot|low\s*priority' -and
            (([string]$_.productName -match '(?i)windows') -eq $wantWindows)
        })
        if ($candidates.Count) { $price = ($candidates | Measure-Object -Property retailPrice -Minimum).Minimum }
    } catch {
        Write-Host "  retail price lookup failed for $VmSize/${Region}: $($_.Exception.Message)"
    }
    if ($Cache) { $Cache[$key] = $price }
    return $price
}

# ----------------------------------------------------------------------------# ----------------------------------------------------------------------------
# Get-LowUtilizationVms — VMs that are barely used, priced from the real price list.
#
# A VM qualifies on BOTH average and 95th-percentile CPU: the average says it is idle most of
# the time, the p95 says it is idle even when busiest. Memory is checked when the guest sends
# it (the "Available Memory Bytes" metric needs the Azure Monitor agent); a VM that is CPU-idle
# but memory-tight is NOT a downsize candidate, so when the metric is present and shows little
# headroom the finding is dropped. When it is absent — the common case — that is recorded as a
# caveat rather than treated as permission.
#
# The saving is (current hourly price - next size down) x 730, both from the Retail Prices API.
# -CoveredResourceIds lists resources whose usage a reservation or savings plan already pays
# for; those are reported as 'indicative' with a zero figure, because downsizing them saves
# nothing until the commitment itself is changed.
# ----------------------------------------------------------------------------
function Get-LowUtilizationVms {
    param(
        $CostMap, [Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [Parameter(Mandatory)][datetime]$WindowStart, [Parameter(Mandatory)][datetime]$WindowEnd, [int]$MaxVms = 20,
        [string[]]$CoveredResourceIds = @()
    )
    $vms = Invoke-ResourceGraph -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| project id, name, location, vmSize = tostring(properties.hardwareProfile.vmSize),
          osType = tostring(properties.storageProfile.osDisk.osType)
"@

    # Only VMs we have cost for; look at the highest-cost ones first (bound metric calls).
    $withCost = foreach ($v in $vms) { $id = [string]$v.id; if ($CostMap.ContainsKey($id)) { [PSCustomObject]@{ Vm = $v; AvgDaily = [double]$CostMap[$id].AvgDaily } } }
    $top = @($withCost | Sort-Object AvgDaily -Descending | Select-Object -First $MaxVms)

    $covered = @{}
    foreach ($c in @($CoveredResourceIds)) { if ($c) { $covered[([string]$c).ToLowerInvariant()] = $true } }
    $priceCache = @{}
    $timespan = "$($WindowStart.ToUniversalTime().ToString('o'))/$($WindowEnd.ToUniversalTime().ToString('o'))"
    $findings = @()

    foreach ($item in $top) {
        $v = $item.Vm; $id = [string]$v.id
        try {
            # Hourly, not daily: a daily average hides a nightly batch window entirely, and the
            # p95 below is only meaningful over enough points to have a tail.
            $uri = "https://management.azure.com$id/providers/microsoft.insights/metrics?api-version=2018-01-01&metricnames=Percentage%20CPU&aggregation=Average&interval=PT1H&timespan=$([uri]::EscapeDataString($timespan))"
            $m = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" } -TimeoutSec 60
            $samples = @($m.value[0].timeseries[0].data | Where-Object { $null -ne $_.average } | ForEach-Object { [double]$_.average })
            if ($samples.Count -lt 24) { continue }   # too little history to judge

            $avgCpu = Get-Mean $samples
            $p95Cpu = Get-Percentile -Values $samples -Percentile 95
            # Idle on average AND idle at the 95th percentile. A VM that averages 8% but hits
            # 70% every night is sized for the night, not for the average.
            if ($avgCpu -ge 20 -or $p95Cpu -ge 40) { continue }

            # Memory, when the guest reports it. Under ~20% free at the 5th percentile means the
            # machine needs its RAM even while the CPU idles — halving the size would hurt.
            $memNote = Get-PortalText 'savings.rightsize.noMem'
            $memFreePct = $null
            try {
                $memUri = "https://management.azure.com$id/providers/microsoft.insights/metrics?api-version=2018-01-01&metricnames=Available%20Memory%20Bytes&aggregation=Average&interval=PT1H&timespan=$([uri]::EscapeDataString($timespan))"
                $mm = Invoke-RestMethod -Method GET -Uri $memUri -Headers @{ Authorization = "Bearer $MgmtToken" } -TimeoutSec 60
                $memSamples = @($mm.value[0].timeseries[0].data | Where-Object { $null -ne $_.average } | ForEach-Object { [double]$_.average })
                if ($memSamples.Count -ge 24) {
                    # Available bytes only becomes a ratio with the size's total RAM, which the
                    # metrics API doesn't give us. The 5th percentile of available memory
                    # against its own median is still a usable signal: a machine whose free
                    # memory never moves has headroom; one that dips to a fraction of its
                    # typical free memory is under pressure.
                    $p5 = Get-Percentile -Values $memSamples -Percentile 5
                    $median = Get-Percentile -Values $memSamples -Percentile 50
                    $memFreePct = if ($median -gt 0) { [Math]::Round(($p5 / $median) * 100, 0) } else { $null }
                    if ($null -ne $memFreePct -and $memFreePct -lt 20) {
                        Write-Host "  $($v.name): CPU is idle but free memory drops to $memFreePct% of its usual level — not a downsize candidate."
                        continue
                    }
                    $memNote = Get-PortalText 'savings.rightsize.mem' @{ pct = (Format-PortalNumber $memFreePct) }
                }
            } catch { }   # metric not collected for this VM — the common case, already noted

            $monthlyCost = [Math]::Round([double]$item.AvgDaily * $script:DaysPerMonth, 2)
            $size = [string]$v.vmSize
            $region = [string]$v.location
            $osType = if ($v.osType) { [string]$v.osType } else { 'Linux' }
            $target = Get-NextSmallerVmSize -VmSize $size

            $save = 0.0; $tier = 'indicative'; $conf = 'low'
            $currentPrice = $null; $targetPrice = $null
            $reason = ''
            if ($covered.ContainsKey($id.ToLowerInvariant())) {
                $reason = 'A reservation or savings plan already pays for this VM, so downsizing it saves nothing until that commitment is exchanged or resized.'
            } elseif (-not $target) {
                $reason = "No smaller size in the $size family to move to."
            } else {
                $currentPrice = Get-VmHourlyPrice -VmSize $size -Region $region -OsType $osType -Cache $priceCache
                $targetPrice = Get-VmHourlyPrice -VmSize $target -Region $region -OsType $osType -Cache $priceCache
                if ($null -ne $currentPrice -and $null -ne $targetPrice -and $currentPrice -gt $targetPrice) {
                    $save = [Math]::Round(($currentPrice - $targetPrice) * $script:HoursPerMonth, 2)
                    # Never claim more than the VM actually costs: a machine that ran for half
                    # the window cannot save a full month of the price difference.
                    if ($monthlyCost -gt 0 -and $save -gt $monthlyCost) { $save = $monthlyCost }
                    $tier = 'likely'
                    $conf = if ($null -ne $memFreePct) { 'high' } else { 'medium' }
                } else {
                    $reason = Get-PortalText 'savings.rightsize.noPrice' @{ size = $size; target = $target; region = $region }
                }
            }

            $detail = Get-PortalText 'savings.rightsize.detail' @{ name = [string]$v.name; size = $size; avg = (Format-PortalNumber $avgCpu 1); p95 = (Format-PortalNumber $p95Cpu 1); mem = $memNote }
            $detail += if ($tier -eq 'likely') { Get-PortalText 'savings.rightsize.likely' @{ target = $target } } else { " $reason" }

            $findings += [PSCustomObject]@{
                Category = 'low-utilization'; ResourceId = $id; ResourceType = 'microsoft.compute/virtualmachines'
                Sku = $size; Location = $region
                Title = if ($tier -eq 'likely') { Get-PortalText 'savings.rightsize.title' @{ size = $size; target = $target } } else { Get-PortalText 'savings.rightsize.lowCpu' @{ cpu = (Format-PortalNumber $avgCpu 1) } }
                Detail = $detail
                EstMonthlySavingsUsd = $save
                Confidence = $conf
                Tier = $tier
                Evidence = @{
                    avgCpuPct = [Math]::Round($avgCpu, 1); p95CpuPct = [Math]::Round($p95Cpu, 1)
                    memoryFreePctOfUsual = $memFreePct
                    monthlyCostUsd = $monthlyCost; vmSize = $size; targetSize = $target
                    currentHourlyUsd = if ($null -ne $currentPrice) { [Math]::Round($currentPrice, 4) } else { $null }
                    targetHourlyUsd = if ($null -ne $targetPrice) { [Math]::Round($targetPrice, 4) } else { $null }
                    commitmentCovered = $covered.ContainsKey($id.ToLowerInvariant())
                    hoursSampled = $samples.Count
                }
            }
        } catch { Write-Host "CPU metrics failed for ${id}: $($_.Exception.Message)" }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# NON-PRODUCTION VMs RUNNING AROUND THE CLOCK.
#
# A dev/test VM that runs nights and weekends pays for 168 hours a week to be used for ~60.
# Qualifies when:
#   - its environment tag (or its resource group's) says non-production (dev, test, qa, uat,
#     acc, staging, sandbox, poc, lab, demo …; 'preprod' is left alone — it is often run like
#     production);
#   - it is running now, and the cost series shows it running every day, weekends included
#     (weekend days cost at least 80% of an average weekday, over at least 12 days).
# The saving is the VM's own compute cost × (1 − 60/168): stopped outside 07:00–19:00 on
# weekdays. Disks keep costing either way (they are separate resources). A VM a reservation or
# savings plan already pays for saves nothing by being stopped, so it is skipped.
# ----------------------------------------------------------------------------
$script:NonProdPattern = '^(dev|devel|development|test|tst|testing|qa|uat|acc|acceptance|stg|stage|staging|sandbox|sbx|poc|lab|demo|nonprod|non-prod|non-production|trial|int|integration)\b'
$script:ScheduledHoursPerWeek = 60

function Test-NonProductionValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ([string]$Value).Trim().ToLowerInvariant() -match $script:NonProdPattern
}

# Is the cost series one of a machine that never stops? -Days = [{ Date 'yyyy-MM-dd'; Usd }].
function Test-RunsAroundTheClock {
    param($Days, [int]$MinDays = 12)
    $withCost = @($Days | Where-Object { [double]$_.Usd -gt 0 })
    if ($withCost.Count -lt $MinDays) { return $false }
    $wk = @(); $we = @()
    foreach ($d in $withCost) {
        $dt = [datetime]::ParseExact([string]$d.Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($dt.DayOfWeek -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday)) { $we += [double]$d.Usd } else { $wk += [double]$d.Usd }
    }
    if ($we.Count -lt 2 -or $wk.Count -lt 5) { return $false }
    $wkAvg = (Get-Mean $wk); $weAvg = (Get-Mean $we)
    return ($wkAvg -gt 0 -and $weAvg -ge 0.8 * $wkAvg)
}

function Get-NonProdAlwaysOnVms {
    param(
        $CostMap, [Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [hashtable]$TagIndex, [string]$EnvironmentKey = 'environment',
        [string[]]$CoveredResourceIds = @()
    )
    if (-not $TagIndex -or -not $TagIndex.Count) { return @() }
    $covered = @{}
    foreach ($c in @($CoveredResourceIds)) { if ($c) { $covered[([string]$c).ToLowerInvariant()] = $true } }
    $vms = Invoke-ResourceGraph -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
| project id = tolower(id), name, location, vmSize = tostring(properties.hardwareProfile.vmSize),
          powerState = tostring(properties.extended.instanceView.powerState.code)
"@
    $keys = @($EnvironmentKey, 'env', 'environment', 'stage') | Select-Object -Unique
    $costLower = @{}; foreach ($k in $CostMap.Keys) { $costLower[([string]$k).ToLowerInvariant()] = $CostMap[$k] }
    $findings = @()
    foreach ($v in $vms) {
        $id = [string]$v.id
        if ($covered.ContainsKey($id)) { continue }
        if ([string]$v.powerState -notmatch '(?i)running') { continue }
        $entry = $TagIndex[$id]
        if (-not $entry) { continue }
        $envValue = $null
        foreach ($k in $keys) { if ($entry.Tags.ContainsKey($k)) { $envValue = [string]$entry.Tags[$k]; break } }
        if (-not (Test-NonProductionValue $envValue)) { continue }
        $series = $costLower[$id]
        if (-not $series) { continue }
        if (-not (Test-RunsAroundTheClock -Days $series.Days)) { continue }
        $monthly = [Math]::Round([double]$series.AvgDaily * $script:DaysPerMonth, 2)
        $save = [Math]::Round($monthly * (1 - $script:ScheduledHoursPerWeek / 168), 2)
        if ($save -lt 5) { continue }
        $findings += [PSCustomObject]@{
            Category = 'schedule'; ResourceId = $id; ResourceType = 'microsoft.compute/virtualmachines'; Sku = [string]$v.vmSize; Location = [string]$v.location
            Title = (Get-PortalText 'savings.schedule.title')
            Detail = (Get-PortalText 'savings.schedule.detail' @{ name = [string]$v.name; env = $envValue })
            EstMonthlySavingsUsd = $save
            Confidence = 'medium'
            # LIKELY: priced from its own measured cost; the working-hours assumption is stated.
            Tier = 'likely'
            Evidence = @{ environment = $envValue; monthlyComputeUsd = $monthly; scheduledHoursPerWeek = $script:ScheduledHoursPerWeek; resourceName = [string]$v.name }
        }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# STORAGE ACCOUNTS HOLDING COLD DATA IN THE HOT TIER.
#
# Hot costs roughly twice as much per GB stored as Cool; Cool costs more per read and has a
# 30-day early-deletion charge. An account holding a lot of data that is barely touched is paying
# the Hot price for nothing. Measured over 14 days from Azure Monitor (UsedCapacity,
# Transactions) for the costliest Hot accounts only (bounded metric calls):
#   - at least 500 GiB stored, and at most 10 transactions per GiB per month;
#   - the saving is GiB × (Hot − Cool) stored price for the account's region and redundancy,
#     from the Retail Prices API (first price band).
# LIKELY only when the data is nearly untouched (≤ 1 transaction per GiB-month) and ≥ 1 TiB;
# otherwise INDICATIVE — read and early-deletion costs could eat part of it, so it is shown and
# not totalled. A lifecycle policy (move blobs untouched for 30 days) is usually the better tool
# than flipping the whole account, and the text says so.
# ----------------------------------------------------------------------------
function Get-StorageStoredPrice {
    param([Parameter(Mandatory)][string]$Tier, [Parameter(Mandatory)][string]$Redundancy, [Parameter(Mandatory)][string]$Region, [hashtable]$Cache)
    $key = "stored|$Tier|$Redundancy|$Region".ToLowerInvariant()
    if ($Cache -and $Cache.ContainsKey($key)) { return $Cache[$key] }
    $price = $null
    try {
        $meter = "$Tier $Redundancy Data Stored"
        $filter = "serviceName eq 'Storage' and armRegionName eq '$Region' and meterName eq '$meter' and priceType eq 'Consumption'"
        $resp = Invoke-RestMethod -Method GET -TimeoutSec 30 -Uri "https://prices.azure.com/api/retail/prices?currencyCode='USD'&`$filter=$([uri]::EscapeDataString($filter))"
        $cands = @($resp.Items | Where-Object { [double]$_.retailPrice -gt 0 -and [double]$_.tierMinimumUnits -eq 0 -and [string]$_.productName -match '(?i)block blob' -and [string]$_.productName -notmatch '(?i)premium' })
        if ($cands.Count) { $price = ($cands | Measure-Object -Property retailPrice -Minimum).Minimum }
    } catch { Write-Host "  storage price lookup failed ($Tier $Redundancy $Region): $($_.Exception.Message)" }
    if ($Cache) { $Cache[$key] = $price }
    return $price
}

function ConvertTo-StorageRedundancy {
    param([string]$Sku)
    switch -Regex ([string]$Sku) {
        '(?i)RAGZRS' { return 'RA-GZRS' }
        '(?i)RAGRS'  { return 'RA-GRS' }
        '(?i)GZRS'   { return 'GZRS' }
        '(?i)GRS'    { return 'GRS' }
        '(?i)ZRS'    { return 'ZRS' }
        default      { return 'LRS' }
    }
}

function Get-HotStorageCandidates {
    param(
        $CostMap, [Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds,
        [datetime]$WindowStart = [datetime]::UtcNow.AddDays(-14), [datetime]$WindowEnd = [datetime]::UtcNow, [int]$MaxAccounts = 15
    )
    $accounts = Invoke-ResourceGraph -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query @"
resources
| where type =~ 'microsoft.storage/storageaccounts' and kind in~ ('StorageV2', 'BlobStorage') and tostring(properties.accessTier) =~ 'Hot'
| project id = tolower(id), name, location, sku = tostring(sku.name)
"@
    $costOf = @{}; foreach ($k in $CostMap.Keys) { $costOf[$k.ToLowerInvariant()] = [double]$CostMap[$k].AvgDaily }
    $top = @($accounts | Where-Object { $costOf[[string]$_.id] -ge 1 } | Sort-Object { $costOf[[string]$_.id] } -Descending | Select-Object -First $MaxAccounts)
    $timespan = "$($WindowStart.ToUniversalTime().ToString('o'))/$($WindowEnd.ToUniversalTime().ToString('o'))"
    $windowDays = [Math]::Max(1, ($WindowEnd - $WindowStart).TotalDays)
    $priceCache = @{}
    $findings = @()
    foreach ($a in $top) {
        $id = [string]$a.id
        try {
            $uri = "https://management.azure.com$id/providers/microsoft.insights/metrics?api-version=2018-01-01&metricnames=UsedCapacity,Transactions&aggregation=Average,Total&interval=PT1H&timespan=$([uri]::EscapeDataString($timespan))"
            $m = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" } -TimeoutSec 60
            $cap = @($m.value | Where-Object { $_.name.value -eq 'UsedCapacity' }) | Select-Object -First 1
            $tx = @($m.value | Where-Object { $_.name.value -eq 'Transactions' }) | Select-Object -First 1
            $capSamples = @($cap.timeseries[0].data | Where-Object { $null -ne $_.average } | ForEach-Object { [double]$_.average })
            if (-not $capSamples.Count) { continue }
            $gib = (Get-Mean $capSamples) / [Math]::Pow(1024, 3)
            $txTotal = 0.0; foreach ($p in @($tx.timeseries[0].data)) { if ($null -ne $p.total) { $txTotal += [double]$p.total } }
            $txPerGibMonth = if ($gib -gt 0) { ($txTotal / $windowDays * $script:DaysPerMonth) / $gib } else { 0 }
            if ($gib -lt 500 -or $txPerGibMonth -gt 10) { continue }

            $red = ConvertTo-StorageRedundancy ([string]$a.sku)
            $hot = Get-StorageStoredPrice -Tier 'Hot' -Redundancy $red -Region ([string]$a.location) -Cache $priceCache
            $cool = Get-StorageStoredPrice -Tier 'Cool' -Redundancy $red -Region ([string]$a.location) -Cache $priceCache
            if ($null -eq $hot -or $null -eq $cool -or $hot -le $cool) { continue }
            $save = [Math]::Round($gib * ($hot - $cool), 2)
            $monthlyCost = [Math]::Round($costOf[$id] * $script:DaysPerMonth, 2)
            if ($monthlyCost -gt 0 -and $save -gt $monthlyCost) { $save = $monthlyCost }
            if ($save -lt 5) { continue }
            $solid = ($txPerGibMonth -le 1 -and $gib -ge 1024)
            $findings += [PSCustomObject]@{
                Category = 'storage-tier'; ResourceId = $id; ResourceType = 'microsoft.storage/storageaccounts'; Sku = [string]$a.sku; Location = [string]$a.location
                Title = (Get-PortalText 'savings.storage.title')
                Detail = (Get-PortalText 'savings.storage.detail' @{ name = [string]$a.name; gib = (Format-PortalNumber $gib); tx = (Format-PortalNumber $txPerGibMonth 2); red = $red })
                EstMonthlySavingsUsd = $save
                Confidence = if ($solid) { 'medium' } else { 'low' }
                Tier = if ($solid) { 'likely' } else { 'indicative' }
                Evidence = @{ storedGiB = [Math]::Round($gib, 1); transactionsPerGiBMonth = [Math]::Round($txPerGibMonth, 3); hotPricePerGb = $hot; coolPricePerGb = $cool; redundancy = $red; resourceName = [string]$a.name }
            }
        } catch { Write-Host "  storage metrics failed for ${id}: $($_.Exception.Message)" }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# LOG ANALYTICS ON THE WRONG PRICING TIER.
#
# Ingestion is billed per GB on pay-as-you-go, or as a daily commitment tier (100, 200, 300,
# 400, 500, 1000, 2000, 5000 GB/day) at a discount, with overage at the tier's own per-GB rate.
# From the last 30 days of billed ingestion per workspace (Cost Management, UsageQuantity of the
# ingestion meters) and the Retail Prices API for the workspace's region, the cheapest option is
# priced against what the workspace is on now. Basic/Auxiliary logs are billed separately and
# are left out; Microsoft Sentinel has its own tiers, which this does not model (the text says so).
# ----------------------------------------------------------------------------
$script:LaTiers = @(100, 200, 300, 400, 500, 1000, 2000, 5000)

function Get-LogAnalyticsPrices {
    param([Parameter(Mandatory)][string]$Region, [hashtable]$Cache)
    $key = "la|$Region".ToLowerInvariant()
    if ($Cache -and $Cache.ContainsKey($key)) { return $Cache[$key] }
    $out = @{ PerGb = $null; Tiers = @{} }
    try {
        $filter = "serviceName eq 'Log Analytics' and armRegionName eq '$Region' and priceType eq 'Consumption'"
        $uri = "https://prices.azure.com/api/retail/prices?currencyCode='USD'&`$filter=$([uri]::EscapeDataString($filter))"
        do {
            $resp = Invoke-RestMethod -Method GET -Uri $uri -TimeoutSec 30
            foreach ($i in @($resp.Items)) {
                $name = [string]$i.meterName
                if ($name -match '(?i)^(Pay-as-you-go|Analytics Logs) Data Ingestion$' -and [double]$i.retailPrice -gt 0) {
                    if (-not $out.PerGb -or [double]$i.retailPrice -lt $out.PerGb) { $out.PerGb = [double]$i.retailPrice }
                } elseif ($name -match '(?i)^(\d+) GB Commitment Tier Capacity Reservation$') {
                    $out.Tiers[[int]$Matches[1]] = [double]$i.retailPrice
                }
            }
            $uri = $resp.NextPageLink
        } while ($uri)
    } catch { Write-Host "  Log Analytics price lookup failed for ${Region}: $($_.Exception.Message)" }
    if ($Cache) { $Cache[$key] = $out }
    return $out
}

# Daily cost of ingesting $DailyGb on each option. Pure. Returns the cheapest and the current.
function Measure-LogAnalyticsTierCost {
    param([double]$DailyGb, $Prices, [string]$CurrentSku = 'PerGB2018', [int]$CurrentLevel = 0)
    $options = @()
    if ($Prices.PerGb) { $options += [PSCustomObject]@{ Name = 'pay-as-you-go'; Level = 0; Daily = $DailyGb * $Prices.PerGb } }
    foreach ($t in $script:LaTiers) {
        $p = $Prices.Tiers[$t]
        if (-not $p) { continue }
        $over = [Math]::Max(0, $DailyGb - $t) * ($p / $t)
        $options += [PSCustomObject]@{ Name = "$t GB/day commitment tier"; Level = $t; Daily = $p + $over }
    }
    if (-not $options.Count) { return $null }
    $best = $options | Sort-Object Daily | Select-Object -First 1
    $current = if ($CurrentSku -match '(?i)capacityreservation' -and $CurrentLevel -gt 0) { @($options | Where-Object Level -eq $CurrentLevel) | Select-Object -First 1 }
               else { @($options | Where-Object Level -eq 0) | Select-Object -First 1 }
    return [PSCustomObject]@{ Best = $best; Current = $current }
}

function Get-LogAnalyticsTierFindings {
    param([Parameter(Mandatory)][string]$MgmtToken, [Parameter(Mandatory)][string[]]$SubscriptionIds, [int]$Days = 30)
    $ws = Invoke-ResourceGraph -MgmtToken $MgmtToken -SubscriptionIds $SubscriptionIds -Query @"
resources
| where type =~ 'microsoft.operationalinsights/workspaces'
| project id = tolower(id), name, location, subscriptionId, skuName = tostring(properties.sku.name), level = toint(properties.sku.capacityReservationLevel)
"@
    if (-not @($ws).Count) { return @() }
    $to = [datetime]::UtcNow.Date.AddDays(-1); $from = $to.AddDays(-($Days - 1))
    $gbById = @{}
    foreach ($g in (@($ws) | Group-Object subscriptionId)) {
        $ids = @($g.Group | ForEach-Object { [string]$_.id } | Select-Object -First 100)
        $body = @{
            type = 'ActualCost'; timeframe = 'Custom'
            timePeriod = @{ from = $from.ToString('yyyy-MM-dd'); to = $to.ToString('yyyy-MM-dd') }
            dataset = @{
                granularity = 'None'
                aggregation = @{ quantity = @{ name = 'UsageQuantity'; function = 'Sum' } }
                grouping = @(@{ type = 'Dimension'; name = 'ResourceId' }, @{ type = 'Dimension'; name = 'Meter' })
                filter = @{ dimensions = @{ name = 'ResourceId'; operator = 'In'; values = $ids } }
            }
        } | ConvertTo-Json -Depth 12
        try {
            $resp = Invoke-CostQueryRest -Token $MgmtToken -Body $body -Uri "https://management.azure.com/subscriptions/$($g.Name)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
            $cols = @($resp.properties.columns.name)
            $iId = [array]::IndexOf($cols, 'ResourceId'); $iMeter = [array]::IndexOf($cols, 'Meter'); $iQ = [array]::IndexOf($cols, 'UsageQuantity')
            foreach ($r in $resp.properties.rows) {
                $meter = [string]$r[$iMeter]
                if ($meter -notmatch '(?i)ingest' -or $meter -match '(?i)basic|auxiliary') { continue }
                $id = ([string]$r[$iId]).ToLowerInvariant()
                if (-not $gbById.ContainsKey($id)) { $gbById[$id] = 0.0 }
                $gbById[$id] += [double]$r[$iQ]
            }
        } catch { Write-Host "  Log Analytics ingestion query failed for $($g.Name): $($_.Exception.Message)" }
    }
    $priceCache = @{}
    $findings = @()
    foreach ($w in $ws) {
        $id = [string]$w.id
        if (-not $gbById.ContainsKey($id)) { continue }
        $daily = $gbById[$id] / $Days
        if ($daily -lt 50) { continue }   # well below the smallest tier: nothing to choose
        $prices = Get-LogAnalyticsPrices -Region ([string]$w.location) -Cache $priceCache
        $m = Measure-LogAnalyticsTierCost -DailyGb $daily -Prices $prices -CurrentSku ([string]$w.skuName) -CurrentLevel ([int]$w.level)
        if (-not $m -or -not $m.Current -or $m.Best.Level -eq $m.Current.Level) { continue }
        $save = [Math]::Round(($m.Current.Daily - $m.Best.Daily) * $script:DaysPerMonth, 2)
        if ($save -lt 10) { continue }
        $findings += [PSCustomObject]@{
            Category = 'log-analytics-tier'; ResourceId = $id; ResourceType = 'microsoft.operationalinsights/workspaces'; Sku = [string]$w.skuName; Location = [string]$w.location
            Title = (Get-PortalText 'savings.la.title' @{ best = $m.Best.Name })
            Detail = (Get-PortalText 'savings.la.detail' @{ name = [string]$w.name; daily = (Format-PortalNumber $daily); days = $Days; current = $m.Current.Name; best = $m.Best.Name })
            EstMonthlySavingsUsd = $save
            Confidence = 'medium'
            Tier = 'likely'
            Evidence = @{ dailyGb = [Math]::Round($daily, 1); current = $m.Current.Name; recommended = $m.Best.Name; resourceName = [string]$w.name }
        }
    }
    return @($findings)
}

# ----------------------------------------------------------------------------
# One saving per resource in the totals. Two of our detectors can price the same resource (a
# non-production VM that is also idle: resize it, or stop it at night), and the two savings do
# not add up. The largest countable finding per resource stays as it is; any other countable one
# for the same resource becomes indicative with a note, so it is shown but never summed twice.
# ----------------------------------------------------------------------------
function Resolve-OverlappingSavings {
    param($Findings)
    $all = @($Findings)
    foreach ($g in ($all | Where-Object { $_.Tier -in @('certain', 'likely') -and $_.ResourceId } | Group-Object { ([string]$_.ResourceId).ToLowerInvariant() })) {
        if ($g.Count -lt 2) { continue }
        $keep = $g.Group | Sort-Object -Property EstMonthlySavingsUsd -Descending | Select-Object -First 1
        foreach ($f in $g.Group) {
            if ($f -eq $keep) { continue }
            $f.Tier = 'indicative'
            $f.Detail = "$($f.Detail)$(Get-PortalText 'savings.overlap' @{ title = $keep.Title })"
        }
    }
    return $all
}

Export-ModuleMember -Function `
    Get-ResourceCostMap, Add-ResourceCostRows, Complete-ResourceCostMap, `
    Find-CostStepUp, Get-OrphanedResources, Get-LowUtilizationVms, `
    Get-NextSmallerVmSize, Get-Percentile, Get-VmHourlyPrice, `
    Test-NonProductionValue, Test-RunsAroundTheClock, Get-NonProdAlwaysOnVms, `
    Get-StorageStoredPrice, ConvertTo-StorageRedundancy, Get-HotStorageCandidates, `
    Get-LogAnalyticsPrices, Measure-LogAnalyticsTierCost, Get-LogAnalyticsTierFindings, `
    Resolve-OverlappingSavings