# ============================================================================
# CostIngest.psm1 — the queue-based cost ingest.
#
# WHY A QUEUE. Cost Management's Query API budget is per TENANT and charged per month of data a
# request touches: 12 QPU per 10 s, 60 per minute, 600 per hour
# (https://learn.microsoft.com/azure/cost-management-billing/costs/manage-automation#data-latency-and-rate-limits).
# On a CSP tenant the only scope is the subscription, so every figure costs one request per
# subscription. The old ingest did all of that inside ONE timer invocation, hit the 30-minute
# function timeout on a 42-subscription tenant, and — because its history backfill was
# all-or-nothing and always started ~26 minutes in — would never have finished at all.
#
# Here the work is split into small tasks on the 'cost-tasks' queue, worked one at a time
# (host.json: batchSize 1), so no invocation comes near the timeout and the tenant quota is the
# only thing that sets the pace:
#
#   PlanCostIngest-Timer (hourly, and on start-up)  -> Invoke-CostIngestPlanner
#       - from 02:00 UTC: today's nightly run — one 'recent' task per subscription;
#       - afterwards: the one-time history, one calendar month (all subscriptions) per task;
#       - recovers a run whose tasks went missing, and re-totals after a scope change.
#   ProcessCostTask-Queue -> Invoke-CostTask
#       'recent'   one subscription, the nightly window: CostSnapshots + CostSummary 'dailysub'.
#                  The last one to finish completes the run (Complete-CostIngestRun).
#       'history'  one month for the pending subscriptions, written only when ALL answered —
#                  the detectors treat a day with any row as covered, so a month must never be
#                  half-loaded.
#       'followup' after the first history: monthly sync, detectors, statements and the brief,
#                  so a new deployment shows a complete portal the same day, not next night.
#
# STORAGE. Per subscription and day (CostSummary 'dailysub'), so tenant totals are a sum computed
# here: a scope change is a recomputation, not a refetch, and one slow subscription holds back
# only the days it hasn't answered for. The tenant rows the readers use are unchanged:
# 'dailytotal' (one row per day, written only when every in-scope subscription has that day),
# 'monthly-sub', the 'ingest/lastrun' marker and 'backfill/dailytotal90'.
# ============================================================================

$script:Queue = 'cost-tasks'
$script:MaxTaskAttempts = 6
# The nightly run starts at this UTC hour (the analysis timers follow from 02:35).
$script:NightlyHourUtc = 2
# A run older than this whose tasks haven't all reported is completed with what arrived.
$script:RunStaleHours = 3
# A history month task that hasn't reported back within this is enqueued again.
$script:HistoryStaleMinutes = 75
# A history month stops starting new queries after this, and is retried later, rather than be
# cut off by the 30-minute function timeout (its rows are only written when complete).
$script:HistoryDeadlineMinutes = 22
$script:FollowupSteps = @('SyncMonthlyCosts-Timer', 'DetectSavings-Timer', 'DetectCostSpikes-Timer', 'SyncAllocation-Timer', 'brief')

