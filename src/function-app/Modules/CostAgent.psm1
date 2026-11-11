# ============================================================================
# CostAgent.psm1 — the weekly / monthly key findings at the top of the Overview.
#
# The brief payload (Brief.psm1) already holds what code can work out on its own: spend against
# last month, the largest cost changes with their evidence, open savings, spend per owner and
# per resource group. The agent starts from that and may run READ-ONLY tools to check and size
# what it sees (Invoke-AiAgent):
#
#   cost_query        the Ask allowlist (Invoke-CostQuery / Invoke-CostComparison), group by the
#                     owner tag as well
#   change_evidence   the stored evidence for one cost change (C-…)
#   saving_detail     the stored detail of one saving (S-… / A-…)
#
# It returns 3–6 findings: priority, owner, cost and estimated saving, a proposed action and an
# optional command (shown to a person, never run). Before anything is kept:
#   - every finding must cite at least one known id or tool call,
#   - every figure in it must appear in the payload or in a tool result (Test-NarrativeGrounding);
#     a finding that fails is dropped, not shown with a warning.
#
# PRIVACY: owner names and subscription names / ids never reach the model. They are replaced by
# tokens (OWNER_1, SUBN_1, ID_1) before the payload and every tool result is sent, tool
# arguments are mapped back before a query runs, and the answer is mapped back afterwards.
#
# Without AI (not configured, over the daily limit, or failing) Get-RuleFindings ranks the same
# payload by amount, so the page always has findings.
# ============================================================================

$script:NonProdTokens = @('dev', 'devel', 'development', 'test', 'tst', 'testing', 'qa', 'uat', 'acc', 'acceptance',
    'stg', 'stage', 'staging', 'sandbox', 'sbx', 'poc', 'lab', 'demo', 'nonprod', 'trial', 'int', 'integration', 'tmp', 'temp')
$script:ProdTokens = @('prod', 'prd', 'production', 'live', 'prodution')

# 'non-production' | 'production' | 'unknown' from a name such as a resource group:
# any dash/underscore/dot-separated part that names an environment decides it.
function Get-EnvironmentGuess {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'unknown' }
    $parts = @(([string]$Name).ToLowerInvariant() -split '[-_.\s/()]+' | Where-Object { $_ })
    foreach ($p in $parts) { if ($script:NonProdTokens -contains $p) { return 'non-production' } }
    foreach ($p in $parts) { if ($script:ProdTokens -contains $p) { return 'production' } }
    return 'unknown'
}

# ----------------------------------------------------------------------------
# Owners and resource groups for the payload (from SyncAllocation-Timer's rollup).
# ----------------------------------------------------------------------------
function Get-AllocationRows {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][string]$Dimension)
    $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'allocation' and RowKey eq '$(ConvertTo-ODataLiteral -Value $Dimension)'" -Token $Token) | Select-Object -First 1
    if (-not $row -or -not $row.RowsJson) { return @() }
    try { return @([string]$row.RowsJson | ConvertFrom-Json) } catch { return @() }
}

# Spend per owner this month (to the settled day) and the open savings that belong to them.
# -Savings: every open saving (Get-BriefSavings items, with owner).
function Get-InsightOwners {
    param([Parameter(Mandatory)][string]$Token, [object[]]$Savings = @(), [int]$Top = 12)
    $ownerKey = @(Get-AllocationTagKeys -StorageToken $Token)[0]
    if (-not $ownerKey) { return @() }
    $rows = @(Get-AllocationRows -Token $Token -Dimension "tag:$ownerKey")
    $byOwner = @{}
    foreach ($s in @($Savings)) {
        $o = [string]$s.owner; if (-not $o) { $o = '(untagged)' }
        if (-not $byOwner.ContainsKey($o)) { $byOwner[$o] = @{ usd = 0.0; n = 0 } }
        $byOwner[$o].usd += [double]$s.monthlyUsd; $byOwner[$o].n++
    }
    $i = 0
    return @($rows | Select-Object -First $Top | ForEach-Object {
        $i++
        $k = [string]$_.key
        # No savings on '(untagged)' and the other placeholder rows: what is untagged is mostly
        # billing-scope purchase recommendations with no resource behind them, so the sum can't
        # be traced to anything a missing owner could act on.
        $sv = if ($k -like '(*') { $null } else { $byOwner[$k] }
        [PSCustomObject]@{
            id = "O-$i"; owner = $k
            currentUsd = [double]$_.currentUsd; previousSameDaysUsd = [double]$_.previousSameDaysUsd
            previousMonthUsd = [double]$_.previousMonthUsd; deltaPct = $_.deltaPct; sharePct = [double]$_.sharePct
            resources = [int]$_.resources
            openSavingsUsd = if ($k -like '(*') { $null } elseif ($sv) { [Math]::Round($sv.usd, 2) } else { 0.0 }
            openSavingsCount = if ($k -like '(*') { $null } elseif ($sv) { [int]$sv.n } else { 0 }
        }
    })
}

# Spend per resource group this month, with a guess at its environment.
function Get-InsightResourceGroups {
    param([Parameter(Mandatory)][string]$Token, [int]$Top = 12)
    $subScope = Get-SubscriptionScope -Token $Token
    $rows = @(Get-AllocationRows -Token $Token -Dimension 'resourceGroup' |
        Where-Object { -not $_.subscriptionId -or (Test-InSubscriptionScope -Scope $subScope -Value ([string]$_.subscriptionId)) })
    $i = 0
    return @($rows | Select-Object -First $Top | ForEach-Object {
        $i++
        $name = ([string]$_.key -split '/')[-1]
        $subName = if ([string]$_.label -match '\((.*)\)\s*$') { $Matches[1] } else { '' }
        [PSCustomObject]@{
            id = "RG-$i"; name = $name; subscription = $subName; subscriptionId = [string]$_.subscriptionId
            environment = (Get-EnvironmentGuess -Name $name)
            currentUsd = [double]$_.currentUsd; previousSameDaysUsd = [double]$_.previousSameDaysUsd
            previousMonthUsd = [double]$_.previousMonthUsd; deltaPct = $_.deltaPct; sharePct = [double]$_.sharePct
            resources = [int]$_.resources
        }
    })
}

