using namespace System.Net
param($Request, $TriggerMetadata)

# Natural-language cost question -> answer, in three deterministic-bounded steps:
#   1. The model TRANSLATES the question into a small STRUCTURED query spec (schema-constrained).
#   2. We VALIDATE it against an allowlist and execute it via the read-only Cost Management
#      Query API (Invoke-CostQuery / Invoke-CostComparison). No query text, no injection, no
#      write path.
#   3. The model NARRATES the returned (already-computed) rows.
# The executed query definition and the structured spec are returned to the UI — the first for
# transparency, the second so a follow-up question can build on it.
#
# Open to Members as well as Admins: the query is read-only by construction, and every AI call
# counts against the daily AI limit (AiDailyCallLimit), which is what bounds the spend.
#
# Body:
#   question  string (required, <= 500 chars)
#   history   up to 3 earlier turns { question, spec, answer } for follow-ups ("and last month?")
#   context   what the user was looking at when they chose "Ask about this":
#             { kind, title, subscriptionId, subscriptionName, resourceId, resourceName, meter,
#               periodStart, periodEnd, summary }

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

function Send-Json {
    param([HttpStatusCode]$Status, $Object, [hashtable]$ExtraHeaders)
    $headers = @{ "Content-Type" = "application/json" }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }
    $body = if ($Object -is [string]) { $Object } else { $Object | ConvertTo-Json -Depth 12 }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $Status; Body = $body; Headers = $headers })
}
function Limit-Text { param($Value, [int]$Max) $s = [string]$Value; if ($s.Length -gt $Max) { return $s.Substring(0, $Max) } return $s }

$question = (Limit-Text $Request.Body.question 500).Trim()
if ([string]::IsNullOrWhiteSpace($question)) {
    Send-Json -Status BadRequest -Object @{ error = 'question required' }
    return
}
if (-not (Test-AiConfigured)) {
    Send-Json -Status Conflict -Object @{ error = 'AI provider not configured. Run Setup/Configure-AiProvider.ps1.' }
    return
}

# --- sanitise history + context: these go into a prompt, so keep them small and shaped ---
$history = @(@($Request.Body.history) | Where-Object { $_ -and $_.question } | Select-Object -Last 3 | ForEach-Object {
    [PSCustomObject]@{
        question = Limit-Text $_.question 500
        spec     = if ($_.spec) { $_.spec } else { $null }
        answer   = Limit-Text $_.answer 800
    }
})
$context = $null
$ctxIn = $Request.Body.context
if ($ctxIn) {
    $c = [ordered]@{}
    foreach ($k in @('kind', 'title', 'subscriptionName', 'resourceName', 'meter', 'periodStart', 'periodEnd')) {
        if ($ctxIn.$k) { $c[$k] = Limit-Text $ctxIn.$k 200 }
    }
    if ($ctxIn.subscriptionId -and [string]$ctxIn.subscriptionId -match '^[0-9a-fA-F-]{36}$') { $c.subscriptionId = ([string]$ctxIn.subscriptionId).ToLowerInvariant() }
    if ($ctxIn.resourceId -and [string]$ctxIn.resourceId -match '^/subscriptions/[0-9a-fA-F-]{36}/') {
        $c.resourceId = Limit-Text $ctxIn.resourceId 400
        if (-not $c.subscriptionId -and [string]$ctxIn.resourceId -match '^/subscriptions/([0-9a-fA-F-]{36})/') { $c.subscriptionId = $Matches[1].ToLowerInvariant() }
    }
    if ($ctxIn.summary) { $c.summary = Limit-Text $ctxIn.summary 1500 }
    if ($c.Count) { $context = [PSCustomObject]$c }
}

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# Cost query scope for tenant-wide questions: COST_QUERY_SCOPE when set, else the management
# group SyncMonthlyCosts-Timer found to contain every included subscription (Get-ResolvedCostScope),
# else — and the answer says so — only the deployment subscription.
$resolvedScope = Get-ResolvedCostScope -StorageToken $storageToken
$deploymentOnly = $false
$defaultScope = if ($resolvedScope.Scope) { [string]$resolvedScope.Scope }
                elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) { $deploymentOnly = $true; "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)" }
                else { $null }