function ConvertTo-DayString { param([datetime]$Date) return $Date.ToString('yyyy-MM-dd') }
function ConvertFrom-DayString {
    param([string]$Value)
    $d = [datetime]::MinValue
    if ($Value -and [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) {
        return [datetime]::SpecifyKind($d.Date, [System.DateTimeKind]::Utc)
    }
    return $null
}
function ConvertFrom-IsoTime {
    param([string]$Value)
    $d = [datetime]::MinValue
    if ($Value -and [datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $d }
    return $null
}
function ConvertFrom-JsonList {
    param([string]$Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    try { return @($Json | ConvertFrom-Json) } catch { return @() }
}
function ConvertTo-JsonList { param($Items) return (@($Items) | ConvertTo-Json -Compress -AsArray -Depth 5) }

# The windows the ingest works with, from PortalConfig settings/current.
#   From..To            the nightly window: the detector baseline plus two days of restatements
#   Settled             D-2 — days up to here are final, and a day Azure has no row for is a 0
#   HistoryFrom         how far back the one-time history reaches (SnapshotBackfillDays, default
#                       120, never below what the retention prune keeps)
#   EffectiveRetention  CostSnapshots retention (SnapshotRetentionDays, floored for the detectors)
function Get-CostIngestWindow {
    param([Parameter(Mandatory)][string]$StorageToken, [datetime]$Today = [datetime]::UtcNow.Date)
    $cfg = $null
    try { $cfg = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1 } catch {}
    $baselineDays = 7;   if ($cfg -and $null -ne $cfg.BaselineDays) { $baselineDays = [int]$cfg.BaselineDays }
    $retentionDays = 180; if ($cfg -and $null -ne $cfg.SnapshotRetentionDays) { $retentionDays = [int]$cfg.SnapshotRetentionDays }
    $backfillDays = 120; if ($cfg -and $null -ne $cfg.SnapshotBackfillDays) { $backfillDays = [int]$cfg.SnapshotBackfillDays }
    $floorDays = [Math]::Max([Math]::Max($baselineDays + 2, 14), (Get-PeriodRetentionFloorDays))
    $effective = [Math]::Max($retentionDays, $floorDays)
    if ($backfillDays -gt 0 -and $retentionDays -gt 0) { $backfillDays = [Math]::Min($backfillDays, $effective) }
    $to = $Today.Date
    $from = $to.AddDays(-($baselineDays + 2))
    return [PSCustomObject]@{
        Today = $to; From = $from; To = $to
        Settled = (Get-RollingWindowEndDate -Today $to)
        BackfillDays = $backfillDays
        HistoryFrom = if ($backfillDays -gt 0) { $to.AddDays(-$backfillDays) } else { $null }
        RetentionDays = $retentionDays; EffectiveRetention = $effective
    }
}

# Calendar-month slices of [From, To] — one QPU each.
function Get-MonthSlices {
    param([datetime]$From, [datetime]$To)
    $out = @()
    if (-not $From -or -not $To -or $To -lt $From) { return $out }
    $m = Get-UtcMonthStart -Date $From
    while ($m -le $To) {
        $s = if ($m -lt $From) { $From } else { $m }
        $e = $m.AddMonths(1).AddDays(-1); if ($e -gt $To) { $e = $To }
        $out += [PSCustomObject]@{ Month = $m.ToString('yyyy-MM'); From = $s.Date; To = $e.Date }
        $m = $m.AddMonths(1)
    }
    return $out
}

# Subscriptions the portal covers: the last discovery, filtered to the operator's scope.
function Get-InScopeSubscriptions {
    param([Parameter(Mandatory)][string]$StorageToken)
    $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'subscriptions' and RowKey eq 'discovered'" -Token $StorageToken) | Select-Object -First 1
    $scope = Get-SubscriptionScope -Token $StorageToken
    $all = if ($row) { @(ConvertFrom-JsonList ([string]$row.SubscriptionsJson)) } else { @() }
    return @($all | Where-Object { Test-InSubscriptionScope -Scope $scope -Value ([string]$_.id) } |
        ForEach-Object { [PSCustomObject]@{ Id = ([string]$_.id).ToLowerInvariant(); Name = [string]$_.name } })
}

function Get-CostIngestRun {
    param([Parameter(Mandatory)][string]$StorageToken)
    return (@(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'ingestrun' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1)
}
function Get-CostHistoryState {
    param([Parameter(Mandatory)][string]$StorageToken)
    return (@(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'backfill' and RowKey eq 'history'" -Token $StorageToken) | Select-Object -First 1)
}

# ---------------------------------------------------------------------------------------------
# Writing one subscription's results
# ---------------------------------------------------------------------------------------------
function Write-CostSnapshotRows {
    param([array]$Rows, [Parameter(Mandatory)][string]$StorageToken)
    $entities = foreach ($r in @($Rows)) {
        @{
            PartitionKey = $r.Date
            # ResourceId is globally unique (it embeds the subscription), so hashing it keeps
            # RowKeys unique across subscriptions.
            RowKey       = (Get-ShortHash -Value $r.ResourceId)
            Date         = $r.Date
            DimensionKey = $r.ResourceId
            Scope        = $r.Scope
            ResourceId   = $r.ResourceId
            Meter        = $r.Meter
            CostUsd      = [Math]::Round([double]$r.CostUsd, 4)
        }
    }
    Set-TableEntityBatch -Table 'CostSnapshots' -Entities @($entities) -Token $StorageToken
}

# One 'dailysub' row per day in [From, To]. A settled day (<= D-2) Azure returned nothing for is
# a genuine zero and is written as one, so a quiet subscription never blocks the tenant total; a
# recent day with no row yet is left out (Azure may simply not have reported it).
function ConvertTo-DailySubEntities {
    param([Parameter(Mandatory)][string]$SubscriptionId, [hashtable]$Days, [datetime]$From, [datetime]$To,
          [datetime]$Settled, [string]$CostType, [string]$Currency)
    $out = @()
    for ($d = $From.Date; $d -le $To.Date; $d = $d.AddDays(1)) {
        $k = ConvertTo-DayString $d
        $v = if ($Days -and $Days.ContainsKey($k)) { $Days[$k] } else { $null }
        if (-not $v -and $d -gt $Settled) { continue }
        $e = @{ PartitionKey = 'dailysub'; RowKey = "$k|$SubscriptionId"; Date = $k; SubscriptionId = $SubscriptionId
                TotalUsd = if ($v) { [Math]::Round([double]$v.Usd, 4) } else { 0.0 }; CostType = $CostType
                At = ([datetime]::UtcNow.ToString('o')) }
        $cur = if ($v -and $v.Currency) { [string]$v.Currency } else { $Currency }
        if ($v -and $null -ne $v.Billing -and $cur) { $e.TotalBilling = [Math]::Round([double]$v.Billing, 4); $e.Currency = $cur }
        elseif (-not $v -and $cur) { $e.TotalBilling = 0.0; $e.Currency = $cur }
        $out += $e
    }
    return $out
}

# ---------------------------------------------------------------------------------------------
# Tenant totals from the per-subscription rows
# ---------------------------------------------------------------------------------------------

# Recomputes CostSummary 'dailytotal' for every day the per-subscription rows cover. A day is
# written only when EVERY subscription in -SubscriptionIds has it (a partial sum would understate
# the day and look complete). The billing-currency total is added only when all of them carry one
# figure in one currency. Returns the number of days written.
function Update-TenantDailyTotals {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$CostType, [string[]]$SubscriptionIds)
    $ids = @($SubscriptionIds | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    if (-not $ids.Count) { return 0 }
    $want = [System.Collections.Generic.HashSet[string]]::new([string[]]$ids)
    $byDate = @{}
    foreach ($r in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailysub'" -Token $StorageToken)) {
        if ([string]$r.CostType -ne $CostType) { continue }
        $sid = ([string]$r.SubscriptionId).ToLowerInvariant()
        if (-not $want.Contains($sid)) { continue }
        $d = [string]$r.Date
        if (-not $byDate.ContainsKey($d)) { $byDate[$d] = @{} }
        $byDate[$d][$sid] = $r
    }
    $entities = @()
    foreach ($d in $byDate.Keys) {
        $rows = $byDate[$d]
        if ($rows.Count -lt $ids.Count) { continue }
        $usd = 0.0; $bill = 0.0; $billOk = $true; $currencies = @{}
        foreach ($r in $rows.Values) {
            $usd += [double]$r.TotalUsd
            if ($null -ne $r.TotalBilling -and $r.Currency) { $bill += [double]$r.TotalBilling; $currencies[[string]$r.Currency] = $true }
            else { $billOk = $false }
        }
        $e = @{ PartitionKey = 'dailytotal'; RowKey = $d; Date = $d; TotalUsd = [Math]::Round($usd, 2); CostType = $CostType }
        if ($billOk -and $currencies.Count -eq 1) { $e.TotalBilling = [Math]::Round($bill, 2); $e.Currency = @($currencies.Keys)[0] }
        $entities += $e
    }
    if ($entities.Count) { Set-TableEntityBatch -Table 'CostSummary' -Entities $entities -Token $StorageToken }
    return $entities.Count
}

# CostSummary 'monthly-sub' (one row per subscription and month), derived from the daily rows
# instead of a 13-month query per subscription every night — that query alone was ~1,100 QPU a
# night on a 42-subscription tenant, nearly twice the hourly quota. A past month is written once
# every day of it is present; the current month as month-to-date. Its reader
# (SyncCommitments-Timer) only uses each subscription's latest month.
function Update-MonthlySubRows {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$CostType,
          [array]$Subscriptions, [datetime]$Settled)
    $names = @{}; foreach ($s in @($Subscriptions)) { $names[([string]$s.Id).ToLowerInvariant()] = [string]$s.Name }
    if (-not $names.Count) { return 0 }
    $groups = @{}
    foreach ($r in @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'dailysub'" -Token $StorageToken)) {
        if ([string]$r.CostType -ne $CostType) { continue }
        $sid = ([string]$r.SubscriptionId).ToLowerInvariant()
        if (-not $names.ContainsKey($sid)) { continue }
        $k = "$(([string]$r.Date).Substring(0, 7))|$sid"
        if (-not $groups.ContainsKey($k)) { $groups[$k] = [System.Collections.Generic.List[object]]::new() }
        $groups[$k].Add($r)
    }
    $entities = @()
    foreach ($k in $groups.Keys) {
        $month, $sid = $k -split '\|', 2
        $rows = $groups[$k]
        $mStart = ConvertFrom-DayString "$month-01"
        $need = $mStart.AddMonths(1).AddDays(-1); if ($need -gt $Settled) { $need = $Settled }
        $have = [System.Collections.Generic.HashSet[string]]::new([string[]]@($rows | ForEach-Object { [string]$_.Date }))
        $complete = $true
        for ($d = $mStart; $d -le $need; $d = $d.AddDays(1)) { if (-not $have.Contains((ConvertTo-DayString $d))) { $complete = $false; break } }
        if (-not $complete) { continue }
        $usd = 0.0; $bill = 0.0; $billOk = $true; $cur = $null
        foreach ($r in $rows) {
            $usd += [double]$r.TotalUsd
            if ($null -ne $r.TotalBilling -and $r.Currency) { $bill += [double]$r.TotalBilling; $cur = [string]$r.Currency } else { $billOk = $false }
        }
        $e = @{ PartitionKey = 'monthly-sub'; RowKey = "$month|$sid"; Month = $month; SubscriptionId = $sid
                SubscriptionName = $names[$sid]; CostUsd = [Math]::Round($usd, 2); UpdatedAt = ([datetime]::UtcNow.ToString('o')) }
        if ($billOk -and $cur) { $e.CostBilling = [Math]::Round($bill, 2); $e.Currency = $cur }
        $entities += $e
    }
    if ($entities.Count) { Set-TableEntityBatch -Table 'CostSummary' -Entities $entities -Token $StorageToken }
    return $entities.Count
}

# Re-total everything for the current scope and record which scope the history now describes
# (GetMonthOverview / GetCostTrend / GetPortalConfig report "scope pending" until this matches).
function Update-CostTotals {
    param([Parameter(Mandatory)][string]$StorageToken, [datetime]$Today = [datetime]::UtcNow.Date)
    $costType = Get-CostTypeSetting -StorageToken $StorageToken
    $subs = @(Get-InScopeSubscriptions -StorageToken $StorageToken)
    $w = Get-CostIngestWindow -StorageToken $StorageToken -Today $Today
    $days = Update-TenantDailyTotals -StorageToken $StorageToken -CostType $costType -SubscriptionIds @($subs.Id)
    $months = Update-MonthlySubRows -StorageToken $StorageToken -CostType $costType -Subscriptions $subs -Settled $w.Settled
    $scope = Get-SubscriptionScope -Token $StorageToken
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'backfill'; RowKey = 'dailytotal90'
        CostType = $costType; IncludesBilling = $true; ScopeHash = $scope.Hash; At = ([datetime]::UtcNow.ToString('o')) }
    return [PSCustomObject]@{ Days = $days; Months = $months; Subscriptions = $subs.Count }
}

# ---------------------------------------------------------------------------------------------
# The nightly run
# ---------------------------------------------------------------------------------------------
function Start-CostIngestRun {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$MgmtToken, [datetime]$Today = [datetime]::UtcNow.Date)
    $all = @(Get-AccessibleSubscriptions -MgmtToken $MgmtToken)
    if ($all.Count) {
        # Everything the identity can see — the list Setup/Set-SubscriptionScope.ps1 offers.
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{
            PartitionKey = 'subscriptions'; RowKey = 'discovered'
            SubscriptionsJson = (@($all | Sort-Object Name | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name } }) | ConvertTo-Json -Compress -AsArray)
            Count = $all.Count; At = ([datetime]::UtcNow.ToString('o'))
        }
    }
    $subs = @(Get-InScopeSubscriptions -StorageToken $StorageToken)
    $costType = Get-CostTypeSetting -StorageToken $StorageToken
    $w = Get-CostIngestWindow -StorageToken $StorageToken -Today $Today
    $runId = [datetime]::UtcNow.ToString('yyyyMMddHHmmss')
    $run = @{
        PartitionKey = 'ingestrun'; RowKey = 'current'; RunId = $runId; Date = (ConvertTo-DayString $Today)
        StartedAt = ([datetime]::UtcNow.ToString('o')); FinishedAt = ''
        Status = if ($subs.Count) { 'running' } else { 'done' }
        Total = $subs.Count; CostType = $costType; ScopeHash = (Get-SubscriptionScope -Token $StorageToken).Hash
        From = (ConvertTo-DayString $w.From); To = (ConvertTo-DayString $w.To)
        SubsJson = (ConvertTo-JsonList @($subs | ForEach-Object { [ordered]@{ id = $_.Id; name = $_.Name } }))
    }
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity $run
    if (-not $subs.Count) {
        Write-Host "No accessible subscriptions in scope. Grant the identity Cost Management Reader + Reader at a management group (Assign-AzureRbac.ps1 -ManagementGroupId)."
        return [PSCustomObject]$run
    }
    foreach ($s in $subs) {
        Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message @{ kind = 'recent'; runId = $runId; subId = $s.Id; subName = $s.Name; attempt = 1 }
    }
    Write-Host "Cost ingest run $runId started: $($subs.Count) subscription(s), window $($run.From)..$($run.To), $costType."
    return [PSCustomObject]$run
}

function Get-RunTaskResults {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$RunId)
    return @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'ingestrun-sub' and RowKey ge '$RunId|' and RowKey lt '$RunId|~'" -Token $StorageToken)
}

