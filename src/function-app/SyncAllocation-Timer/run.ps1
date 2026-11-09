param($Timer)

Write-Host "=== Allocation sync started ==="

# WHO SPENDS IT — this month vs the same days last month, per allocation tag (owner, cost centre,
# environment, application by default; PortalConfig AllocationTagKeys) and per resource group.
#
# Built from the per-resource daily cost the ingest already stores (CostSnapshots), so it makes
# NO Cost Management query; tags come from Resource Graph (Allocation.psm1), with the resource
# group's tag standing in where the resource has none. It therefore covers resource-attributed
# cost only — the page says so — and tags as they are now, not as they were when billed.
#
# Stored in CostSummary, PartitionKey 'allocation': one row per dimension ('tag:owner',
# 'resourceGroup', ...) plus 'meta'. Runs at 03:05 UTC, after the ingest and before the brief.
#
# The same pass builds the MONTHLY STATEMENT per tag value for the last complete month against
# the month before (Measure-AllocationStatement): spend by service, top resources and open
# savings per owner / cost centre, plus a reconciliation to the billed total in which untagged
# and shared spend (no resource) are shown separately, never spread. CostSummary, PartitionKey
# 'statement', RowKeys '<yyyy-MM>|<dim>|index' and '<yyyy-MM>|<dim>|<hash of value>'. The current
# month gets a PARTIAL statement too (this month so far vs the same days of last month), under its
# own month key; once the month is complete the nightly complete build overwrites it.
#
# For the statement TREND, each month's spend per tag value is also kept CUMULATIVE by day
# (Measure-AllocationDailySeries), so the page can compare "1st to day N" of this month with the
# same days of earlier months: CostSummary 'statement-daily', RowKey '<yyyy-MM>|<dim>|<part>'.
# The months this pass reads are rewritten nightly; one older month still within snapshot
# retention is backfilled per night; rows older than 13 months are dropped.

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$mgmtToken    = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'

$subScope = Get-SubscriptionScope -Token $storageToken
$subs = @(Get-AccessibleSubscriptions -MgmtToken $mgmtToken -StorageToken $storageToken)
if (-not $subs.Count) { Write-Host "No accessible subscriptions."; Write-Host "=== Allocation sync finished (nothing to do) ==="; return }
$subNames = @{}; foreach ($s in $subs) { $subNames[([string]$s.Id).ToLowerInvariant()] = [string]$s.Name }
$tagKeys = @(Get-AllocationTagKeys -StorageToken $storageToken)
$aliases = Get-AllocationValueAliases -StorageToken $storageToken

# Same settled cut-off as everything else (D-2), so these figures line up with the month tiles.
$settled = Get-RollingWindowEndDate
$monthStart = Get-UtcMonthStart -Date $settled
$prevStart = $monthStart.AddMonths(-1)
$prevEnd = $monthStart.AddDays(-1)
$prevSameEnd = $prevStart.AddDays(($settled - $monthStart).Days)
if ($prevSameEnd -gt $prevEnd) { $prevSameEnd = $prevEnd }
# The statement month: the latest complete, settled month, and the one before it.
$stmtMonth = Get-BriefTargetMonth
$stmtEnd = $stmtMonth.AddMonths(1).AddDays(-1)
$stmtPrev = $stmtMonth.AddMonths(-1)
$loopStart = if ($stmtPrev -lt $prevStart) { $stmtPrev } else { $prevStart }

