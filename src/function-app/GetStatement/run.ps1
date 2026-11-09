using namespace System.Net
param($Request, $TriggerMetadata)

# The monthly statement per owner / cost centre / … (SyncAllocation-Timer, Measure-AllocationStatement).
# Served from storage; no Azure call. Read-only; members allowed.
#
# Months: every complete month kept (13), plus the current month so far (partial = true, listed
# first, compared with the same days of last month). The default is the current month so far — the
# page always shows it; the latest complete month only on the 1st/2nd, before there is one.
#
# Query: ?month=yyyy-MM &dimension=tag:<key> (default: the first configured)
#        &value=<tag value> — without a value: the index (every value, the reconciliation to the
#        billed total, a 12-month trend per value); with one: that value's statement too.
# Trend: up to 13 months ending with the current month so far. series = each month's total (null
# for the current month); sameDays = the 1st to the settled day of the current month, in every
# month that has a daily series (CostSummary 'statement-daily'), so months compare like for like.
# Azure budgets are attached for the partial month only (a budget's spend is Azure's figure for its
# current period): budgets filtered to the tag, and budgets on resource groups, on the value of
# that group's tag.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}
function Send-Json { param([int]$Status, $Body)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]$Status
        Body       = ($Body | ConvertTo-Json -Depth 8)
        Headers    = @{ "Content-Type" = "application/json" }
    })
}

$q = $Request.Query
$wantMonth = if ($q -and $q['month']) { [string]$q['month'] } else { '' }
$wantDim = if ($q -and $q['dimension']) { [string]$q['dimension'] } else { '' }
$wantValue = if ($q -and $q['value']) { [string]$q['value'] } else { '' }
# Shape checks before anything reaches a filter.
if ($wantMonth -and $wantMonth -notmatch '^\d{4}-\d{2}$') { Send-Json 400 @{ error = 'month must be yyyy-MM' }; return }
if ($wantDim -and $wantDim -notmatch '^tag:[a-z0-9]{1,40}$') { Send-Json 400 @{ error = 'dimension must be tag:<key>' }; return }
if ($wantValue.Length -gt 256) { Send-Json 400 @{ error = 'value too long' }; return }

$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
$subScope = Get-SubscriptionScope -Token $token

# Every index row (one per month and dimension) — a few dozen at most.
$indexes = @()
try {
    $indexes = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement'" -Select 'PartitionKey,RowKey,Month,PreviousMonth,Dimension,RowsJson,ReconciliationJson,CoveragePct,Complete,DaysCovered,DaysInMonth,Partial,ThroughDate,ScopeHash,SyncedAt' -Token $token |
        Where-Object { ([string]$_.RowKey).EndsWith('|index') })
} catch { Write-Host "statement read failed: $($_.Exception.Message)" }

$monthKeys = @($indexes | ForEach-Object { [string]$_.Month } | Where-Object { $_ } | Select-Object -Unique | Sort-Object -Descending)
if (-not $monthKeys.Count) { Send-Json 200 @{ ready = $false; months = @(); dimensions = @() }; return }
$isPartial = @{}
foreach ($m in $monthKeys) { $isPartial[$m] = [bool](@($indexes | Where-Object { [string]$_.Month -eq $m -and [bool]$_.Partial }).Count) }
$completeMonths = @($monthKeys | Where-Object { -not $isPartial[$_] })
$default = @($monthKeys | Where-Object { $isPartial[$_] }) + @($completeMonths) | Select-Object -First 1
$month = if ($wantMonth -and $monthKeys -contains $wantMonth) { $wantMonth } else { $default }