function Invoke-RecentCostTask {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$MgmtToken)
    $run = Get-CostIngestRun -StorageToken $StorageToken
    if (-not $run -or [string]$run.RunId -ne [string]$Task.runId -or [string]$run.Status -ne 'running') {
        Write-Host "  [$($Task.subName)] task for run $($Task.runId) is stale (current run: $($run.RunId), $($run.Status)) — skipped."
        return
    }
    $from = ConvertFrom-DayString ([string]$run.From); $to = ConvertFrom-DayString ([string]$run.To)
    $w = Get-CostIngestWindow -StorageToken $StorageToken -Today (ConvertFrom-DayString ([string]$run.Date))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = @{ PartitionKey = 'ingestrun-sub'; RowKey = "$($run.RunId)|$($Task.subId)"; SubscriptionId = [string]$Task.subId
                 SubscriptionName = [string]$Task.subName; Attempts = [int]$Task.attempt; At = ([datetime]::UtcNow.ToString('o')) }
    try {
        $r = Get-SubscriptionDailyCost -SubscriptionId $Task.subId -MgmtToken $MgmtToken -From $from -To $to -CostType ([string]$run.CostType)
        Write-CostSnapshotRows -Rows $r.Rows -StorageToken $StorageToken
        $days = ConvertTo-DailySubEntities -SubscriptionId ([string]$Task.subId) -Days $r.Days -From $from -To $to -Settled $w.Settled -CostType ([string]$run.CostType) -Currency $r.Currency
        Set-TableEntityBatch -Table 'CostSummary' -Entities @($days) -Token $StorageToken
        $result.Status = 'ok'; $result.Rows = @($r.Rows).Count; $result.Currency = if ($r.Currency) { [string]$r.Currency } else { '' }; $result.Error = ''
        Write-Host "  [$($Task.subName)] $(@($r.Rows).Count) (date,resource) rows, $(@($days).Count) day total(s) in $([int]$sw.Elapsed.TotalSeconds)s."
    } catch {
        $msg = $_.Exception.Message
        if ([int]$Task.attempt -lt $script:MaxTaskAttempts) {
            # Put it back rather than sleep here: the worker moves on, and the quota recovers meanwhile.
            $delay = if (Test-CostQueryThrottled -ErrorRecord $msg) { 120 * [int]$Task.attempt } else { 60 * [int]$Task.attempt }
            Write-Host "  [$($Task.subName)] attempt $($Task.attempt) failed after $([int]$sw.Elapsed.TotalSeconds)s: $msg — retrying in ${delay}s."
            $next = @{ kind = 'recent'; runId = $Task.runId; subId = $Task.subId; subName = $Task.subName; attempt = [int]$Task.attempt + 1 }
            Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message $next -DelaySeconds $delay
            return
        }
        Write-Host "  [$($Task.subName) / $($Task.subId)] FAILED after $($Task.attempt) attempts: $msg — its cost is missing from this run."
        $result.Status = 'failed'; $result.Rows = 0; $result.Currency = ''; $result.Error = $msg
    }
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity $result
    if (@(Get-RunTaskResults -StorageToken $StorageToken -RunId ([string]$run.RunId)).Count -ge [int]$run.Total) {
        Complete-CostIngestRun -StorageToken $StorageToken -MgmtToken $MgmtToken -Run $run
    }
}