if (-not $defaultScope) {
    Send-Json -Status Conflict -Object @{ error = 'no cost query scope configured (set COST_QUERY_SCOPE or AZURE_SUBSCRIPTION_ID)' }
    return
}

# The operator's subscription scope: Ask never answers about an excluded subscription, and a
# management-group query is filtered to the included ones (Invoke-CostQuery -SubscriptionIds).
$subScope = Get-SubscriptionScope -Token $storageToken
if ($context -and $context.subscriptionId -and -not (Test-InSubscriptionScope -Scope $subScope -Value ([string]$context.subscriptionId))) {
    Send-Json -Status BadRequest -Object @{ error = 'that subscription is outside the portal''s subscription scope' }
    return
}
# Only a problem when the question is not asked of the subscriptions one by one (below).
$defaultOutOfScope = ($defaultScope -like '/subscriptions/*' -and -not (Test-InSubscriptionScope -Scope $subScope -Value $defaultScope))

Write-AuditEntry -Caller $caller -Action 'QueryCosts' -Target $(if ($context) { [string]$context.kind } else { '' }) -StorageToken $storageToken `
    -Details @{ question = (Limit-Text $question 200); followUp = ($history.Count -gt 0) }

$dims = Get-CostQueryDimensions

# --- STEP 1: NL -> structured query spec ---
$genSystem = @"
You translate a user's natural-language Azure cost question into a STRUCTURED cost query.
Fields:
- timeframe: MonthToDate | BillingMonthToDate | TheLastMonth | TheLastBillingMonth | WeekToDate | Custom
- from, to: ISO dates (yyyy-MM-dd), ONLY when timeframe is Custom, otherwise null
- granularity: None (totals), Daily, or Monthly (a trend over time)
- groupBy: up to two dimensions to break cost down by. Allowed: $($dims -join ', ')
- filters: up to three { dimension, values } restrictions, all of which must hold. Allowed
  dimensions as above. Put names the user mentions (a service, region, resource group,
  subscription name) into values; never invent names.
- compareWithPrevious: true when the user asks how the period compares with the one before
  ("vs last month", "has it gone up", "change"). The previous equivalent period is computed
  for you; granularity is ignored when comparing.
- scopeToContextSubscription: true when the question is about the subscription or resource
  in the context ("this subscription", "this resource", "why did it go up").
Rules: choose the smallest query that answers the question. Use granularity None unless the
user asks for a trend. Set every field you are not using to null (false for the booleans).
If you choose Custom you MUST supply both from and to; if you cannot, choose a named timeframe.
Today is $([datetime]::UtcNow.ToString('yyyy-MM-dd')) (UTC).

The user message is JSON:
- question: what to answer now.
- history: earlier questions in this conversation and the query spec each produced. A short
  follow-up ("and last month?", "only production") changes the previous spec — keep the rest.
- context: what the user is looking at (a cost change, a saving, a subscription). When the
  question refers to it, filter to it: ResourceId for a resource, MeterCategory for a meter
  (plus scopeToContextSubscription), scopeToContextSubscription for a subscription.
"@
# Every property is listed in `required` — see the note above Get-CostChangeExplanationSchema
# in CostEvidence.psm1: OpenAI's strict mode rejects a schema that omits one, and that HTTP 400
# would take out the whole Ask feature. Fields that don't apply to every question are declared
# NULLABLE rather than optional; Invoke-CostQuery treats null as "not supplied". `anyOf` is used
# instead of a ["string","null"] type union because both provider families document it.
$nullable = { param($Schema) @{ anyOf = @($Schema, @{ type = 'null' }) } }
$genSchema = @{
    type = 'object'; additionalProperties = $false
    required = @('timeframe', 'from', 'to', 'granularity', 'groupBy', 'filters', 'compareWithPrevious', 'scopeToContextSubscription')
    properties = @{
        timeframe   = @{ type = 'string'; enum = @('MonthToDate', 'BillingMonthToDate', 'TheLastMonth', 'TheLastBillingMonth', 'WeekToDate', 'Custom') }
        from        = (& $nullable @{ type = 'string'; description = 'yyyy-MM-dd. Only with timeframe Custom, otherwise null.' })
        to          = (& $nullable @{ type = 'string'; description = 'yyyy-MM-dd. Only with timeframe Custom, otherwise null.' })
        granularity = @{ type = 'string'; enum = @('None', 'Daily', 'Monthly') }
        groupBy     = (& $nullable @{ type = 'array'; items = @{ type = 'string'; enum = $dims } })
        filters     = (& $nullable @{
            type  = 'array'
            items = @{
                type = 'object'; additionalProperties = $false; required = @('dimension', 'values')
                properties = @{ dimension = @{ type = 'string'; enum = $dims }; values = @{ type = 'array'; items = @{ type = 'string' } } }
            }
        })
        compareWithPrevious        = @{ type = 'boolean' }
        scopeToContextSubscription = @{ type = 'boolean' }
    }
}

$genUser = [PSCustomObject]@{
    question = $question
    history  = @($history | ForEach-Object { [PSCustomObject]@{ question = $_.question; spec = $_.spec } })
    context  = $context
} | ConvertTo-Json -Depth 8

$aiLimitResponse = {
    param($ErrorRecord)
    Send-Json -Status TooManyRequests -Object @{ error = ($ErrorRecord.Exception.Message -replace '^AI_BUDGET_EXCEEDED:\s*', ''); aiLimitReached = $true }
}

try {
    $gen = Invoke-AiCompletion -System $genSystem -User $genUser -Schema $genSchema -MaxTokens 500 -Purpose 'ask-translate'
} catch {
    if (Test-AiBudgetExceeded -ErrorRecord $_) { & $aiLimitResponse $_; return }
    Send-Json -Status BadGateway -Object (Write-ErrorBody -Message 'query generation failed' -Exception $_ -TriggerMetadata $TriggerMetadata)
    return
}
if (-not $gen.Parsed) {
    Send-Json -Status BadGateway -Object @{ error = 'could not translate the question into a cost query' }
    return
}
$spec = $gen.Parsed

# --- STEP 2: validate + execute (read-only) ---
$scope = $defaultScope
$scopeLabel = 'all subscriptions in scope'
if ([bool]$spec.scopeToContextSubscription -and $context -and $context.subscriptionId) {
    $scope = "/subscriptions/$($context.subscriptionId)"
    $scopeLabel = if ($context.subscriptionName) { [string]$context.subscriptionName } else { "subscription $($context.subscriptionId)" }
} elseif ($deploymentOnly) {
    $r = $resolvedScope
    $scopeLabel = $(if ($r.Source -eq 'insufficient') { "only the deployment subscription (the management group $($r.Name) shows only $([Math]::Round([double]$r.CoveragePct, 0))% of the spend in its cost data; set costQueryScope)" } else { 'only the deployment subscription (no readable management group contains all subscriptions; set costQueryScope)' })
} elseif ($defaultScope -like '/subscriptions/*') {
    $scopeLabel = 'the configured subscription'
}

# Only a management-group query needs the extra filter; a subscription scope is already one
# included subscription.
# A management group is filtered to the included subscriptions whenever it may hold others: an
# operator scope is set, the group was found with extra subscriptions, or it was configured.
$scopeSubIds = @()
if ($scope -notlike '/subscriptions/*' -and ($subScope.Ids -or $resolvedScope.Extra -ne 0)) {
    $scopeSubIds = @(Get-IncludedSubscriptionIds -Token $storageToken -Scope $subScope)
}
if ($scopeSubIds.Count -and $scopeLabel -eq 'all subscriptions in scope') { $scopeLabel = "the $($scopeSubIds.Count) subscription(s) in the portal's scope" }

$mgmtToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
# Same basis as everything else the portal shows, so an Ask answer can't contradict the
# dashboard. The type is part of the query definition returned to the UI for transparency.
$costType = Get-CostTypeSetting -StorageToken $storageToken
$comparison = $null

# Asking subscriptions one by one. Cost Management does not answer management-group queries for
# CSP / MCA subscriptions, so when the tenant scope fell back to the deployment subscription,
# a portal-wide question goes to every subscription in scope and the rows are added up. A
# question that names subscriptions goes to those, whatever the tenant scope is.
$fanOut = $null; $missingSubs = @(); $stored = $null
$useContextSub = ([bool]$spec.scopeToContextSubscription -and $context -and $context.subscriptionId)
$querySubs = @(Get-QuerySubscriptions -Token $storageToken -Scope $subScope)

# The subscriptions the question names, found in its text (the model is not given the list of
# names): they become the subscription filter, replacing wherever the model put the name.
$namedInText = @(Find-SubscriptionsInText -Text $question -Subscriptions $querySubs)
if ($namedInText.Count -and -not $useContextSub) { $spec = Set-SpecSubscriptions -Spec $spec -Named $namedInText }

# First choice: the portal's own per-resource cost (nightly, every subscription, instant).
try {
    $storedSpec = $spec
    if ($useContextSub) {
        $storedSpec = $spec | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $storedSpec.filters = @(@($storedSpec.filters) | Where-Object { $_ }) + @([PSCustomObject]@{ dimension = 'SubscriptionId'; values = @([string]$context.subscriptionId) })
    }
    $index = Read-ResourceCostIndex -Token $storageToken
    if ($index) {
        $stored = Invoke-StoredCostQuery -Spec $storedSpec -IndexData $index -Subscriptions $querySubs `
            -Rate (Get-BillingCurrencyRate -StorageToken $storageToken) -Compare:([bool]$spec.compareWithPrevious)
    }
} catch { Write-Host "stored cost answer unavailable, asking Cost Management: $($_.Exception.Message)" }