# Only the tags configured now, in their order: statements stored for a tag that has since been
# dropped (e.g. 'owner' replaced by 'ServiceLead') stay in storage until pruned, unshown.
$tagKeys = @(Get-AllocationTagKeys -StorageToken $token)
$aliases = Get-AllocationValueAliases -StorageToken $token
$configuredDims = @($tagKeys | ForEach-Object { "tag:$_" })
$indexes = @($indexes | Where-Object { $configuredDims -contains [string]$_.Dimension })
$monthKeys = @($indexes | ForEach-Object { [string]$_.Month } | Where-Object { $_ } | Select-Object -Unique | Sort-Object -Descending)
if (-not $monthKeys.Count) { Send-Json 200 @{ ready = $false; months = @(); dimensions = @() }; return }
$completeMonths = @($monthKeys | Where-Object { -not $isPartial[$_] })
$default = @($monthKeys | Where-Object { $isPartial[$_] }) + @($completeMonths) | Select-Object -First 1
$month = if ($wantMonth -and $monthKeys -contains $wantMonth) { $wantMonth } else { $default }
$inMonth = @($indexes | Where-Object { [string]$_.Month -eq $month })
$have = @($inMonth | ForEach-Object { [string]$_.Dimension })
$dimensions = @($configuredDims | Where-Object { $have -contains $_ })
$dim = if ($wantDim -and $dimensions -contains $wantDim) { $wantDim } else { @($dimensions)[0] }
$tagKey = $dim.Substring(4)
$idx = @($inMonth | Where-Object { [string]$_.Dimension -eq $dim }) | Select-Object -First 1
$partial = [bool]($idx -and $idx.Partial)

$rows = @()
if ($idx -and $idx.RowsJson) { try { $rows = @([string]$idx.RowsJson | ConvertFrom-Json) } catch { $rows = @() } }
$recon = $null
if ($idx -and $idx.ReconciliationJson) { try { $recon = [string]$idx.ReconciliationJson | ConvertFrom-Json } catch { $recon = $null } }

# A value as it is matched across months and against budgets: through the alias map, then
# case-insensitively — so history stored before a value was merged still lines up.
$matchKey = { param([string]$v) if ($v.StartsWith('(')) { $v } else { ConvertTo-TagValueNorm -Value $v -Key $tagKey -Aliases $aliases } }

# --- trend per value: up to 12 complete months and the current month so far ---
$partialMonth = @($monthKeys | Where-Object { $isPartial[$_] } | Sort-Object -Descending | Select-Object -First 1)
$partialMonth = if ($partialMonth.Count) { [string]$partialMonth[0] } else { $null }
$partialIdx = if ($partialMonth) { @($indexes | Where-Object { [string]$_.Month -eq $partialMonth -and [string]$_.Dimension -eq $dim }) | Select-Object -First 1 } else { $null }

# Each month's spend per value, cumulative by day (SyncAllocation-Timer); aliases add up.
$daily = @{}; $dailyDays = @{}
try {
    foreach ($r in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement-daily'" -Select 'PartitionKey,RowKey,Month,Dimension,Days,SeriesJson' -Token $token | Where-Object { [string]$_.Dimension -eq $dim })) {
        $m = [string]$r.Month
        if (-not $daily.ContainsKey($m)) { $daily[$m] = @{} }
        $dailyDays[$m] = [int]$r.Days
        $obj = [string]$r.SeriesJson | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) {
            $k = & $matchKey ([string]$p.Name)
            $arr = @($p.Value | ForEach-Object { [double]$_ })
            if ($daily[$m].ContainsKey($k)) { $prev = $daily[$m][$k]; $daily[$m][$k] = @(for ($i = 0; $i -lt $arr.Count; $i++) { $arr[$i] + $(if ($i -lt $prev.Count) { $prev[$i] } else { 0 }) }) }
            else { $daily[$m][$k] = $arr }
        }
    }
} catch { Write-Host "statement trend read failed: $($_.Exception.Message)" }