# Totals, retention and the 'ingest/lastrun' marker the analysis timers wait for. Called by the
# last task of a run, or by the planner for a run whose tasks went missing.
function Complete-CostIngestRun {
    param([Parameter(Mandatory)][string]$StorageToken, [string]$MgmtToken, [Parameter(Mandatory)]$Run, [string]$Reason = '')
    $results = @(Get-RunTaskResults -StorageToken $StorageToken -RunId ([string]$Run.RunId))
    $ok = @($results | Where-Object { $_.Status -eq 'ok' })
    $total = [int]$Run.Total
    $complete = ($ok.Count -eq $total)
    $w = Get-CostIngestWindow -StorageToken $StorageToken -Today (ConvertFrom-DayString ([string]$Run.Date))
    $subs = @(ConvertFrom-JsonList ([string]$Run.SubsJson) | ForEach-Object { [PSCustomObject]@{ Id = [string]$_.id; Name = [string]$_.name } })

    $days = 0; $months = 0
    try {
        $days = Update-TenantDailyTotals -StorageToken $StorageToken -CostType ([string]$Run.CostType) -SubscriptionIds @($subs.Id)
        $months = Update-MonthlySubRows -StorageToken $StorageToken -CostType ([string]$Run.CostType) -Subscriptions $subs -Settled $w.Settled
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'backfill'; RowKey = 'dailytotal90'
            CostType = [string]$Run.CostType; IncludesBilling = $true; ScopeHash = [string]$Run.ScopeHash; At = ([datetime]::UtcNow.ToString('o')) }
    } catch { Write-Host "Tenant totals failed (non-fatal, recomputed next run): $($_.Exception.Message)" }

    Invoke-SnapshotRetention -StorageToken $StorageToken -Window $w

    $currency = @($ok | Where-Object { $_.Currency } | ForEach-Object { [string]$_.Currency } | Select-Object -First 1)
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{
        PartitionKey = 'ingest'; RowKey = 'lastrun'; At = ([datetime]::UtcNow.ToString('o'))
        WindowFrom = [string]$Run.From; WindowTo = [string]$Run.To
        SubscriptionsTotal = $total; SubscriptionsOk = $ok.Count
        RowsIngested = [int](($ok | Measure-Object -Property Rows -Sum).Sum)
        CostType = [string]$Run.CostType
        # Read by SyncAdvisor-Timer: amounts without a stated currency are converted on this basis.
        BillingCurrency = if ($currency) { $currency[0] } else { '' }
        TotalsComplete = [bool]$complete; Complete = [bool]$complete
    }
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'ingestrun'; RowKey = 'current'
        Status = 'done'; FinishedAt = ([datetime]::UtcNow.ToString('o')); Ok = $ok.Count; Note = $Reason }
    $failed = @($results | Where-Object { $_.Status -ne 'ok' } | ForEach-Object { $_.SubscriptionName })
    $missing = $total - $results.Count
    Write-Host ("=== Cost ingest run $($Run.RunId) finished: $($ok.Count)/$total subscription(s), $days day total(s), $months month row(s)" +
        $(if ($failed.Count) { "; failed: $($failed -join ', ')" } else { '' }) +
        $(if ($missing -gt 0) { "; $missing never reported" } else { '' }) +
        $(if ($Reason) { " ($Reason)" } else { '' }) + ' ===')

    # Previous runs' task results are no longer needed.
    try {
        $old = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'ingestrun-sub' and RowKey lt '$($Run.RunId)|'" -Select 'PartitionKey,RowKey' -Top 1000 -Token $StorageToken)
        if ($old.Count) { $null = Remove-TableEntityBatch -Table 'PortalConfig' -Entities $old -Token $StorageToken }
    } catch {}

    # The run is the critical path; history only starts once it is done.
    try { $null = Update-CostHistoryPlan -StorageToken $StorageToken } catch { Write-Host "History planning failed (retried hourly): $($_.Exception.Message)" }
}