if (-not $stored -and -not $useContextSub) {
    $sel = Select-SpecSubscriptions -Spec $spec -Subscriptions $querySubs
    if ($sel.Named -and -not @($sel.Subscriptions).Count) {
        Send-Json -Status BadRequest -Object @{ error = "No subscription in the portal's scope matches '$((@($sel.Unmatched) -join "', '"))'." }
        return
    }
    if ($sel.Named -or (($deploymentOnly -or $defaultScope -like '/subscriptions/*') -and $querySubs.Count -gt 1)) { $fanOut = $sel }
}
if (-not $stored -and -not $fanOut -and $defaultOutOfScope -and -not $useContextSub) {
    Send-Json -Status Conflict -Object @{ error = 'the cost query scope (the deployment subscription) is outside the portal''s subscription scope — set costQueryScope to a management group' }
    return
}

try {
    if ($stored) {
        $q = $stored
        $comparison = $stored.comparison
        $who = if ($useContextSub) { $scopeLabel }
               elseif ($namedInText.Count) { ($namedInText | ForEach-Object { $_.Name }) -join ', ' }
               else { "all $($querySubs.Count) subscriptions in the portal's scope" }
        $scopeLabel = "$who, $($stored.periodText), from the portal's nightly cost data (resource costs only; purchases not tied to a resource are not included)"
    } elseif ($fanOut) {
        $n = @($fanOut.Subscriptions).Count
        $q = Invoke-CostQueryAcrossSubscriptions -Spec $fanOut.Spec -MgmtToken $mgmtToken -Subscriptions @($fanOut.Subscriptions) `
            -CostType $costType -Compare:([bool]$spec.compareWithPrevious) -BudgetSeconds 120
        if (-not @($q.answered).Count) { throw "$(if (@($q.missing).Count) { 'COST_QUERY_THROTTLED' } else { 'no subscription answered' }): no subscription answered the query in time." }
        $comparison = $q.comparison
        $missingSubs = @($q.missing)
        $scopeLabel = if ($fanOut.Named) { (@($fanOut.Subscriptions) | ForEach-Object { $_.Name }) -join ', ' }
                      else { "all $n subscriptions in the portal's scope, asked one by one (Cost Management can't query them as a management group)" }
        if ($missingSubs.Count) { $scopeLabel += ". Not included, no answer in time: $($missingSubs -join ', ')" }
    } elseif ([bool]$spec.compareWithPrevious) {
        $q = Invoke-CostComparison -Spec $spec -MgmtToken $mgmtToken -Scope $scope -CostType $costType -SubscriptionIds $scopeSubIds
        $comparison = $q.comparison
    } else {
        $q = Invoke-CostQuery -Spec $spec -MgmtToken $mgmtToken -Scope $scope -Interactive -CostType $costType -SubscriptionIds $scopeSubIds
    }
} catch {
    if (Test-CostQueryThrottled -ErrorRecord $_) {
        Send-Json -Status TooManyRequests -ExtraHeaders @{ "Retry-After" = "120" } -Object (Write-ErrorBody -Message 'Azure is rate-limiting cost queries right now. Try again in a few minutes.' -Exception $_ -TriggerMetadata $TriggerMetadata)
        return
    }
    Send-Json -Status BadGateway -Object (Write-ErrorBody -Message 'cost query failed' -Exception $_ -TriggerMetadata $TriggerMetadata)
    return
}

# --- STEP 3: narrate the computed rows (cap what we send the model) ---
$rowsForModel = @($q.rows | Select-Object -First 50)
$answerSystem = Add-AiLanguageLine @'
You answer a user's Azure cost question using ONLY the result rows provided (already computed
from billing data). Be concise and specific, and cite figures from the rows. Amounts are in the
row's currency. Never invent numbers and never do arithmetic the rows don't show.
- comparison, when present: Cost is the current period, PreviousCost the previous one, Change
  and ChangePct the difference. Say which periods were compared. If approximate is true, say
  billing months were approximated by calendar months.
- context, when present, is what the user was looking at; relate the answer to it.
- history holds earlier answers in this conversation; don't repeat them.
- If there are no rows, say no matching cost was found for that query.
- scope says which subscriptions were asked. If it lists subscriptions that did not answer in
  time, say the figures leave them out.
'@
$answerSchema = @{ type = 'object'; additionalProperties = $false; required = @('answer'); properties = @{ answer = @{ type = 'string' } } }

$answer = $null
$grounded = $true
$aiLimited = $false
try {
    $answerPayload = [PSCustomObject]@{
        question   = $question
        scope      = $scopeLabel
        comparison = $comparison
        rows       = $rowsForModel
        rowCount   = @($q.rows).Count
        context    = $context
        history    = @($history | ForEach-Object { [PSCustomObject]@{ question = $_.question; answer = $_.answer } })
    }
    $ans = Invoke-AiCompletion -System $answerSystem -Schema $answerSchema -MaxTokens 600 -Purpose 'ask-answer' `
        -User ($answerPayload | ConvertTo-Json -Depth 8)
    $answer = if ($ans.Parsed -and $ans.Parsed.answer) { [string]$ans.Parsed.answer } else { [string]$ans.Text }
    # The answer is prose over rows the user can see right below it — check that every figure
    # in it came from what we sent.
    $grounded = Test-NarrativeGrounding -Narrative $answer -Payload $answerPayload
    if (-not $grounded) { Write-Host "Ask answer cited a number not present in the result rows — flagged." }
} catch {
    # The numbers are already computed; if narration fails, still return the rows + query.
    if (Test-AiBudgetExceeded -ErrorRecord $_) {
        $aiLimited = $true
        $answer = "The daily AI limit was reached after the query ran, so there is no written answer — the results are below."
    } else {
        $answer = "(Could not generate a written answer, but the query ran — see the results below.)"
    }
}

Send-Json -Status OK -Object ([PSCustomObject]@{
    answer         = $answer
    # False = the answer quotes a figure that is not in the rows.
    grounded       = $grounded
    aiLimitReached = $aiLimited
    spec           = $spec                               # the structured spec (for follow-ups)
    query          = $q.query                            # the definition(s) we executed (transparency)
    scope          = $scopeLabel
    # subscriptions that did not answer in time; the rows leave them out
    missingSubscriptions = @($missingSubs)
    comparison     = $comparison
    columns        = @($q.columns)
    rows           = @($q.rows | Select-Object -First 200) # cap what we ship the UI
    rowCount       = @($q.rows).Count
})