# The day "same days" counts to: the settled day of the current month.
$throughDay = $null
if ($partialIdx -and $partialIdx.ThroughDate) { $throughDay = ([datetime]::ParseExact(([string]$partialIdx.ThroughDate).Substring(0, 10), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).Day }
elseif ($partialMonth -and $dailyDays.ContainsKey($partialMonth)) { $throughDay = $dailyDays[$partialMonth] }

$withIndex = @($completeMonths | Where-Object { $m = $_; @($indexes | Where-Object { [string]$_.Month -eq $m -and [string]$_.Dimension -eq $dim }).Count })
$older = @(@($withIndex) + @($daily.Keys | Where-Object { $_ -ne $partialMonth }) | Select-Object -Unique | Sort-Object -Descending | Select-Object -First 12)
$trendMonths = @(@($older) + @(if ($partialMonth) { $partialMonth }) | Sort-Object)
$byMonth = @{}
foreach ($m in $trendMonths) {
    $r = @($indexes | Where-Object { [string]$_.Month -eq $m -and [string]$_.Dimension -eq $dim }) | Select-Object -First 1
    $totals = @{}
    if ($r) { try { foreach ($x in @([string]$r.RowsJson | ConvertFrom-Json)) { $k = & $matchKey ([string]$x.key); $totals[$k] = [double]$totals[$k] + [double]$x.totalUsd } } catch { } }
    $byMonth[$m] = $totals
}
$totalOf = {
    param([string]$m, [string]$k)
    if ($m -eq $partialMonth) { return $null }
    if ($byMonth[$m].ContainsKey($k)) { return [Math]::Round($byMonth[$m][$k], 2) }
    if ($daily.ContainsKey($m) -and $daily[$m].ContainsKey($k) -and $dailyDays[$m] -ge 28) { return [Math]::Round([double]$daily[$m][$k][-1], 2) }
    return $null
}
$sameDaysOf = {
    param([string]$m, [string]$k)
    if (-not $throughDay) { return $null }
    if ($daily.ContainsKey($m) -and $daily[$m].ContainsKey($k)) {
        $a = $daily[$m][$k]; $n = [Math]::Min($throughDay, $a.Count)
        return [Math]::Round([double]$a[$n - 1], 2)
    }
    # The current month without a series yet: its partial statement is the same figure.
    if ($m -eq $partialMonth -and $byMonth[$m].ContainsKey($k)) { return [Math]::Round($byMonth[$m][$k], 2) }
    if ($daily.ContainsKey($m)) { return 0.0 }
    return $null
}
$series = [ordered]@{}; $sameDays = [ordered]@{}
foreach ($row in $rows) {
    $k = & $matchKey ([string]$row.key)
    $series[[string]$row.key] = @($trendMonths | ForEach-Object { & $totalOf $_ $k })
    $sameDays[[string]$row.key] = @($trendMonths | ForEach-Object { & $sameDaysOf $_ $k })
}

# --- Azure budgets filtered to this tag (partial month only) ---
$budgetsByKey = @{}
if ($partial) {
    try {
        $ov = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'monthoverview' and RowKey eq 'current'" -Token $token) | Select-Object -First 1
        $tagBudgets = @(Get-MonthBudgetList -Overview $ov -Kind Tag -StorageToken $token)
        foreach ($b in $tagBudgets) {
            if (-not (Test-InSubscriptionScope -Scope $subScope -Value ([string]$b.Scope))) { continue }
            foreach ($f in @($b.TagFilters)) {
                if ([string]$f.key -ne $tagKey) { continue }
                $item = [PSCustomObject]@{
                    name = [string]$b.Name; scopeName = [string]$b.ScopeName; currency = [string]$b.Currency; timeGrain = [string]$b.TimeGrain
                    amount = [double]$b.Amount; spent = [double]$b.SpentAmount
                    usedPct = if ([double]$b.Amount -gt 0) { [Math]::Round(([double]$b.SpentAmount / [double]$b.Amount) * 100, 1) } else { $null }
                    projectedToExceed = ($null -ne $b.ForecastAmount -and [double]$b.Amount -gt 0 -and [double]$b.ForecastAmount -gt [double]$b.Amount)
                    extraFilters = ([bool]$b.ExtraFilters -or @($b.TagFilters).Count -gt 1 -or @($f.values).Count -gt 1)
                }
                foreach ($v in @($f.values)) {
                    $k = & $matchKey ([string]$v)
                    if (-not $budgetsByKey.ContainsKey($k)) { $budgetsByKey[$k] = @() }
                    $budgetsByKey[$k] += $item
                }
            }
        }
    } catch { Write-Host "tag budget read failed: $($_.Exception.Message)" }
    # Budgets on resource groups, on the value of that group's tag (SyncAllocation-Timer).
    try {
        $rb = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statementbudgets' and RowKey eq 'resourcegroups'" -Token $token) | Select-Object -First 1
        foreach ($b in @(if ($rb -and $rb.BudgetsJson) { [string]$rb.BudgetsJson | ConvertFrom-Json } else { @() })) {
            if (-not $b -or -not (Test-InSubscriptionScope -Scope $subScope -Value ([string]$b.Scope))) { continue }
            $v = [string]$b.Tags.$tagKey
            if (-not $v -or $v.StartsWith('(')) { continue }
            $k = & $matchKey $v
            if (-not $budgetsByKey.ContainsKey($k)) { $budgetsByKey[$k] = @() }
            $budgetsByKey[$k] += [PSCustomObject]@{
                name = [string]$b.Name; scopeName = "resource group $([string]$b.ScopeName)"; currency = [string]$b.Currency; timeGrain = [string]$b.TimeGrain
                amount = [double]$b.Amount; spent = [double]$b.SpentAmount
                usedPct = if ([double]$b.Amount -gt 0) { [Math]::Round(([double]$b.SpentAmount / [double]$b.Amount) * 100, 1) } else { $null }
                projectedToExceed = ($null -ne $b.ForecastAmount -and [double]$b.Amount -gt 0 -and [double]$b.ForecastAmount -gt [double]$b.Amount)
                extraFilters = [bool]$b.ExtraFilters
            }
        }
    } catch { Write-Host "resource-group budget read failed: $($_.Exception.Message)" }
}
$rows = @($rows | ForEach-Object {
    $k = & $matchKey ([string]$_.key)
    $_ | Add-Member -NotePropertyName budgets -NotePropertyValue @($budgetsByKey[$k] | Where-Object { $_ }) -Force -PassThru
})

$statement = $null
if ($wantValue) {
    $rk = "$month|$dim|$(Get-ShortHash -Value $wantValue)"
    $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'statement' and RowKey eq '$(ConvertTo-ODataLiteral $rk)'" -Token $token) | Select-Object -First 1
    if (-not $row -or [string]$row.Value -ne $wantValue) { Send-Json 404 @{ error = "No statement for '$wantValue' in $month." }; return }
    try { $statement = [string]$row.StatementJson | ConvertFrom-Json } catch { $statement = $null }
    if ($statement) {
        # Resource rows name their subscription, so the scope applies at once; the sums wait for
        # tonight's rebuild (scopePending).
        foreach ($p in @('topResources', 'savings')) {
            if ($statement.$p) { $statement.$p = @($statement.$p | Where-Object { Test-InSubscriptionScope -Scope $subScope -Value ([string]$_.resourceId) }) }
        }
        if ($statement.untaggedGroups) { $statement.untaggedGroups = @($statement.untaggedGroups | Where-Object { Test-InSubscriptionScope -Scope $subScope -Value ([string]$_.resourceGroupId) }) }
        $k = & $matchKey $wantValue
        $statement | Add-Member -NotePropertyName budgets -NotePropertyValue @($budgetsByKey[$k] | Where-Object { $_ }) -Force
        $statement | Add-Member -NotePropertyName trend -NotePropertyValue @($trendMonths | ForEach-Object { & $totalOf $_ $k }) -Force
        $statement | Add-Member -NotePropertyName trendSameDays -NotePropertyValue @($trendMonths | ForEach-Object { & $sameDaysOf $_ $k }) -Force
    }
}

Send-Json 200 ([PSCustomObject]@{
    ready          = $true
    month          = $month
    previousMonth  = if ($idx) { [string]$idx.PreviousMonth } else { $null }
    partial        = $partial
    throughDate    = if ($idx -and $idx.ThroughDate) { [string]$idx.ThroughDate } else { $null }
    months         = @($monthKeys | ForEach-Object { [PSCustomObject]@{ month = $_; partial = $isPartial[$_] } })
    dimension      = $dim
    dimensions     = $dimensions
    tagLabels      = [PSCustomObject](Get-AllocationTagLabels -StorageToken $token)
    rows           = $rows
    reconciliation = $recon
    coveragePct    = if ($idx -and $null -ne $idx.CoveragePct -and [double]$idx.CoveragePct -ge 0) { [double]$idx.CoveragePct } else { $null }
    trend          = [PSCustomObject]@{ months = $trendMonths; series = $series; sameDays = $sameDays; throughDay = $throughDay; partialMonth = $partialMonth }
    complete       = if ($idx) { [bool]$idx.Complete } else { $false }
    daysCovered    = if ($idx) { [int]$idx.DaysCovered } else { 0 }
    daysInMonth    = if ($idx) { [int]$idx.DaysInMonth } else { 0 }
    lastSynced     = if ($idx) { [string]$idx.SyncedAt } else { $null }
    scopePending   = if ($idx) { [bool](Test-ScopeHashPending -Scope $subScope -Stored ([string]$idx.ScopeHash)) } else { $false }
    statement      = $statement
})