# --- per-resource cost, one day at a time (memory stays one day + one entry per resource) ---
$perResource = @{}
$stmtResource = @{}
# Month key -> resource -> the day's cost by day of month (for the statement trend).
$dailyByMonth = @{}
$daysCurrent = 0; $daysPrevious = 0; $daysStmt = 0; $daysStmtPrev = 0
for ($d = $loopStart; $d -le $settled; $d = $d.AddDays(1)) {
    $dayKey = $d.ToString('yyyy-MM-dd')
    $rows = @()
    try { $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$dayKey'" -Token $storageToken) }
    catch { Write-Host "  snapshot read failed for ${dayKey}: $($_.Exception.Message)"; continue }
    if (-not $rows.Count) { continue }
    $inAlloc = ($d -ge $prevStart)
    $stmtSlot = if ($d -ge $stmtMonth -and $d -le $stmtEnd) { 0 } elseif ($d -ge $stmtPrev -and $d -lt $stmtMonth) { 1 } else { -1 }
    if ($inAlloc) { if ($d -ge $monthStart) { $daysCurrent++ } else { $daysPrevious++ } }
    if ($stmtSlot -eq 0) { $daysStmt++ } elseif ($stmtSlot -eq 1) { $daysStmtPrev++ }
    $mk = $d.ToString('yyyy-MM')
    if (-not $dailyByMonth.ContainsKey($mk)) { $dailyByMonth[$mk] = @{ Resources = @{}; Days = @{} } }
    $dm = $dailyByMonth[$mk]; $dm.Days[$d.Day] = $true
    $dimLen = [datetime]::DaysInMonth($d.Year, $d.Month)
    foreach ($r in (Select-InSubscriptionScope -Scope $subScope -Rows $rows)) {
        $id = ([string]$r.ResourceId).ToLowerInvariant()
        if (-not $id) { continue }
        $c = [double]$r.CostUsd
        if (-not $dm.Resources.ContainsKey($id)) { $dm.Resources[$id] = [double[]]::new($dimLen) }
        $dm.Resources[$id][$d.Day - 1] += $c
        if ($inAlloc) {
            if (-not $perResource.ContainsKey($id)) { $perResource[$id] = @{ Current = 0.0; PreviousSameDays = 0.0; PreviousMonth = 0.0; Meters = @{} } }
            $e = $perResource[$id]
            $slot = -1
            if ($d -ge $monthStart) { $e.Current += $c; $slot = 0 }
            else {
                $e.PreviousMonth += $c
                if ($d -le $prevSameEnd) { $e.PreviousSameDays += $c; $slot = 1 }
            }
            if ($slot -ge 0) {
                $m = [string]$r.Meter
                if (-not $e.Meters.ContainsKey($m)) { $e.Meters[$m] = @(0.0, 0.0) }
                $e.Meters[$m][$slot] += $c
            }
        }
        if ($stmtSlot -ge 0) {
            if (-not $stmtResource.ContainsKey($id)) { $stmtResource[$id] = @{ LastMonth = 0.0; MonthBefore = 0.0; Meters = @{} } }
            $sr = $stmtResource[$id]
            if ($stmtSlot -eq 0) { $sr.LastMonth += $c } else { $sr.MonthBefore += $c }
            $m = [string]$r.Meter
            if (-not $sr.Meters.ContainsKey($m)) { $sr.Meters[$m] = @(0.0, 0.0) }
            $sr.Meters[$m][$stmtSlot] += $c
        }
    }
}
Write-Host "Cost for $($perResource.Count) resource(s): $daysCurrent day(s) this month, $daysPrevious day(s) last month."

# --- tags ---
$index = Get-ResourceTagIndex -MgmtToken $mgmtToken -SubscriptionIds @($subs | ForEach-Object { $_.Id }) -Aliases $aliases
$tagsRead = ($index.Count -gt 0)
if (-not $tagsRead) { Write-Host "No tags could be read — only the resource-group view is refreshed tonight." }

$rollup = Measure-AllocationRollup -PerResource $perResource -Index $index -TagKeys $tagKeys -SubscriptionNames $subNames
$totalCurrent = 0.0; $totalPrevSame = 0.0
foreach ($e in $perResource.Values) { $totalCurrent += $e.Current; $totalPrevSame += $e.PreviousSameDays }

# Tag coverage: the share of this month's resource-attributed spend that carries a real value.
$coverage = [ordered]@{}
foreach ($k in $tagKeys) {
    $tagged = 0.0; foreach ($x in @($rollup["tag:$k"])) { if (-not ([string]$x.key).StartsWith('(')) { $tagged += [double]$x.currentUsd } }
    $coverage[$k] = if ($tagsRead -and $totalCurrent -gt 0) { [Math]::Round(($tagged / $totalCurrent) * 100, 1) } else { $null }
}

# --- write: top 100 per dimension, the rest folded into one row (a table property holds 32K) ---
$now = [datetime]::UtcNow.ToString('o')
$entities = @()
foreach ($dim in $rollup.Keys) {
    if (-not $tagsRead -and $dim -ne 'resourceGroup') { continue }
    $rows = @($rollup[$dim])
    $top = @($rows | Select-Object -First 100)
    $rest = @($rows | Select-Object -Skip 100)
    if ($rest.Count) {
        $sum = { param($p) $t = 0.0; foreach ($x in $rest) { $t += [double]$x.$p }; [Math]::Round($t, 2) }
        $top += [PSCustomObject]@{ key = '(other)'; label = "$($rest.Count) more"; subscriptionId = ''
            currentUsd = (& $sum 'currentUsd'); previousSameDaysUsd = (& $sum 'previousSameDaysUsd'); previousMonthUsd = (& $sum 'previousMonthUsd')
            deltaUsd = [Math]::Round((& $sum 'currentUsd') - (& $sum 'previousSameDaysUsd'), 2); deltaPct = $null
            sharePct = [Math]::Round((@($rest | Measure-Object -Property sharePct -Sum).Sum), 1); resources = (@($rest | Measure-Object -Property resources -Sum).Sum) }
    }
    $json = @($top) | ConvertTo-Json -Compress -AsArray
    # Belt and braces for very long labels: trim to fit the 32K property rather than fail.
    while ($json.Length -gt 30000 -and $top.Count -gt 10) { $top = @($top | Select-Object -First ([int]($top.Count * 0.8))); $json = @($top) | ConvertTo-Json -Compress -AsArray }
    $entities += @{
        PartitionKey = 'allocation'; RowKey = $dim
        RowsJson = $json; RowCount = $rows.Count
        ScopeHash = $subScope.Hash; SyncedAt = $now
    }
}
$entities += @{
    PartitionKey = 'allocation'; RowKey = 'meta'
    Month = $monthStart.ToString('yyyy-MM'); PreviousMonth = $prevStart.ToString('yyyy-MM')
    SettledThrough = $settled.ToString('yyyy-MM-dd'); PreviousSameDaysThrough = $prevSameEnd.ToString('yyyy-MM-dd')
    DaysCurrent = $daysCurrent; DaysPrevious = $daysPrevious
    TagKeys = ($tagKeys -join ','); TagsRead = $tagsRead
    # Share of this month's resource-attributed spend that carries a real value, per tag key.
    CoverageJson = ($coverage | ConvertTo-Json -Compress)
    TotalCurrentUsd = [Math]::Round($totalCurrent, 2); TotalPreviousSameDaysUsd = [Math]::Round($totalPrevSame, 2)
    Resources = $perResource.Count
    ScopeHash = $subScope.Hash; SyncedAt = $now
}
Set-TableEntityBatch -Table 'CostSummary' -Entities $entities -Token $storageToken

# --- per-resource cost for Ask and the findings agent (Write-ResourceCostIndex) ---
# Questions about resources, resource groups, subscriptions and owners, this month or last month,
# are answered from this instead of asking Cost Management subscription by subscription.
try {
    $monthBefore = if ($stmtMonth -eq $prevStart) { $stmtResource } else { $null }
    $n = Write-ResourceCostIndex -Token $storageToken -PerResource $perResource -MonthBefore $monthBefore -Index $index -OwnerKey $tagKeys[0] `
        -Month $monthStart -SettledThrough $settled -PreviousSameDaysThrough $prevSameEnd -ScopeHash $subScope.Hash
    Write-Host "Resource cost index: $n resource(s)."
} catch { Write-Host "Resource cost index failed (Ask falls back to live queries): $($_.Exception.Message)" }

# Dimensions of tags no longer configured (e.g. 'owner' after switching to ServiceLead).
try {
    $written = @{}; foreach ($e in $entities) { $written[[string]$e.RowKey] = $true }
    $dropped = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'allocation'" -Select 'PartitionKey,RowKey' -Token $storageToken |
        Where-Object { ([string]$_.RowKey).StartsWith('tag:') -and -not $written.ContainsKey([string]$_.RowKey) })
    if ($tagsRead -and $dropped.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $dropped -Token $storageToken; Write-Host "Removed $($dropped.Count) dropped tag dimension(s)." }
} catch { Write-Host "dropped dimension clean-up failed (non-fatal): $($_.Exception.Message)" }

# Rows nothing reads any more (2026-10-13: the Explore page, the Subscriptions page and the old
# dashboard summary were removed). Deleted once; after that each read finds nothing.
foreach ($pk in @('explore', 'breakdown-ServiceName', 'breakdown-ResourceGroupName', 'dashboard')) {
    try {
        $old = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq '$pk'" -Select 'PartitionKey,RowKey' -Top 5000 -Token $storageToken)
        if ($old.Count) { $n = Remove-TableEntityBatch -Table 'CostSummary' -Entities $old -Token $storageToken; Write-Host "Removed $n unused '$pk' row(s)." }
    } catch { Write-Host "clean-up of '$pk' failed (non-fatal): $($_.Exception.Message)" }
}

# --- resource-group budgets, mapped to the group's allocation tags ---
# SyncMonthlyCosts-Timer (02:55) keeps the budgets set on resource groups apart (Get-MonthBudgetList Rg —
# the subscription listing returns them). Each lands on its group's tag values, read above, so a
# budget on rg-payments shows on that group's ServiceLead and ProjectName statements.
try {
    $ov = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthoverview' and RowKey eq 'current'" -Token $storageToken) | Select-Object -First 1
    $rgb = @(Get-MonthBudgetList -Overview $ov -Kind Rg -StorageToken $storageToken)
    $mapped = @(foreach ($b in $rgb) {
        if (-not $b) { continue }
        $rgId = ([string]$b.ResourceGroupId).ToLowerInvariant()
        if (-not $rgId -or -not (Test-InSubscriptionScope -Scope $subScope -Value $rgId)) { continue }
        $tags = [ordered]@{}
        if ($index.ContainsKey($rgId)) { foreach ($k in $tagKeys) { if ($index[$rgId].Tags.ContainsKey($k)) { $tags[$k] = [string]$index[$rgId].Tags[$k] } } }
        [PSCustomObject]@{
            Name = [string]$b.Name; Scope = $rgId; ScopeName = [string]$b.ScopeName; Currency = [string]$b.Currency; TimeGrain = [string]$b.TimeGrain
            Amount = [double]$b.Amount; SpentAmount = [double]$b.SpentAmount; ForecastAmount = $b.ForecastAmount
            ExtraFilters = ([bool]$b.ExtraFilters -or @($b.TagFilters | Where-Object { $_ }).Count -gt 0); Tags = [PSCustomObject]$tags
        }
    })
    Set-TableEntity -Table 'CostSummary' -Token $storageToken -Entity @{
        PartitionKey = 'statementbudgets'; RowKey = 'resourcegroups'
        BudgetsJson = (ConvertTo-Json -InputObject @($mapped) -Compress -Depth 4); ScopeHash = $subScope.Hash; SyncedAt = $now
    }
    Write-Host "Resource-group budgets mapped to tags: $($mapped.Count)."
} catch { Write-Host "resource-group budget mapping failed (non-fatal): $($_.Exception.Message)" }

# --- statements per tag value ---
# One month's statements: an index row per tag key plus one row per value, rewritten whole (values
# that dropped out are removed). -Partial marks the current month so far.
function Write-MonthStatements {
    param(
        [datetime]$Month, [datetime]$PreviousMonth, [hashtable]$PerResource, $BilledUsd,
        [bool]$Complete, [int]$DaysCovered, [int]$DaysInMonth, [bool]$Partial, [string]$ThroughDate, [object[]]$Savings
    )
    $monthKey = $Month.ToString('yyyy-MM')
    $stmt = Measure-AllocationStatement -PerResource $PerResource -Index $index -TagKeys $tagKeys -Savings $Savings -BilledUsd $BilledUsd
    $stmtEntities = @()
    foreach ($dim in $stmt.dims.Keys) {
        $sd = $stmt.dims[$dim]
        $rows = @($sd.index)
        $top = @($rows | Select-Object -First 200)
        $json = ConvertTo-Json -InputObject @($top) -Compress -Depth 4
        while ($json.Length -gt 30000 -and $top.Count -gt 10) { $top = @($top | Select-Object -First ([int]($top.Count * 0.8))); $json = ConvertTo-Json -InputObject @($top) -Compress -Depth 4 }
        $stmtEntities += @{
            PartitionKey = 'statement'; RowKey = "$monthKey|$dim|index"
            Month = $monthKey; PreviousMonth = $PreviousMonth.ToString('yyyy-MM'); Dimension = $dim
            RowsJson = $json; RowCount = $rows.Count
            ReconciliationJson = ($stmt.reconciliation | ConvertTo-Json -Compress)
            CoveragePct = if ($null -ne $sd.coveragePct) { [double]$sd.coveragePct } else { -1.0 }
            Complete = $Complete; DaysCovered = $DaysCovered; DaysInMonth = $DaysInMonth
            Partial = $Partial; ThroughDate = $ThroughDate
            ScopeHash = $subScope.Hash; SyncedAt = $now
        }
        foreach ($r in $top) {
            $body = $sd.statements[[string]$r.key] | ConvertTo-Json -Compress -Depth 5
            if ($body.Length -gt 30000) { continue }
            $stmtEntities += @{
                PartitionKey = 'statement'; RowKey = "$monthKey|$dim|$(Get-ShortHash -Value ([string]$r.key))"
                Month = $monthKey; Dimension = $dim; Value = [string]$r.key
                StatementJson = $body; ScopeHash = $subScope.Hash; SyncedAt = $now
            }
        }
    }
    if ($stmtEntities.Count) {
        $keep = @{}; foreach ($e in $stmtEntities) { $keep[$e.RowKey] = $true }
        $existing = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement' and RowKey ge '$monthKey|' and RowKey lt '$monthKey}'" -Select 'PartitionKey,RowKey' -Token $storageToken)
        $stale = @($existing | Where-Object { -not $keep.ContainsKey([string]$_.RowKey) })
        Set-TableEntityBatch -Table 'CostSummary' -Entities $stmtEntities -Token $storageToken
        if ($stale.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $stale -Token $storageToken }
    }
    Write-Host "Statements for ${monthKey}$(if ($Partial) { ' (so far)' }): $(@($stmtEntities).Count) row(s)$(if (-not $Complete) { ' (not fully covered)' })."
}

try {
    if ($tagsRead) {
        # The billed totals, from the one definition of daily spend (dailytotal, written by the ingest).
        $totals = @{}
        foreach ($row in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailytotal' and RowKey ge '$($stmtMonth.ToString('yyyy-MM-dd'))' and RowKey le '$($settled.ToString('yyyy-MM-dd'))'" -Token $storageToken)) {
            $totals[[string]$row.RowKey] = $row
        }
        $savings = @()
        try { $savings = @((Get-BriefSavings -Token $storageToken -Top 1000 -ExcludeIdle).items) } catch { Write-Host "  statement: savings read failed: $($_.Exception.Message)" }

        # The last complete month against the one before.
        $dimInMonth = [datetime]::DaysInMonth($stmtMonth.Year, $stmtMonth.Month)
        $dimPrev = [datetime]::DaysInMonth($stmtPrev.Year, $stmtPrev.Month)
        $billed = Measure-MonthSpend -Days $totals -Month $stmtMonth
        Write-MonthStatements -Month $stmtMonth -PreviousMonth $stmtPrev -PerResource $stmtResource -Savings $savings `
            -BilledUsd $(if ($billed.complete) { $billed.usd } else { $null }) `
            -Complete (($daysStmt -eq $dimInMonth) -and ($daysStmtPrev -eq $dimPrev) -and $billed.complete) `
            -DaysCovered $daysStmt -DaysInMonth $dimInMonth -Partial $false -ThroughDate $stmtEnd.ToString('yyyy-MM-dd')

        # This month so far against the same days of last month — unless the settled month IS the
        # statement month (the 1st/2nd), which the complete build above already covers.
        if ($monthStart -ne $stmtMonth) {
            $partialResource = @{}
            foreach ($id in $perResource.Keys) {
                $e = $perResource[$id]
                $partialResource[$id] = @{ LastMonth = $e.Current; MonthBefore = $e.PreviousSameDays; Meters = $e.Meters }
            }
            $billedSoFar = Measure-MonthSpend -Days $totals -Month $monthStart -ThroughDay $settled.Day
            $sameDays = ($prevSameEnd - $prevStart).Days + 1
            Write-MonthStatements -Month $monthStart -PreviousMonth $prevStart -PerResource $partialResource -Savings $savings `
                -BilledUsd $(if ($billedSoFar.complete) { $billedSoFar.usd } else { $null }) `
                -Complete (($daysCurrent -eq $settled.Day) -and ($daysPrevious -ge $sameDays) -and $billedSoFar.complete) `
                -DaysCovered $daysCurrent -DaysInMonth ([datetime]::DaysInMonth($monthStart.Year, $monthStart.Month)) `
                -Partial $true -ThroughDate $settled.ToString('yyyy-MM-dd')
        }
    }
    # A year of statements: drop months more than 13 before the statement month.
    $cutoff = $stmtMonth.AddMonths(-13).ToString('yyyy-MM')
    $old = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement' and RowKey lt '$cutoff|'" -Select 'PartitionKey,RowKey' -Token $storageToken)
    if ($old.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $old -Token $storageToken }
} catch { Write-Host "statement build failed (non-fatal): $($_.Exception.Message)" }