# CostSnapshots retention. Only the detectors read these rows, over their recent windows; the
# permanent history is CostSummary. Capped per run: a long-unpruned table drains over a few nights.
function Invoke-SnapshotRetention {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)]$Window)
    if ($Window.RetentionDays -le 0) { Write-Host "Snapshot retention disabled (SnapshotRetentionDays = $($Window.RetentionDays))."; return }
    $cutoff = ConvertTo-DayString ($Window.To.AddDays(-$Window.EffectiveRetention))
    $max = 20000
    try {
        $stale = @(Get-TableEntities -Table 'CostSnapshots' -Filter "PartitionKey lt '$cutoff'" -Select 'PartitionKey,RowKey' -Top $max -Token $StorageToken)
        if ($stale.Count) {
            $removed = Remove-TableEntityBatch -Table 'CostSnapshots' -Entities $stale -Token $StorageToken
            Write-Host "Snapshot retention: deleted $removed row(s) older than $cutoff$(if ($stale.Count -ge $max) { ' (capped; the rest goes next run)' })."
        }
    } catch { Write-Host "Snapshot retention failed (non-fatal, retries next run): $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------------------------
# The one-time history (and its refetch after a cost-type change or a subscription added to scope)
# ---------------------------------------------------------------------------------------------
# State: PortalConfig backfill/history
#   CostType     the basis the stored history is on
#   Covered      subscriptions whose history is complete
#   Pending      subscriptions being fetched now ([] = nothing to do)
#   Done         months (yyyy-MM) already fetched for Pending
#   InFlight / InFlightAt   the month task on the queue
#   Gen          bumped on every restart, so a task from an abandoned plan is ignored
function Update-CostHistoryPlan {
    param([Parameter(Mandatory)][string]$StorageToken, [datetime]$Today = [datetime]::UtcNow.Date)
    $w = Get-CostIngestWindow -StorageToken $StorageToken -Today $Today
    if (-not $w.HistoryFrom) { return 'disabled' }
    $costType = Get-CostTypeSetting -StorageToken $StorageToken
    $subs = @(Get-InScopeSubscriptions -StorageToken $StorageToken)
    if (-not $subs.Count) { return 'no-subscriptions' }
    $ids = @($subs.Id)
    $state = Get-CostHistoryState -StorageToken $StorageToken

    $covered = @(ConvertFrom-JsonList ([string]$state.Covered)); $pending = @(ConvertFrom-JsonList ([string]$state.Pending))
    $done = @(ConvertFrom-JsonList ([string]$state.Done)); $gen = if ($state) { [int]$state.Gen } else { 0 }
    if (-not $state -or [string]$state.CostType -ne $costType) {
        if ($state) { Write-Host "Cost history: cost type is now $costType (was $($state.CostType)) — refetching the history on the new basis." }
        $covered = @(); $pending = $ids; $done = @(); $gen++
    } elseif (-not $pending.Count) {
        $missing = @($ids | Where-Object { $covered -notcontains $_ })
        if ($missing.Count) {
            Write-Host "Cost history: $($missing.Count) subscription(s) without history (new, or added to the scope) — fetching theirs."
            $pending = $missing; $done = @(); $gen++
        }
    }
    $save = @{ PartitionKey = 'backfill'; RowKey = 'history'; CostType = $costType; Gen = $gen
               Covered = (ConvertTo-JsonList $covered); Pending = (ConvertTo-JsonList $pending); Done = (ConvertTo-JsonList $done) }
    if (-not $pending.Count) {
        if ($state -and [string]$state.Pending -eq '[]' -and [string]$state.CostType -eq $costType) { return 'complete' }
        $save.InFlight = ''; $save.Complete = $true
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity $save
        return 'complete'
    }

    # Newest month first: the detectors' weekly windows need the last 35 days before anything older.
    $months = @(Get-MonthSlices -From $w.HistoryFrom -To $w.From.AddDays(-1) | Sort-Object Month -Descending)
    $next = $months | Where-Object { $done -notcontains $_.Month } | Select-Object -First 1
    if (-not $next) {
        $save.Covered = (ConvertTo-JsonList (@($covered + $pending) | Sort-Object -Unique)); $save.Pending = '[]'; $save.Done = '[]'
        $save.InFlight = ''; $save.Complete = $true; $save.CompletedAt = ([datetime]::UtcNow.ToString('o'))
        Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity $save
        Write-Host "Cost history complete for $($pending.Count) subscription(s) — running the analysis on it now."
        Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message @{ kind = 'followup'; steps = $script:FollowupSteps; attempt = 1 }
        return 'completed'
    }
    $inFlightAt = ConvertFrom-IsoTime ([string]$state.InFlightAt)
    if ($state -and [string]$state.InFlight -and [int]$state.Gen -eq $gen -and $inFlightAt -and
        ([datetime]::UtcNow - $inFlightAt).TotalMinutes -lt $script:HistoryStaleMinutes) {
        return 'in-flight'
    }
    $save.Complete = $false; $save.InFlight = $next.Month; $save.InFlightAt = ([datetime]::UtcNow.ToString('o'))
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity $save
    Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message @{
        kind = 'history'; month = $next.Month; from = (ConvertTo-DayString $next.From); to = (ConvertTo-DayString $next.To)
        gen = $gen; attempt = 1 }
    Write-Host "Cost history: queued $($next.Month) for $($pending.Count) subscription(s) ($(@($done).Count)/$($months.Count) month(s) done)."
    return 'queued'
}

function Invoke-HistoryCostTask {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$MgmtToken)
    $state = Get-CostHistoryState -StorageToken $StorageToken
    if (-not $state -or [int]$state.Gen -ne [int]$Task.gen -or [string]$state.InFlight -ne [string]$Task.month) {
        Write-Host "History task $($Task.month) (gen $($Task.gen)) is stale — skipped."
        return
    }
    $costType = [string]$state.CostType
    $pending = @(ConvertFrom-JsonList ([string]$state.Pending))
    $names = @{}; foreach ($s in @(Get-InScopeSubscriptions -StorageToken $StorageToken)) { $names[$s.Id] = $s.Name }
    $from = ConvertFrom-DayString ([string]$Task.from); $to = ConvertFrom-DayString ([string]$Task.to)
    $w = Get-CostIngestWindow -StorageToken $StorageToken
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Cost history $($Task.month) ($($Task.from)..$($Task.to)): $($pending.Count) subscription(s), attempt $($Task.attempt)."

    # Staged in memory and written only when every subscription answered (see the module header).
    $rows = [System.Collections.Generic.List[object]]::new()
    $days = [System.Collections.Generic.List[object]]::new()
    $failure = $null
    foreach ($sid in $pending) {
        if ($sw.Elapsed.TotalMinutes -ge $script:HistoryDeadlineMinutes) { $failure = "deadline reached after $([int]$sw.Elapsed.TotalMinutes) minute(s)"; break }
        try {
            $r = Get-SubscriptionDailyCost -SubscriptionId $sid -MgmtToken $MgmtToken -From $from -To $to -CostType $costType
            foreach ($x in @($r.Rows)) { $rows.Add($x) }
            foreach ($x in @(ConvertTo-DailySubEntities -SubscriptionId $sid -Days $r.Days -From $from -To $to -Settled $w.Settled -CostType $costType -Currency $r.Currency)) { $days.Add($x) }
        } catch { $failure = "[$($names[$sid])] $($_.Exception.Message)"; break }
    }
    if ($failure) {
        if ([int]$Task.attempt -lt $script:MaxTaskAttempts) {
            $delay = 300 * [int]$Task.attempt
            Write-Host "Cost history $($Task.month) not complete ($failure) — nothing written, retrying in ${delay}s."
            Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'backfill'; RowKey = 'history'; InFlightAt = ([datetime]::UtcNow.AddSeconds($delay).ToString('o')) }
            $next = @{ kind = 'history'; month = $Task.month; from = $Task.from; to = $Task.to; gen = $Task.gen; attempt = [int]$Task.attempt + 1 }
            Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message $next -DelaySeconds $delay
        } else {
            Write-Host "Cost history $($Task.month) gave up after $($Task.attempt) attempts ($failure). The planner tries again in an hour."
            Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'backfill'; RowKey = 'history'; InFlight = '' }
        }
        return
    }

    Write-CostSnapshotRows -Rows @($rows) -StorageToken $StorageToken
    Set-TableEntityBatch -Table 'CostSummary' -Entities @($days) -Token $StorageToken
    $done = @(@(ConvertFrom-JsonList ([string]$state.Done)) + [string]$Task.month | Sort-Object -Unique)
    Set-TableEntity -Table 'PortalConfig' -Token $StorageToken -Entity @{ PartitionKey = 'backfill'; RowKey = 'history'
        Done = (ConvertTo-JsonList $done); InFlight = '' }
    Write-Host "Cost history $($Task.month): wrote $($rows.Count) resource row(s) and $($days.Count) day total(s) in $([int]$sw.Elapsed.TotalSeconds)s."
    try { $t = Update-CostTotals -StorageToken $StorageToken; Write-Host "  tenant totals: $($t.Days) day(s), $($t.Months) month row(s)." }
    catch { Write-Host "  tenant totals failed (recomputed by the next run): $($_.Exception.Message)" }
    Update-CostHistoryPlan -StorageToken $StorageToken | Out-Null
}

