#requires -Version 7.2
<#
.SYNOPSIS
    Choose which subscriptions the FinOps portal covers. Default: all of them.

.DESCRIPTION
    Writes the portal's SUBSCRIPTION SCOPE to its own storage (PortalConfig 'settings/scope').
    The scope applies to everything and everyone: cost ingest, cost changes, savings, Advisor,
    the Subscriptions page, forecast, budgets, the executive brief and Ask.

    What happens when you remove a subscription:
      - IMMEDIATELY: its findings, savings, Advisor recommendations, monthly history and budgets
        are hidden on every page. Nothing is deleted.
      - AFTER THE NEXT NIGHTLY RUN (from 02:00 UTC, or when you trigger it): the tenant totals —
        the 90-day daily history behind month-to-date and the trend chart, the month view, the
        forecast and the brief — are rebuilt without it. Until then the portal shows
        "subscription scope changed — totals update after tonight's run".
    Adding it back reverses both, and its per-resource history is refetched so the time it was
    excluded has no gap.

    Pick interactively (a grid on Windows, a numbered list elsewhere), or pass -Include /
    -Exclude / -All. The list offered is what the portal's managed identity can see (recorded by
    the nightly ingest); before the first ingest it falls back to what YOUR account can see.

    Writes through the Azure CLI: first with your Entra identity (needs Storage Table Data
    Contributor on the portal's storage account), otherwise with the account key (Contributor
    on the storage account is enough). The change is recorded in the portal's AuditLog.

.PARAMETER ResourceGroupName
    The portal's resource group.
.PARAMETER StorageAccountName
    Optional. Defaults to the single storage account in the resource group.
.PARAMETER Include
    Subscription ids or names to ADD to the current scope. When the scope is currently "all",
    -Include starts a new list with just these.
.PARAMETER Exclude
    Subscription ids or names to REMOVE. When the scope is currently "all", this means "every
    subscription except these".
.PARAMETER All
    Reset: cover every subscription.
.PARAMETER Show
    Print the current scope and exit.

.EXAMPLE
    ./Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst            # pick interactively
.EXAMPLE
    ./Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -Exclude 'Sandbox','Visual Studio Enterprise'
.EXAMPLE
    ./Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -All
.EXAMPLE
    ./Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -Show
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Pick')]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$StorageAccountName,
    [Parameter(ParameterSetName = 'Change')][string[]]$Include,
    [Parameter(ParameterSetName = 'Change')][string[]]$Exclude,
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [Parameter(ParameterSetName = 'Show')][switch]$Show
)

$ErrorActionPreference = 'Stop'
$table = 'PortalConfig'
$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Returns the output as one string ('' for -o none); $null only when -AllowFailure and az failed.
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $out = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments[0..2] -join ' ') … failed (exit $LASTEXITCODE)"
    }
    return ($out -join "`n")
}

# --- storage account + how we may write to it ---------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI (az) not found." }
if ($null -eq (Invoke-Az @('account', 'show', '-o', 'json') -AllowFailure)) { throw "Not logged in to Azure. Run 'az login' first." }
if (-not $StorageAccountName) {
    $names = @((Invoke-Az @('storage', 'account', 'list', '-g', $ResourceGroupName, '--query', '[].name', '-o', 'tsv')) -split "`n" | Where-Object { $_ })
    if ($names.Count -ne 1) { throw "Expected exactly one storage account in '$ResourceGroupName' (found $($names.Count)). Pass -StorageAccountName." }
    $StorageAccountName = $names[0]
}
$base = @('--account-name', $StorageAccountName, '--table-name', $table)

# Entra first; the account key when the caller has no data-plane role.
$authMode = 'login'
if ($null -eq (Invoke-Az (@('storage', 'entity', 'query') + $base + @('--auth-mode', 'login', '--num-results', '1', '-o', 'none')) -AllowFailure)) {
    $authMode = 'key'
    if ($null -eq (Invoke-Az (@('storage', 'entity', 'query') + $base + @('--auth-mode', 'key', '--num-results', '1', '-o', 'none')) -AllowFailure)) {
        throw "Cannot read the '$table' table in '$StorageAccountName' with your Entra identity or the account key. You need Storage Table Data Contributor, or Contributor on the storage account."
    }
}
$auth = @('--auth-mode', $authMode)

function Get-Entity { param([string]$Pk, [string]$Rk)
    $j = Invoke-Az (@('storage', 'entity', 'show') + $base + $auth + @('--partition-key', $Pk, '--row-key', $Rk, '-o', 'json')) -AllowFailure
    if ($j) { return ($j | ConvertFrom-Json) } else { return $null }
}