# --- statement trend: each month's spend per tag value, cumulative by day ---
function Write-DailySeries {
    param([datetime]$Month, [hashtable]$PerResourceDaily, [int]$Days, [int]$DaysCovered)
    $monthKey = $Month.ToString('yyyy-MM')
    $dimLen = [datetime]::DaysInMonth($Month.Year, $Month.Month)
    $series = Measure-AllocationDailySeries -PerResourceDaily $PerResourceDaily -Index $index -TagKeys $tagKeys -Days $Days
    $ents = @()
    foreach ($dim in $series.Keys) {
        # Split by value so each row's JSON stays inside the 32K property.
        $chunks = [System.Collections.Generic.List[object]]::new()
        $chunk = [ordered]@{}; $len = 2
        foreach ($v in @($series[$dim].Keys | Sort-Object)) {
            $arr = @($series[$dim][$v])
            if ($arr.Count -and [double]$arr[-1] -eq 0) { continue }
            $piece = ([string]$v | ConvertTo-Json -Compress).Length + (ConvertTo-Json -InputObject $arr -Compress).Length + 2
            if ($chunk.Count -and $len + $piece -gt 30000) { $chunks.Add($chunk); $chunk = [ordered]@{}; $len = 2 }
            $chunk[[string]$v] = $arr; $len += $piece
        }
        $chunks.Add($chunk)
        for ($part = 0; $part -lt $chunks.Count; $part++) {
            $ents += @{
                PartitionKey = 'statement-daily'; RowKey = "$monthKey|$dim|$part"
                Month = $monthKey; Dimension = $dim; Days = $Days; DaysInMonth = $dimLen; DaysCovered = $DaysCovered
                Complete = ($Days -eq $dimLen -and $DaysCovered -eq $dimLen)
                SeriesJson = ($chunks[$part] | ConvertTo-Json -Compress -Depth 3); ScopeHash = $subScope.Hash; SyncedAt = $now
            }
        }
    }
    $keep = @{}; foreach ($e in $ents) { $keep[$e.RowKey] = $true }
    $existing = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement-daily' and RowKey ge '$monthKey|' and RowKey lt '$monthKey}'" -Select 'PartitionKey,RowKey' -Token $storageToken)
    if ($ents.Count) { Set-TableEntityBatch -Table 'CostSummary' -Entities $ents -Token $storageToken }
    $stale = @($existing | Where-Object { -not $keep.ContainsKey([string]$_.RowKey) })
    if ($stale.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $stale -Token $storageToken }
    Write-Host "Statement trend for ${monthKey}: $($ents.Count) row(s), $DaysCovered day(s) of data."
}