# After the first history: the nightly analysis, now, on the complete data — one step per task so
# each gets its own invocation (and timeout). The timer scripts are run as they are; the brief is
# regenerated (Force), since the one built on the thin first night would otherwise stand all week.
function Invoke-FollowupCostTask {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$StorageToken)
    $steps = @($Task.steps | ForEach-Object { [string]$_ })
    if (-not $steps.Count) { return }
    $step = $steps[0]
    if ($script:FollowupSteps -notcontains $step) { Write-Host "Follow-up step '$step' is not allowed — skipped."; $step = $null }
    if ($step) {
        Write-Host "--- follow-up: $step ---"
        try {
            if ($step -eq 'brief') {
                foreach ($grain in @('week', 'month')) {
                    $null = Update-PortfolioBrief -Grain $grain -Token $StorageToken -Force -SkipAi:($grain -eq 'month')
                }
            } else {
                $script = Join-Path (Split-Path -Parent $PSScriptRoot) "$step/run.ps1"
                & $script -Timer $null
            }
        } catch { Write-Host "Follow-up step $step failed: $($_.Exception.Message)" }
    }
    if ($steps.Count -gt 1) {
        Add-QueueMessage -Queue $script:Queue -Token $StorageToken -Message @{ kind = 'followup'; steps = @($steps | Select-Object -Skip 1); attempt = 1 }
    }
}