# ----------------------------------------------------------------------------
# Pseudonyms — names never reach the model.
# ----------------------------------------------------------------------------
function New-PseudonymMap { return @{ Forward = @{}; Reverse = @{}; Counters = @{} } }

function Add-Pseudonym {
    param([Parameter(Mandatory)][hashtable]$Map, [string]$Value, [Parameter(Mandatory)][string]$Prefix)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $v = [string]$Value
    if ($v.Length -lt 3 -or $v.StartsWith('(') -or $Map.Forward.ContainsKey($v)) { return }
    $n = 1 + [int]($Map.Counters[$Prefix] ?? 0); $Map.Counters[$Prefix] = $n
    $token = "$($Prefix)_$n"
    $Map.Forward[$v] = $token; $Map.Reverse[$token] = $v
}

# Replace every registered name, and every GUID, in a text (JSON).
function Protect-AgentText {
    param([Parameter(Mandatory)][hashtable]$Map, [AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    foreach ($m in @([regex]::Matches($t, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)) {
        Add-Pseudonym -Map $Map -Value $m -Prefix 'ID'
    }
    foreach ($k in @($Map.Forward.Keys | Sort-Object { $_.Length } -Descending)) {
        $t = [regex]::Replace($t, '(?<![\w])' + [regex]::Escape($k) + '(?![\w])', $Map.Forward[$k],
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $t
}

function Unprotect-AgentText {
    param([Parameter(Mandatory)][hashtable]$Map, [AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, '\b(OWNER|SUBN|ID)_\d+\b', {
        param($m) if ($Map.Reverse.ContainsKey($m.Value)) { $Map.Reverse[$m.Value] } else { $m.Value }
    })
}

# Map an object through JSON: protect or unprotect every string in it.
function Convert-AgentObject {
    param([Parameter(Mandatory)][hashtable]$Map, $Object, [switch]$Unprotect)
    if ($null -eq $Object) { return $null }
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    $out = if ($Unprotect) { Unprotect-AgentText -Map $Map -Text $json } else { Protect-AgentText -Map $Map -Text $json }
    return ($out | ConvertFrom-Json)
}

# Owners and subscription names that appear in the payload.
function Register-PayloadNames {
    param([Parameter(Mandatory)][hashtable]$Map, [Parameter(Mandatory)]$Payload)
    foreach ($o in @($Payload.owners)) { Add-Pseudonym -Map $Map -Value ([string]$o.owner) -Prefix 'OWNER' }
    foreach ($c in @($Payload.changes.items)) { Add-Pseudonym -Map $Map -Value ([string]$c.owner) -Prefix 'OWNER' }
    foreach ($s in @($Payload.savings.items)) { Add-Pseudonym -Map $Map -Value ([string]$s.owner) -Prefix 'OWNER' }
    foreach ($c in @($Payload.changes.items)) { if ([string]$c.dimension -eq 'subscription') { Add-Pseudonym -Map $Map -Value ([string]$c.name) -Prefix 'SUBN' }; Add-Pseudonym -Map $Map -Value ([string]$c.subscription) -Prefix 'SUBN' }
    foreach ($s in @($Payload.savings.items)) { Add-Pseudonym -Map $Map -Value ([string]$s.subscription) -Prefix 'SUBN' }
    foreach ($r in @($Payload.resourceGroups)) { Add-Pseudonym -Map $Map -Value ([string]$r.subscription) -Prefix 'SUBN' }
}

# ----------------------------------------------------------------------------
# Tools
# ----------------------------------------------------------------------------
function Get-InsightTools {
    $dims = Get-CostQueryDimensions
    $nullable = { param($Schema) @{ anyOf = @($Schema, @{ type = 'null' }) } }
    return @(
        @{
            name = 'cost_query'
            description = 'Read-only Azure Cost Management query over the subscriptions this portal covers. Returns up to 30 rows with Cost and Currency (billing currency).'
            parameters = @{
                type = 'object'; additionalProperties = $false
                required = @('timeframe', 'from', 'to', 'granularity', 'groupBy', 'groupByOwner', 'filters', 'compareWithPrevious')
                properties = @{
                    timeframe   = @{ type = 'string'; enum = @('MonthToDate', 'TheLastMonth', 'WeekToDate', 'Custom') }
                    from        = (& $nullable @{ type = 'string'; description = 'yyyy-MM-dd, only with Custom' })
                    to          = (& $nullable @{ type = 'string'; description = 'yyyy-MM-dd, only with Custom' })
                    granularity = @{ type = 'string'; enum = @('None', 'Daily', 'Monthly') }
                    groupBy     = (& $nullable @{ type = 'array'; items = @{ type = 'string'; enum = $dims } })
                    groupByOwner = @{ type = 'boolean'; description = 'also group by the owner tag' }
                    filters     = (& $nullable @{ type = 'array'; items = @{ type = 'object'; additionalProperties = $false; required = @('dimension', 'values')
                                    properties = @{ dimension = @{ type = 'string'; enum = $dims }; values = @{ type = 'array'; items = @{ type = 'string' } } } } })
                    compareWithPrevious = @{ type = 'boolean'; description = 'compare with the previous equivalent period' }
                }
            }
        }
        @{
            name = 'change_evidence'
            description = 'The stored evidence for one cost change: meters that drove it, volume vs unit price, Activity Log and configuration changes.'
            parameters = @{ type = 'object'; additionalProperties = $false; required = @('id'); properties = @{ id = @{ type = 'string'; description = 'a C-… id from the payload' } } }
        }
        @{
            name = 'saving_detail'
            description = 'The stored detail of one savings opportunity: what was measured and how the saving was priced.'
            parameters = @{ type = 'object'; additionalProperties = $false; required = @('id'); properties = @{ id = @{ type = 'string'; description = 'an S-… or A-… id from the payload' } } }
        }
    )
}

# Run one tool call. -Ctx: @{ Token; Payload; Map; Log (List); CostScope (lazy); OwnerKey; Currencies (HashSet) }.
# Returns the (protected) result object for the model. Arguments arrive protected and are
# mapped back before anything runs.
function Invoke-InsightTool {
    param([Parameter(Mandatory)][string]$Name, $Arguments, [Parameter(Mandatory)][hashtable]$Ctx)
    $args0 = Convert-AgentObject -Map $Ctx.Map -Object $Arguments -Unprotect
    $ref = "Q$($Ctx.Log.Count + 1)"
    $entry = [ordered]@{ ref = $ref; tool = $Name; args = $args0; summary = '' }
    $result = $null
    try {
        switch ($Name) {
            'cost_query' {
                if (-not $Ctx.CostScope) { $Ctx.CostScope = Resolve-InsightCostScope -Token $Ctx.Token }
                $cs = $Ctx.CostScope
                if (-not $cs.Scope -and -not $cs.FanOut) { throw 'no cost query scope is configured' }
                $spec = [PSCustomObject]@{
                    timeframe = [string]$args0.timeframe; from = $args0.from; to = $args0.to
                    granularity = [string]$args0.granularity; groupBy = @($args0.groupBy | Where-Object { $_ }); filters = @($args0.filters | Where-Object { $_ })
                    groupByTag = if ([bool]$args0.groupByOwner -and $Ctx.OwnerKey) { [string]$Ctx.OwnerKey } else { $null }
                }
                $mgmt = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
                # Subscriptions named in the question, or every one when no management group can
                # answer for them (CSP / MCA): asked one by one and added up, like Ask.
                $sel = Select-SpecSubscriptions -Spec $spec -Subscriptions @($cs.QuerySubs)
                if ($sel.Named -and -not @($sel.Subscriptions).Count) { throw "no subscription in scope matches '$((@($sel.Unmatched)) -join "', '")'" }
                # First choice: the portal's own per-resource cost (every subscription, instant).
                if (-not $Ctx.ContainsKey('Index')) {
                    $Ctx.Index = $null; $Ctx.Rate = $null
                    try { $Ctx.Index = Read-ResourceCostIndex -Token $Ctx.Token; $Ctx.Rate = Get-BillingCurrencyRate -StorageToken $Ctx.Token } catch { Write-Host "resource cost index unavailable: $($_.Exception.Message)" }
                }
                $stored = if ($Ctx.Index) { Invoke-StoredCostQuery -Spec $spec -IndexData $Ctx.Index -Subscriptions @($cs.QuerySubs) -Rate $Ctx.Rate -Compare:([bool]$args0.compareWithPrevious) } else { $null }
                $q = if ($stored) { $stored } elseif ($sel.Named -or $cs.FanOut) {
                    $r = Invoke-CostQueryAcrossSubscriptions -Spec $sel.Spec -MgmtToken $mgmt -Subscriptions @($sel.Subscriptions) -CostType $cs.CostType `
                        -Compare:([bool]$args0.compareWithPrevious) -BudgetSeconds 90
                    if (-not @($r.answered).Count) { throw 'no subscription answered the query in time' }
                    $r
                } elseif ([bool]$args0.compareWithPrevious) {
                    Invoke-CostComparison -Spec $spec -MgmtToken $mgmt -Scope $cs.Scope -CostType $cs.CostType -SubscriptionIds $cs.SubIds
                } else {
                    Invoke-CostQuery -Spec $spec -MgmtToken $mgmt -Scope $cs.Scope -CostType $cs.CostType -SubscriptionIds $cs.SubIds
                }
                $rows = @($q.rows | Sort-Object { if ($_.PSObject.Properties['Cost']) { -[double]$_.Cost } else { 0 } } | Select-Object -First 30)
                foreach ($r in $rows) {
                    if ($r.PSObject.Properties['Currency'] -and $r.Currency) { [void]$Ctx.Currencies.Add(([string]$r.Currency).ToUpperInvariant()) }
                    if ($r.PSObject.Properties['TagValue']) { Add-Pseudonym -Map $Ctx.Map -Value ([string]$r.TagValue) -Prefix 'OWNER' }
                    if ($r.PSObject.Properties['SubscriptionName']) { Add-Pseudonym -Map $Ctx.Map -Value ([string]$r.SubscriptionName) -Prefix 'SUBN' }
                }
                $missing = if ($q.PSObject.Properties['missing']) { @($q.missing) } else { @() }
                $label = if ($stored) { "the portal's nightly per-resource cost, $($stored.periodText) (resource costs only)" } elseif ($sel.Named) { 'the subscriptions named in the query' } elseif ($cs.FanOut) { "all $(@($cs.QuerySubs).Count) subscriptions in scope" } else { $cs.Label }
                $result = [PSCustomObject]@{ ref = $ref; scope = $label; notAnswered = $missing; comparison = $q.comparison; columns = @($q.columns); rows = $rows; rowCount = @($q.rows).Count }
                $entry.summary = "$(@($q.rows).Count) row(s)$(if ($missing.Count) { ", $($missing.Count) subscription(s) did not answer" })"
            }
            'change_evidence' {
                $id = [string]$args0.id
                $c = @($Ctx.Payload.changes.items | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
                if (-not $c) { throw "unknown change id '$id'" }
                $pk = if ($c.periodKey) { [string]$c.periodKey } else { "$([string]$Ctx.Payload.changes.periodType)|$([string]$Ctx.Payload.changes.period)" }
                $row = @(Get-TableEntities -Table 'CostSpikes' -Filter "PartitionKey eq '$(ConvertTo-ODataLiteral -Value $pk)' and RowKey eq '$(ConvertTo-ODataLiteral -Value ([string]$c.findingId))'" -Token $Ctx.Token) | Select-Object -First 1
                $result = [PSCustomObject]@{
                    ref = $ref; id = $id; name = $c.name; deltaUsd = $c.deltaUsd; currentUsd = $c.currentUsd; baselineUsd = $c.baselineUsd
                    periodStart = $Ctx.Payload.changes.periodStart; periodEnd = $Ctx.Payload.changes.periodEnd
                    cause = if ($row -and [bool]$row.Explained) { [string]$row.Cause } else { $null }
                    facts = @(Get-BriefFacts -EvidenceJson ([string]$row.EvidenceJson) -Max 12)
                }
                $entry.summary = "$(@($result.facts).Count) fact(s)"
            }
            'saving_detail' {
                $id = [string]$args0.id
                $s = @($Ctx.Payload.savings.items | Where-Object { [string]$_.id -eq $id }) | Select-Object -First 1
                if (-not $s) { throw "unknown saving id '$id'" }
                $rk = $id -replace '^[SA]-', ''
                $row = if ([string]$s.source -eq 'advisor') {
                    @(Get-TableEntities -Table 'Recommendations' -Filter "PartitionKey eq 'cost' and RowKey eq '$(ConvertTo-ODataLiteral -Value $rk)'" -Token $Ctx.Token) | Select-Object -First 1
                } else {
                    @(Get-TableEntities -Table 'SavingsFindings' -Filter "PartitionKey eq 'savings' and RowKey eq '$(ConvertTo-ODataLiteral -Value $rk)'" -Token $Ctx.Token) | Select-Object -First 1
                }
                $evidence = [string]$row.EvidenceJson
                if ($evidence.Length -gt 3000) { $evidence = $evidence.Substring(0, 3000) }
                $result = [PSCustomObject]@{
                    ref = $ref; id = $id; title = $s.title; detail = $s.detail; category = $s.category; tier = $s.tier
                    monthlyUsd = $s.monthlyUsd; resourceName = $s.resourceName
                    resourceType = [string]$row.ResourceType; sku = [string]$row.Sku; evidence = $evidence
                }
                $entry.summary = 'detail'
            }
            default { throw "unknown tool '$Name'" }
        }
    } catch {
        $entry.summary = "failed: $($_.Exception.Message)"
        $result = [PSCustomObject]@{ ref = $ref; error = $_.Exception.Message }
    }
    $Ctx.Log.Add([PSCustomObject]$entry)
    $protectedResult = Convert-AgentObject -Map $Ctx.Map -Object $result
    $Ctx.ToolText.Add(($protectedResult | ConvertTo-Json -Depth 10 -Compress))
    return $protectedResult
}

# The cost query scope the same way Ask resolves it (QueryCosts): COST_QUERY_SCOPE, else the
# management group found to hold every included subscription, else the deployment subscription.
function Resolve-InsightCostScope {
    param([Parameter(Mandatory)][string]$Token)
    $resolved = Get-ResolvedCostScope -StorageToken $Token
    $scope = if ($resolved.Scope) { [string]$resolved.Scope }
             elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) { "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)" } else { $null }
    $subScope = Get-SubscriptionScope -Token $Token
    $subIds = @()
    if ($scope -and $scope -notlike '/subscriptions/*' -and ($subScope.Ids -or $resolved.Extra -ne 0)) {
        $subIds = @(Get-IncludedSubscriptionIds -Token $Token -Scope $subScope)
    }
    $querySubs = @(Get-QuerySubscriptions -Token $Token -Scope $subScope)
    # No management group answers for these subscriptions (CSP / MCA): ask each one.
    $fanOut = ((-not $scope -or $scope -like '/subscriptions/*') -and $querySubs.Count -gt 1)
    return @{ Scope = $scope; SubIds = $subIds; CostType = (Get-CostTypeSetting -StorageToken $Token)
              QuerySubs = $querySubs; FanOut = $fanOut
              Label = if ($scope -like '/subscriptions/*') { 'one subscription' } else { 'all subscriptions in scope' } }
}

# ----------------------------------------------------------------------------
# Prompt, schema, validation
# ----------------------------------------------------------------------------
function Get-InsightSystemPrompt {
    return Add-AiLanguageLine @'
You are the FinOps analyst for one Azure tenant. The readers are the platform / FinOps team and
management. They look once a week or once a month, and their main job is deciding WHO to chase,
about WHAT, for HOW MUCH.

The user message is JSON, already calculated (amounts in USD unless a row says otherwise):
- grain: week (this month so far) or month (the last complete month); today
- spend: this period against the one before; forecastUsd is Azure's month-end forecast. Each
  figure carries the exact days it sums (from, to). A month-to-date figure is compared with the
  SAME days of the previous month (previousSamePeriod), not the whole month.
- changes: the largest cost increases (ids C-…) of the last 7 days and of last month — each
  item's period says which. state says where it stands NOW, from the latest settled days
  (currentRunRateUsd, on the same footing as currentUsd, as of currentAsOf): open = still running
  high; decreasing = falling but still above normal; resolved = already back to normal.
  A decreasing change is never priority 1: rank it on currentExcessUsd (what is still being
  overspent per period now), not on deltaUsd, and say that it is falling — with fallPct and
  fallSince when given (e.g. "down 42% since 3 Nov"). Do not report a
  resolved change as a finding.
- savings: open savings opportunities with their estimated monthly saving (ids S-…, A-…).
  billingScope true = a reservation / savings-plan purchase for the billing account: it has no
  resource and so no owner. Present it as a purchase decision, never as missing an owner.
- owners: spend per owner this month and their open savings (ids O-…); rows without an owner
  tag carry no savings figure
- resourceGroups: spend per resource group this month, with an environment guess (ids RG-…)
- notes: gaps in the data
People and subscription names are replaced by tokens such as OWNER_3, SUBN_2 and ID_5. Use the
tokens exactly as given; never guess the real names.

You may call read-only tools to check and size what you see: cost_query (Cost Management, rows in
the billing currency), change_evidence (C-…) and saving_detail (S-…/A-…). Every tool result has a
ref (Q1, Q2, …). Use at most 5 tool calls; skip them when the payload already answers.

Then answer with ONE JSON object:
- summary: 2-3 sentences on the period as a whole. When you compare spend, name both date
  ranges from their from/to (e.g. "1-8 November against 1-8 October"; a forecast against "all of
  October"), never just "the same period".
- findings: 3 to 6, most important first. Important = a large amount that someone can act on:
  waste, non-production running like production, sudden or growing increases, spend nobody owns,
  savings not acted on. Every finding is about something SPECIFIC the reader can open and act
  on: a named resource, resource group, subscription, purchase (e.g. a reservation for a VM size
  in a region) or owner. Do NOT write process findings about the data as a whole ("many savings
  lack owners", "recommendations need triage"); if untagged spend matters, name the resource
  groups that hold it, at most one such finding, never priority 1.
  Savings with the same title for a reservation or savings plan are alternatives of one purchase:
  never add them up. For each:
  - priority: 1 = act this week (large or growing), 2 = act this month, 3 = worth knowing
  - title: one plain sentence, at most 90 characters, saying what is wrong
  - why: 1-3 sentences with the evidence
    In title and why: NO currency amounts (the page shows monthlyCost and estMonthlySavings in
    the reader's currency right below), NO ids or refs (C-…, S-…, A-…, Q1), NO field names
    (monthlyUsd, deltaPct …), NO owner (shown separately) and NO placeholder values such as
    "(untagged)" or "(resource no longer exists)" — say "without an owner tag" or "deleted".
    Percentages, dates, counts and resource names are fine. Write for a manager, not a developer.
  - owner: the owner token the finding belongs to, or "" when unknown
  - monthlyCost, estMonthlySavings: COPIED from the payload or a tool result, or null. Do no
    arithmetic. A finding about a missing owner tag has estMonthlySavings null: name the
    resources or resource groups without one, never a saving. currency: "USD" for payload figures, the row's Currency for cost_query figures
  - action: one concrete next step
  - actionScript: one Azure CLI or PowerShell command that would carry out the action, or "".
    Use real Azure names and resource ids only, never the payload's ids or tokens.
    A person reviews it before running it. No secrets, no deletes of data without a backup step.
  - refs: the ids (C-, S-, A-, O-, RG-) and tool refs (Q1 …) the finding rests on — at least one

Rules: every number you write must appear in the payload or a tool result. Never invent
resources, owners, causes or dates. Plain language, no markdown. Output only the JSON object.
'@
}

function Get-InsightSchema {
    $nullableNum = @{ anyOf = @(@{ type = 'number' }, @{ type = 'null' }) }
    return @{
        type = 'object'; additionalProperties = $false; required = @('summary', 'findings')
        properties = @{
            summary  = @{ type = 'string' }
            findings = @{
                type = 'array'
                items = @{
                    type = 'object'; additionalProperties = $false
                    required = @('priority', 'title', 'why', 'owner', 'monthlyCost', 'estMonthlySavings', 'currency', 'action', 'actionScript', 'refs')
                    properties = @{
                        priority = @{ type = 'integer'; enum = @(1, 2, 3) }
                        title = @{ type = 'string' }; why = @{ type = 'string' }; owner = @{ type = 'string' }
                        monthlyCost = $nullableNum; estMonthlySavings = $nullableNum; currency = @{ type = 'string' }
                        action = @{ type = 'string' }; actionScript = @{ type = 'string' }
                        refs = @{ type = 'array'; items = @{ type = 'string' } }
                    }
                }
            }
        }
    }
}

# "has no owner", "lack an owner", "without an owner tag", "unowned", "unassigned"…
# In Danish: "ingen ejer", "mangler en ejer", "uden ejer-tag", "ejeren mangler".
$script:MissingOwnerPattern = '(?i)\b(?:no|without|lacks?|lacking|missing)\b[\w\s/-]{0,30}?\bowners?\b|\bowners?\b[\w\s]{0,20}?\b(?:missing|unassigned|unknown)\b|\bunowned\b|\bunassigned\b|\b(?:ingen|uden|mangler|manglende)\b[\w\s/-]{0,30}?\bejer\w*\b|\bejer\w*\b[\w\s]{0,20}?\b(?:mangler|ukendt|ikke tildelt)\b'

function Limit-InsightText { param($Value, [int]$Max) $s = ([string]$Value).Trim(); if ($s.Length -gt $Max) { return $s.Substring(0, $Max) } return $s }

# Belt and braces for the prompt's rule: take internal ids, payload field names and USD amounts
# out of reader-facing text ("Advisor item A-9f6b… with monthlyUsd $596.0" reached a page).
function Remove-InsightJargon {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '\s*\(\s*\$[\d.,]+(?:\s*/\s*(?:mo|month))?\s*\)', '')                       # ($596/mo)
    # Any other amount with a currency: "about 13,770.98 USD", "$596", "1.200 kr." — the page shows
    # the amounts in the reader's currency next to the text.
    $t = [regex]::Replace($t, '(?i)\s*(?:about\s+|around\s+|roughly\s+|~\s*)?(?:\$\s?[\d][\d.,]*|[\d][\d.,]*\s?(?:USD|DKK|EUR|SEK|NOK|GBP|kr\.?)(?![A-Za-z]))(?:\s*(?:/|per|a)\s*(?:mo|month)\b)?(?:\s+of\b)?', '')
    # Internal placeholder values quoted as text: "(untagged)", "(resource no longer exists)".
    $t = [regex]::Replace($t, '(?i)\s*owner shown as\s*', ' ')
    $t = [regex]::Replace($t, '\((untagged|resource no longer exists|tags unavailable)\)', { param($m) switch ($m.Groups[1].Value) { 'untagged' { 'untagged' } 'resource no longer exists' { 'deleted' } default { 'unknown' } } })
    $t = [regex]::Replace($t, '\b(?:with\s+)?(?:monthlyUsd|deltaUsd|currentUsd|currentRunRateUsd|currentExcessUsd|baselineUsd|deltaPct|sharePct|estMonthlySavings|monthlyCost)\b\s*[:=]?\s*\$?[\d.,]*', '')
    $t = [regex]::Replace($t, '\s*\(?\b(?:item\s+|id\s+)?(?:[CSA]-[0-9a-fA-F]{8,}|RG-\d+|O-\d+|Q\d+)\b\)?', '')
    $t = [regex]::Replace($t, '\(\s+', '(')
    $t = [regex]::Replace($t, '\s{2,}', ' ')
    $t = [regex]::Replace($t, '\s+([.,;:])', '$1')
    return $t.Trim()
}

# Keep only well-formed, cited, grounded findings, mapped back to real names.
#   -AllowedText   everything the model saw (protected payload + tool results), for grounding
#   -KnownRefs     ids in the payload plus Q-refs of the tool calls made
#   -Currencies    currencies seen in tool rows (USD is always allowed)
# Returns @{ summary; findings; dropped }.
function Select-InsightFindings {
    param(
        [Parameter(Mandatory)]$Parsed,
        [Parameter(Mandatory)][string]$AllowedText,
        [Parameter(Mandatory)][hashtable]$KnownRefs,
        [Parameter(Mandatory)][hashtable]$Map,
        [string[]]$Currencies = @(),
        [hashtable]$UntaggedRefs = @{},
        [hashtable]$BillingScopeRefs = @{},
        # C-… id -> 'open' | 'decreasing' | 'resolved'
        [hashtable]$ChangeStates = @{},
        # C-… id -> current overspend per period (USD), for ranking a falling change
        [hashtable]$ChangeExcess = @{},
        # last month's spend, the scale priorities are judged against (Get-AmountPriority)
        [double]$BaseUsd = 0
    )
    $okCurrencies = @('USD') + @($Currencies)
    $kept = @(); $dropped = 0; $n = 0
    foreach ($f in @($Parsed.findings)) {
        if (-not $f -or [string]::IsNullOrWhiteSpace([string]$f.title)) { $dropped++; continue }
        $prio = 0; [void][int]::TryParse([string]$f.priority, [ref]$prio)
        if ($prio -lt 1 -or $prio -gt 3) { $prio = 3 }
        $refs = @(@($f.refs) | ForEach-Object { [string]$_ } | Where-Object { $KnownRefs.ContainsKey($_) } | Select-Object -Unique)
        if (-not $refs.Count) { $dropped++; continue }
        # Belt and braces for the prompt's rule on a cost change's state. A finding that rests only
        # on changes that are no longer running high: all resolved → dropped; otherwise ranked on
        # what is still being overspent now (never more urgent than that, and never priority 1).
        # Savings, owners and queries in the refs lift this.
        $changeRefs = @($refs | Where-Object { $_ -like 'C-*' })
        if ($changeRefs.Count -and $changeRefs.Count -eq $refs.Count) {
            $states = @($changeRefs | ForEach-Object { if ($ChangeStates.ContainsKey($_)) { [string]$ChangeStates[$_] } else { 'open' } })
            if (@($states | Where-Object { $_ -ne 'resolved' }).Count -eq 0) { $dropped++; continue }
            if (@($states | Where-Object { $_ -eq 'open' }).Count -eq 0) {
                $excess = @($changeRefs | Where-Object { $ChangeExcess.ContainsKey($_) -and $null -ne $ChangeExcess[$_] } | ForEach-Object { [double]$ChangeExcess[$_] })
                $floor = if ($excess.Count) { [Math]::Max(2, (Get-AmountPriority -Usd (($excess | Measure-Object -Sum).Sum) -BaseUsd $BaseUsd)) } else { 2 }
                if ($prio -lt $floor) { $prio = $floor }
            }
        }
        $cost = if ($null -ne $f.monthlyCost -and "$($f.monthlyCost)" -ne '') { [double]$f.monthlyCost } else { $null }
        $save = if ($null -ne $f.estMonthlySavings -and "$($f.estMonthlySavings)" -ne '') { [double]$f.estMonthlySavings } else { $null }
        # A saving must rest on a saving, a cost change or a query result — not on an owner or
        # resource-group row — and is never attached to a missing owner tag.
        $savingRefs = @($refs | Where-Object { $_ -match '^(S-|A-|C-|Q\d)' })
        $aboutUntagged = @($refs | Where-Object { $UntaggedRefs.ContainsKey($_) }).Count -gt 0
        if (-not $savingRefs.Count -or $aboutUntagged) { $save = $null }
        # A savings item carries only the saving; a monthly cost needs a cost change, an owner or
        # resource-group row, or a query result.
        if (-not @($refs | Where-Object { $_ -match '^(C-|O-|RG-|Q\d)' }).Count) { $cost = $null }
        # A billing-account purchase has no owner: a finding that blames a missing owner for it
        # mixes the two, and is dropped.
        $billingRefs = @($refs | Where-Object { $BillingScopeRefs.ContainsKey($_) })
        if ($billingRefs.Count -and "$($f.title) $($f.why)" -match $script:MissingOwnerPattern) { $dropped++; continue }
        $billingOnly = ($billingRefs.Count -gt 0 -and $billingRefs.Count -eq $refs.Count)
        $text = "$($f.title) $($f.why) $($f.action) $(if ($null -ne $cost) { $cost }) $(if ($null -ne $save) { $save })"
        if (-not (Test-NarrativeGrounding -Narrative $text -Payload $AllowedText)) { $dropped++; continue }
        $cur = ([string]$f.currency).Trim().ToUpperInvariant()
        if ($okCurrencies -notcontains $cur) { $cur = 'USD' }
        $owner = [string]$f.owner
        $owner = if ($owner -match '^OWNER_\d+$' -and $Map.Reverse.ContainsKey($owner)) { $Map.Reverse[$owner] } else { '' }
        $n++
        $kept += [PSCustomObject]@{
            id = "F$n"; priority = $prio
            # The owner has its own column; a name in the title only repeats it.
            title = Unprotect-AgentText -Map $Map -Text (Remove-InsightJargon ((Limit-InsightText $f.title 140) -replace '\s*\b(?:owned by|for|by)?\s*OWNER_\d+\b', ''))
            why = Unprotect-AgentText -Map $Map -Text (Remove-InsightJargon (Limit-InsightText $f.why 600))
            owner = if ($billingOnly) { '' } else { $owner }
            billingScope = $billingOnly
            monthlyCost = $cost; estMonthlySavings = $save; currency = $cur
            action = Unprotect-AgentText -Map $Map -Text (Remove-InsightJargon (Limit-InsightText $f.action 300))
            # A command quoting the portal's own ids (A-…, RG-3, Q1) can't run anywhere.
            actionScript = $(if ([string]$f.actionScript -cmatch '(?<![\w-])(?:[CSA]-[0-9a-fA-F]{6,}|[CSA]-(?=[''"\]\)]|$)|RG-\d+|O-\d+|Q\d+|OWNER_\d+|SUBN_\d+|ID_\d+)(?![\w-])') { '' } else { Unprotect-AgentText -Map $Map -Text (Limit-InsightText $f.actionScript 600) })
            refs = $refs
        }
        if ($kept.Count -ge 6) { break }
    }
    $kept = @($kept | Sort-Object priority, @{ Expression = { -[double]($_.estMonthlySavings ?? 0) } })
    $i = 0; foreach ($k in $kept) { $i++; $k.id = "F$i" }
    return [PSCustomObject]@{
        summary = Unprotect-AgentText -Map $Map -Text (Limit-InsightText $Parsed.summary 800)
        findings = $kept; dropped = $dropped
    }
}

# ----------------------------------------------------------------------------
# Get-RuleFindings — the no-AI findings: the same payload ranked by amount. Pure.
# Priority is the amount against last month's spend: >= 2% → 1, >= 0.5% → 2, else 3.
# ----------------------------------------------------------------------------
# The priority an amount earns against last month's spend: >= 2% → 1, >= 0.5% → 2, else 3
# (2 when there is no spend to compare with). Pure.
function Get-AmountPriority {
    param([double]$Usd, [double]$BaseUsd)
    if ($BaseUsd -le 0) { return 2 }
    $p = $Usd / $BaseUsd
    if ($p -ge 0.02) { return 1 } elseif ($p -ge 0.005) { return 2 } else { return 3 }
}

# The spend priorities are judged against: last month's, else this month's so far.
function Get-PriorityBaseUsd {
    param($Payload)
    $base = [double]($Payload.spend.previousMonth.usd ?? 0)
    if ($base -le 0) { $base = [double]($Payload.spend.current.usd ?? 0) }
    return $base
}

function Get-RuleFindings {
    param([Parameter(Mandatory)]$Payload, [int]$Max = 6)
    $base = Get-PriorityBaseUsd $Payload
    $prio = { param([double]$Usd) Get-AmountPriority -Usd $Usd -BaseUsd $base }
    $items = @()
    foreach ($s in @($Payload.savings.items)) {
        $items += [PSCustomObject]@{
            priority = (& $prio ([double]$s.monthlyUsd)); title = "$([string]$s.title)$(if ($s.resourceName) { ": $($s.resourceName)" })"
            why = [string]$s.detail; owner = [string]$s.owner; billingScope = [bool]$s.billingScope; monthlyCost = $null; estMonthlySavings = [double]$s.monthlyUsd; currency = 'USD'
            action = [string]$s.title; actionScript = ''; refs = @([string]$s.id); sortUsd = [double]$s.monthlyUsd
        }
    }
    # Changes already back to normal are not findings. Falling ones are ranked on what is still
    # being overspent now, and are never priority 1.
    foreach ($c in @($Payload.changes.items | Where-Object { [string]$_.state -ne 'resolved' -and -not ([bool]$_.resolved) } | Select-Object -First 3)) {
        $amount = [double]$c.deltaUsd
        if ([string]$c.state -eq 'decreasing' -and $null -ne $c.currentExcessUsd) { $amount = [double]$c.currentExcessUsd }
        $p = & $prio $amount
        if ([string]$c.state -eq 'decreasing' -and $p -lt 2) { $p = 2 }
        $items += [PSCustomObject]@{
            priority = $p; title = (Get-PortalText 'rule.costUp' @{ name = [string]$c.name })
            why = if ($c.cause) { [string]$c.cause } else { Get-PortalText 'rule.notExplained' }
            owner = [string]$c.owner; billingScope = $false; monthlyCost = [double]$c.currentUsd; estMonthlySavings = $null; currency = 'USD'
            action = (Get-PortalText 'rule.askOwner'); actionScript = ''; refs = @([string]$c.id); sortUsd = $amount
        }
    }
    $i = 0
    return @($items | Sort-Object priority, @{ Expression = 'sortUsd'; Descending = $true } | Select-Object -First $Max | ForEach-Object {
        $i++
        [PSCustomObject]@{ id = "R$i"; priority = $_.priority; title = $_.title; why = $_.why; owner = $_.owner; billingScope = $_.billingScope
            monthlyCost = $_.monthlyCost; estMonthlySavings = $_.estMonthlySavings; currency = $_.currency
            action = $_.action; actionScript = $_.actionScript; refs = $_.refs }
    })
}

# ----------------------------------------------------------------------------
# Invoke-CostInsights — run the agent over a brief payload.
# Returns @{ ai = { summary; findings; toolCalls; dropped; model } ; error }. Throws on provider
# failure or the AI budget (the caller records the status).
# ----------------------------------------------------------------------------
function Invoke-CostInsights {
    param([Parameter(Mandatory)]$Payload, [Parameter(Mandatory)][string]$Token, [int]$MaxSteps = 7)
    $map = New-PseudonymMap
    Register-PayloadNames -Map $map -Payload $Payload
    $userObj = [PSCustomObject]@{
        grain = $Payload.grain; today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
        spend = $Payload.spend; changes = $Payload.changes; savings = $Payload.savings
        owners = @($Payload.owners | ForEach-Object { $_ | Select-Object * -ExcludeProperty subscriptionId })
        resourceGroups = @($Payload.resourceGroups | ForEach-Object { $_ | Select-Object * -ExcludeProperty subscriptionId })
        notes = $Payload.notes
    }
    $userJson = Protect-AgentText -Map $map -Text ($userObj | ConvertTo-Json -Depth 12 -Compress)

    $ctx = @{
        Token = $Token; Payload = $Payload; Map = $map; CostScope = $null
        OwnerKey = @(Get-AllocationTagKeys -StorageToken $Token)[0]
        Log = [System.Collections.Generic.List[object]]::new()
        ToolText = [System.Collections.Generic.List[string]]::new()
        Currencies = [System.Collections.Generic.HashSet[string]]::new()
    }
    $handler = { param([string]$Name, $Arguments) Invoke-InsightTool -Name $Name -Arguments $Arguments -Ctx $ctx }

    $r = Invoke-AiAgent -System (Get-InsightSystemPrompt) -User $userJson -Tools (Get-InsightTools) -ToolHandler $handler `
        -Schema (Get-InsightSchema) -MaxSteps $MaxSteps -MaxTokens 2500 -Purpose "findings-$($Payload.grain)"
    if (-not $r.Parsed) { return [PSCustomObject]@{ ai = $null; error = 'the model did not return the expected structure' } }

    $known = @{}
    foreach ($c in @($Payload.changes.items)) { $known[[string]$c.id] = $true }
    foreach ($s in @($Payload.savings.items)) { $known[[string]$s.id] = $true }
    foreach ($o in @($Payload.owners)) { $known[[string]$o.id] = $true }
    foreach ($g in @($Payload.resourceGroups)) { $known[[string]$g.id] = $true }
    foreach ($l in $ctx.Log) { $known[[string]$l.ref] = $true }

    $allowed = $userJson + "`n" + ($ctx.ToolText -join "`n")
    $untagged = @{}
    foreach ($o in @($Payload.owners)) { if ([string]$o.owner -like '(*') { $untagged[[string]$o.id] = $true } }
    $billing = @{}
    foreach ($s in @($Payload.savings.items)) { if ([bool]$s.billingScope) { $billing[[string]$s.id] = $true } }
    $changeStates = @{}
    $changeExcess = @{}
    foreach ($c in @($Payload.changes.items)) {
        if ($c.state) { $changeStates[[string]$c.id] = [string]$c.state }
        if ($null -ne $c.currentExcessUsd) { $changeExcess[[string]$c.id] = [double]$c.currentExcessUsd }
    }
    $sel = Select-InsightFindings -Parsed $r.Parsed -AllowedText $allowed -KnownRefs $known -Map $map -Currencies @($ctx.Currencies) -UntaggedRefs $untagged -BillingScopeRefs $billing `
        -ChangeStates $changeStates -ChangeExcess $changeExcess -BaseUsd (Get-PriorityBaseUsd $Payload)
    $toolCalls = @($ctx.Log | ForEach-Object {
        $a = ($_.args | ConvertTo-Json -Depth 8 -Compress)
        [PSCustomObject]@{ ref = $_.ref; tool = $_.tool; args = $(if ($a.Length -gt 400) { $a.Substring(0, 400) } else { $a }); summary = $_.summary }
    })
    return [PSCustomObject]@{
        ai = [PSCustomObject]@{ summary = $sel.summary; findings = @($sel.findings); toolCalls = $toolCalls; dropped = $sel.dropped; steps = $r.Steps; model = [string]$env:AI_MODEL }
        error = $null
    }
}

Export-ModuleMember -Function Get-EnvironmentGuess, Get-AllocationRows, Get-InsightOwners, Get-InsightResourceGroups, `
    New-PseudonymMap, Add-Pseudonym, Protect-AgentText, Unprotect-AgentText, Convert-AgentObject, Register-PayloadNames, `
    Get-InsightTools, Invoke-InsightTool, Resolve-InsightCostScope, Get-InsightSystemPrompt, Get-InsightSchema, `
    Select-InsightFindings, Remove-InsightJargon, Get-RuleFindings, Get-AmountPriority, Get-PriorityBaseUsd, Invoke-CostInsights