try {
    if ($tagsRead) {
        # The months this pass read: the current month to the settled day, earlier ones whole.
        foreach ($mk in @($dailyByMonth.Keys | Sort-Object)) {
            $m = [datetime]::ParseExact($mk, 'yyyy-MM', [System.Globalization.CultureInfo]::InvariantCulture)
            $days = if ($mk -eq $monthStart.ToString('yyyy-MM')) { $settled.Day } else { [datetime]::DaysInMonth($m.Year, $m.Month) }
            Write-DailySeries -Month $m -PerResourceDaily $dailyByMonth[$mk].Resources -Days $days -DaysCovered $dailyByMonth[$mk].Days.Count
        }
        # Backfill: the oldest month within the last 12 that has no series yet but still has daily
        # snapshots (they are pruned after ~180 days, so the oldest goes first). One per night.
        $have = @{}
        foreach ($r in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement-daily'" -Select 'PartitionKey,RowKey,Month' -Token $storageToken)) { $have[[string]$r.Month] = $true }
        for ($i = 12; $i -ge 1; $i--) {
            $m = $monthStart.AddMonths(-$i)
            $mk = $m.ToString('yyyy-MM')
            if ($m -ge $loopStart -or $have.ContainsKey($mk)) { continue }
            $last = $m.AddMonths(1).AddDays(-1)
            $probe = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$($last.ToString('yyyy-MM-dd'))'" -Select 'PartitionKey,RowKey' -Top 1 -Token $storageToken)
            if (-not $probe.Count) { continue }
            $dimLen = [datetime]::DaysInMonth($m.Year, $m.Month)
            $perDay = @{}; $covered = 0
            for ($d = $m; $d -le $last; $d = $d.AddDays(1)) {
                $rows = @()
                try { $rows = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey eq '$($d.ToString('yyyy-MM-dd'))'" -Token $storageToken) } catch { continue }
                if (-not $rows.Count) { continue }
                $covered++
                foreach ($r in (Select-InSubscriptionScope -Scope $subScope -Rows $rows)) {
                    $id = ([string]$r.ResourceId).ToLowerInvariant()
                    if (-not $id) { continue }
                    if (-not $perDay.ContainsKey($id)) { $perDay[$id] = [double[]]::new($dimLen) }
                    $perDay[$id][$d.Day - 1] += [double]$r.CostUsd
                }
            }
            Write-DailySeries -Month $m -PerResourceDaily $perDay -Days $dimLen -DaysCovered $covered
            break
        }
    }
    $cutoff = $monthStart.AddMonths(-13).ToString('yyyy-MM')
    $old = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement-daily' and RowKey lt '$cutoff|'" -Select 'PartitionKey,RowKey' -Token $storageToken)
    if ($old.Count) { $null = Remove-TableEntityBatch -Table 'CostSummary' -Entities $old -Token $storageToken }
} catch { Write-Host "statement trend build failed (non-fatal): $($_.Exception.Message)" }

$untaggedOwner = @($rollup["tag:$($tagKeys[0])"] | Where-Object { $_.key -eq '(untagged)' }) | Select-Object -First 1
Write-Host "=== Allocation sync finished: $(@($entities).Count - 1) dimension(s)$(if ($untaggedOwner) { "; $($untaggedOwner.sharePct)% of this month's resource cost has no $($tagKeys[0]) tag" }) ==="