# ---------------------------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------------------------
function Invoke-CostTask {
    param([Parameter(Mandatory)]$Task, [Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$MgmtToken)
    switch ([string]$Task.kind) {
        'recent'   { Invoke-RecentCostTask -Task $Task -StorageToken $StorageToken -MgmtToken $MgmtToken }
        'history'  { Invoke-HistoryCostTask -Task $Task -StorageToken $StorageToken -MgmtToken $MgmtToken }
        'followup' { Invoke-FollowupCostTask -Task $Task -StorageToken $StorageToken }
        default    { Write-Host "Unknown cost task kind '$($Task.kind)' — dropped." }
    }
}

# Hourly (and on start-up, so a fresh deployment starts loading straight away). Idempotent:
# every decision is read from state, so an extra run only finds nothing to do.
function Invoke-CostIngestPlanner {
    param([Parameter(Mandatory)][string]$StorageToken, [Parameter(Mandatory)][string]$MgmtToken, [datetime]$Now = [datetime]::UtcNow)
    $run = Get-CostIngestRun -StorageToken $StorageToken
    $today = ConvertTo-DayString $Now.Date

    if ($run -and [string]$run.Status -eq 'running') {
        $started = ConvertFrom-IsoTime ([string]$run.StartedAt)
        if ($started -and ($Now - $started).TotalHours -ge $script:RunStaleHours) {
            Complete-CostIngestRun -StorageToken $StorageToken -MgmtToken $MgmtToken -Run $run -Reason "completed by the planner after $($script:RunStaleHours)h"
            return 'recovered'
        }
        Write-Host "Cost ingest run $($run.RunId) in progress ($(@(Get-RunTaskResults -StorageToken $StorageToken -RunId ([string]$run.RunId)).Count)/$($run.Total) subscription(s) reported)."
        return 'running'
    }
    # Nightly from 02:00 UTC; at any hour when nothing has ever run (a new deployment).
    if (-not $run -or ([string]$run.Date -ne $today -and $Now.Hour -ge $script:NightlyHourUtc)) {
        $null = Start-CostIngestRun -StorageToken $StorageToken -MgmtToken $MgmtToken -Today $Now.Date
        return 'started'
    }
    # A scope change: re-total from what is stored (no Cost Management queries).
    $scope = Get-SubscriptionScope -Token $StorageToken
    $marker = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'backfill' and RowKey eq 'dailytotal90'" -Token $StorageToken) | Select-Object -First 1
    if ($marker -and [string]$marker.ScopeHash -ne [string]$scope.Hash) {
        $t = Update-CostTotals -StorageToken $StorageToken -Today $Now.Date
        Write-Host "Subscription scope changed — re-totalled $($t.Days) day(s) for $($t.Subscriptions) subscription(s)."
    }
    return (Update-CostHistoryPlan -StorageToken $StorageToken -Today $Now.Date)
}

Export-ModuleMember -Function Invoke-CostIngestPlanner, Invoke-CostTask, Start-CostIngestRun, Complete-CostIngestRun, `
    Update-CostHistoryPlan, Update-CostTotals, Update-TenantDailyTotals, Update-MonthlySubRows, Get-CostIngestWindow, `
    Get-MonthSlices, ConvertTo-DailySubEntities, Get-InScopeSubscriptions