# --- what can be chosen, and what is chosen now -----------------------------------
$discovered = @()
$disc = Get-Entity 'subscriptions' 'discovered'
if ($disc -and $disc.SubscriptionsJson) { $discovered = @([string]$disc.SubscriptionsJson | ConvertFrom-Json) }
$source = "the portal's managed identity (last ingest $($disc.At))"
if (-not $discovered.Count) {
    $discovered = @((Invoke-Az @('account', 'list', '--query', "[?state=='Enabled'].{id:id,name:name}", '-o', 'json')) | ConvertFrom-Json)
    $source = "YOUR account (the portal hasn't run its first ingest yet, so it may see more or fewer)"
}
$discovered = @($discovered | Sort-Object name)
$nameOf = @{}; foreach ($d in $discovered) { $nameOf[([string]$d.id).ToLowerInvariant()] = [string]$d.name }

$current = @()
$row = Get-Entity 'settings' 'scope'
if ($row -and $row.IncludedSubscriptionIds) {
    $raw = ([string]$row.IncludedSubscriptionIds).Trim()
    $current = if ($raw.StartsWith('[')) { @($raw | ConvertFrom-Json) } else { @($raw -split '[,;\s]+') }
    $current = @($current | Where-Object { $_ -match $guidPattern } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
}

function Format-Scope { param([string[]]$Ids)
    if (-not $Ids -or -not $Ids.Count) { return "ALL subscriptions ($($discovered.Count) visible)" }
    return "$($Ids.Count) of $($discovered.Count):`n" + (($Ids | ForEach-Object { "  - $(if ($nameOf[$_]) { $nameOf[$_] } else { '(not visible)' })  $_" }) -join "`n")
}

Write-Host "Storage account : $StorageAccountName (auth: $authMode)"
Write-Host "Subscriptions   : from $source"
Write-Host "Current scope   : $(Format-Scope $current)"
if ($Show) { return }

# Resolve ids or names (case-insensitive) against the list.
function Resolve-Subscriptions { param([string[]]$Values)
    foreach ($v in @($Values | Where-Object { $_ })) {
        $hit = @($discovered | Where-Object { [string]$_.id -eq $v -or [string]$_.name -eq $v })
        if (-not $hit.Count -and $v -match $guidPattern) { $v.ToLowerInvariant(); continue }
        if ($hit.Count -ne 1) { throw "'$v' matches $($hit.Count) subscription(s). Use the subscription id." }
        ([string]$hit[0].id).ToLowerInvariant()
    }
}

# --- the new scope -----------------------------------------------------------------
$allIds = @($discovered | ForEach-Object { ([string]$_.id).ToLowerInvariant() })
if ($All) {
    $new = @()
} elseif ($PSCmdlet.ParameterSetName -eq 'Change') {
    $start = if ($current.Count) { $current } elseif ($Exclude -and -not $Include) { $allIds } else { @() }
    $add = @(Resolve-Subscriptions $Include)
    $remove = @(Resolve-Subscriptions $Exclude)
    $new = @(@($start) + $add | Where-Object { $_ -and $remove -notcontains $_ } | Sort-Object -Unique)
    if (-not $new.Count) { throw "That would leave no subscriptions. Use -All to cover every subscription." }
} else {
    # Interactive pick. Everything in the current scope (or everything, for ALL) starts selected.
    $selectedNow = if ($current.Count) { $current } else { $allIds }
    $rows = @($discovered | ForEach-Object {
        [PSCustomObject]@{ Included = if ($selectedNow -contains ([string]$_.id).ToLowerInvariant()) { 'yes' } else { '' }; Name = [string]$_.name; Id = [string]$_.id }
    })
    $picked = $null
    if ($IsWindows -and (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
        try {
            $picked = @($rows | Out-GridView -Title 'Select the subscriptions the portal should cover (Ctrl+click for several), then OK' -OutputMode Multiple)
        } catch { $picked = $null }
    }
    if ($null -eq $picked) {
        for ($i = 0; $i -lt $rows.Count; $i++) { Write-Host ("{0,3}. [{1}] {2}  {3}" -f ($i + 1), $(if ($rows[$i].Included) { 'x' } else { ' ' }), $rows[$i].Name, $rows[$i].Id) }
        $answer = Read-Host "Numbers to include (e.g. 1,3,5), 'all', or Enter to keep the current scope"
        if ([string]::IsNullOrWhiteSpace($answer)) { Write-Host 'No change.'; return }
        if ($answer.Trim() -ieq 'all') { $picked = $rows }
        else {
            $picked = @(foreach ($n in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
                $k = 0
                if (-not [int]::TryParse($n, [ref]$k) -or $k -lt 1 -or $k -gt $rows.Count) { throw "'$n' is not a number from the list." }
                $rows[$k - 1]
            })
        }
    }
    if (-not $picked.Count) { Write-Host 'Nothing selected — no change.'; return }
    $new = @($picked | ForEach-Object { ([string]$_.Id).ToLowerInvariant() } | Sort-Object -Unique)
}
# Every visible subscription selected = ALL, so subscriptions added to the tenant later are
# covered too instead of being silently left out of a list that happened to be complete.
if ($new.Count -and $allIds.Count -and -not @($allIds | Where-Object { $new -notcontains $_ }).Count) { $new = @() }

$unchanged = (($new -join ',') -eq ($current -join ','))
Write-Host ""
Write-Host "New scope       : $(Format-Scope $new)"
if ($unchanged) { Write-Host 'No change.'; return }

$removed = @($(if ($current.Count) { $current } else { $allIds }) | Where-Object { $new.Count -and $new -notcontains $_ })
$added = @($(if ($new.Count) { $new } else { $allIds }) | Where-Object { $current.Count -and $current -notcontains $_ })
if ($removed.Count) { Write-Host "Removed         : $(($removed | ForEach-Object { if ($nameOf[$_]) { $nameOf[$_] } else { $_ } }) -join ', ')" }
if ($added.Count) { Write-Host "Added           : $(($added | ForEach-Object { if ($nameOf[$_]) { $nameOf[$_] } else { $_ } }) -join ', ')" }

if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$table settings/scope", 'Set the portal subscription scope')) { return }

# The hash must match Get-SubscriptionScopeHash in src/function-app/profile.ps1: the first 16
# hex characters of SHA-256 over the sorted, lower-cased ids joined by ',' ('all' when empty).
$hash = 'all'
if ($new.Count) {
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes(($new | Sort-Object) -join ','))
    $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
}
$who = (Invoke-Az @('account', 'show', '--query', 'user.name', '-o', 'tsv')).Trim()
$now = [datetime]::UtcNow.ToString('o')

# Comma-separated ids: no JSON quoting to survive the shell. '' = ALL (replace, so an old list
# can't linger).
Invoke-Az (@('storage', 'entity', 'insert') + $base + $auth + @('--if-exists', 'replace', '-o', 'none', '--entity',
    'PartitionKey=settings', 'RowKey=scope', "IncludedSubscriptionIds=$($new -join ',')", "ScopeHash=$hash",
    "UpdatedBy=$who", "UpdatedAt=$now")) | Out-Null

# Audit trail, same table and shape the API writes (Write-AuditEntry).
$detail = "included=$(if ($new.Count) { $new.Count } else { 'all' }); removed=$($removed -join ' '); added=$($added -join ' ')"
Invoke-Az (@('storage', 'entity', 'insert') + @('--account-name', $StorageAccountName, '--table-name', 'AuditLog') + $auth + @('-o', 'none', '--entity',
    "PartitionKey=$([datetime]::UtcNow.ToString('yyyy-MM'))", "RowKey=$now-$([guid]::NewGuid().ToString('N').Substring(0, 8))",
    'Action=SetSubscriptionScope', "Upn=$($who.ToLowerInvariant())", 'Target=settings/scope', "Details=$detail", "At=$now")) -AllowFailure | Out-Null

Write-Host ""
Write-Host "Saved." -ForegroundColor Green
Write-Host "  Now          : excluded subscriptions are hidden on every page (refresh the portal)."
Write-Host "  Within an hour: daily totals are re-totalled for the new set (PlanCostIngest-Timer); a subscription added back gets its history fetched."
Write-Host "  Tonight      : forecast, detection and the brief follow (02:00-03:15 UTC)."
Write-Host "  Sooner       : ./Tools/Invoke-SpikeDetection.ps1 -ResourceGroupName $ResourceGroupName -FunctionAppName <api-app> ``"
Write-Host "                   -Functions DetectCostSpikes-Timer,DetectSavings-Timer,SyncAdvisor-Timer,SyncCommitments-Timer,SyncMonthlyCosts-Timer,SyncAllocation-Timer,BuildBrief-Timer"
