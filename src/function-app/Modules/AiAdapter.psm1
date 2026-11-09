# ============================================================================
# AiAdapter.psm1 — the provider-agnostic AI layer (the "spine").
#
# Every feature that needs the model calls ONE function: Invoke-AiCompletion.
# It dispatches to a provider adapter based on the AI_PROVIDER app setting, so the
# rest of the codebase never knows or cares which vendor the customer brought.
#
# BYOK: the customer supplies their own provider, endpoint, model, and key. Nothing
# here is vendor-specific outside the per-provider adapters below. Two ways to authenticate
# (AI_AUTH_MODE):
#   - apiKey (default): the key is read from Key Vault via a managed-identity-backed app
#     setting reference (AI_API_KEY).
#   - managedIdentity: no key at all. The Function App's identity gets an Entra token for
#     Azure OpenAI / Foundry (needs 'Cognitive Services OpenAI User' on the account). Required
#     when the account sits behind a network security perimeter that admits a subscription:
#     such a rule only lets managed-identity-authenticated calls through, never API keys.
#
# Design rules (non-negotiable for this product):
#   - every NUMBER the model states must come from data it was given or a read-only query it
#     ran. Narration (Invoke-AiCompletion) gets precomputed figures; the findings agent
#     (Invoke-AiAgent, CostAgent.psm1) may run read-only cost queries itself, and its output is
#     checked against the tool results before anything is kept. No write path exists.
#   - the model never EXPLAINS WITHOUT EVIDENCE. A "why" question is only sent together with
#     deterministically gathered evidence (CostAnalysis.psm1 Get-CostChangeEvidence), and the
#     answer must cite it.
#   - every call counts against the daily budget (AiDailyCallLimit), see below.
#
# Supported providers (config value -> adapter):
#   "openai"    -> Invoke-OpenAiCompatible   (OpenAI, Azure OpenAI, Gemini compat,
#                                             Mistral, Groq, Together, Ollama, vLLM, ...)
#   "anthropic" -> Invoke-AnthropicMessages
# ============================================================================

# ----------------------------------------------------------------------------
# Configuration and authentication
# ----------------------------------------------------------------------------

function Test-AiManagedIdentity {
    return (([string]$env:AI_AUTH_MODE).Trim() -ieq 'managedIdentity')
}

# True when AI calls can be made: an endpoint, plus either a key or managed-identity mode.
# Every "is AI configured?" check in the app goes through here, so both modes behave alike.
function Test-AiConfigured {
    if ([string]::IsNullOrWhiteSpace($env:AI_ENDPOINT)) { return $false }
    return ((Test-AiManagedIdentity) -or -not [string]::IsNullOrWhiteSpace($env:AI_API_KEY))
}

function Assert-AiConfigured {
    if ([string]::IsNullOrWhiteSpace($env:AI_ENDPOINT)) { throw "AI_ENDPOINT is not configured. Run Setup/Configure-AiProvider.ps1." }
    if (-not (Test-AiConfigured)) { throw "AI_API_KEY is not configured (or set AI_AUTH_MODE=managedIdentity). Run Setup/Configure-AiProvider.ps1." }
}

# Request headers that authenticate one provider call.
function Get-AiAuthHeaders {
    param([Parameter(Mandatory)][string]$Provider, [Parameter(Mandatory)][string]$Endpoint, [string]$ApiKey)
    if (Test-AiManagedIdentity) {
        if ($Provider -ne 'openai' -or $Endpoint -notmatch 'azure\.com') {
            throw "AI_AUTH_MODE=managedIdentity works only with AI_PROVIDER=openai and an Azure OpenAI / Foundry endpoint (*.azure.com)."
        }
        $token = Get-ManagedIdentityToken -Resource 'https://cognitiveservices.azure.com/'
        if (-not $token) { throw "Could not get a managed-identity token for Azure OpenAI." }
        return @{ Authorization = "Bearer $token" }
    }
    if ($Provider -eq 'anthropic') { return @{ 'x-api-key' = $ApiKey; 'anthropic-version' = '2023-06-01' } }
    if ($Endpoint -match 'azure\.com') { return @{ 'api-key' = $ApiKey } }
    return @{ Authorization = "Bearer $ApiKey" }
}

# ----------------------------------------------------------------------------
# Private helpers
# ----------------------------------------------------------------------------

# Parse model output as JSON, tolerating a ```json ... ``` code fence. Returns the
# parsed object, or $null if the text isn't valid JSON.
function ConvertFrom-JsonLoose {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t.StartsWith('```')) {
        $t = ($t -replace '^```[a-zA-Z]*\s*', '' -replace '\s*```$', '').Trim()
    }
    try { return ($t | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# POST a JSON body and return the parsed response object.
#
# Retries 429 and 5xx with exponential backoff, honouring Retry-After when the provider
# sends it. Every AI provider throttles, and the nightly timers make many calls in a row:
# without this, one throttled response silently cost a spike its explanation for the day.
# 4xx other than 429 are permanent (bad key, bad model, bad request) and throw immediately.
# Invoke-WebRequest hands back Content as a byte[] rather than a string for some responses
# (notably the error bodies returned under -SkipHttpErrorCheck). Interpolating that into the
# thrown message logged "123 10 32 34 101 ..." instead of the provider's explanation — which is
# the single most useful line we get when a call fails, so decode it before it reaches anyone.
function ConvertTo-ResponseText {
    param($Content)
    if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
    return [string]$Content
}

function Invoke-HttpJson {
    param($Url, $Headers, $BodyObj, [int]$MaxAttempts = 4)
    $json = $BodyObj | ConvertTo-Json -Depth 20
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $resp = Invoke-WebRequest -Method POST -Uri $Url -Headers $Headers -Body $json `
            -ContentType 'application/json' -SkipHttpErrorCheck -TimeoutSec 120
        $code = [int]$resp.StatusCode
        if ($code -lt 400) { return ((ConvertTo-ResponseText $resp.Content) | ConvertFrom-Json) }
        if (($code -eq 429 -or $code -ge 500) -and $attempt -lt $MaxAttempts) {
            $wait = [Math]::Pow(2, $attempt) * 2        # 4s, 8s, 16s
            $ra = $resp.Headers['Retry-After']; if ($ra -is [array]) { $ra = $ra[0] }
            $parsed = 0
            if ($ra -and [int]::TryParse([string]$ra, [ref]$parsed) -and $parsed -gt 0) { $wait = $parsed }
            $wait = [Math]::Min([Math]::Max($wait, 2), 60)
            Write-Host "  AI provider returned $code — waiting ${wait}s then retrying (attempt $attempt/$MaxAttempts)"
            Start-Sleep -Seconds $wait
            continue
        }
        throw "AI provider returned HTTP ${code}: $(ConvertTo-ResponseText $resp.Content)"
    }
    throw "AI provider still throttling after $MaxAttempts attempts"
}

# Did the provider reject the REQUEST SHAPE (as opposed to failing for a real reason)?
#
# Providers disagree about what a "strict" JSON schema may contain — OpenAI requires every
# property to appear in `required` and rejects anything else with a 400 — and plenty of
# OpenAI-compatible endpoints (Ollama, vLLM, older gateways) don't implement
# response_format/output_config at all. Those all surface as a permanent 4xx on the request
# body, which is exactly the case the prompt-only fallback below exists to cover.
# Deliberately narrow: 401/403/404 mean a bad key, a bad model or a bad URL, and repeating
# the call without the schema just spends the customer's tokens on the same failure.
# (429/5xx never reach here — Invoke-HttpJson retries those itself.)
function Test-SchemaRejection {
    param($ErrorRecord)
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    return ($msg -like 'AI provider returned HTTP 400:*' -or $msg -like 'AI provider returned HTTP 422:*')
}

# Build the chat-completions URL from whatever the customer put in AI_ENDPOINT.
#
# The Azure hosts do NOT serve the chat route at the root — it lives under /openai — and the
# host on its own is exactly what the Azure AI Foundry overview blade shows, so it is what
# people paste. Appending '/chat/completions' to it yields a 404 ("Resource not found") on
# every AI call, which is a permanent error the schema fallback deliberately doesn't retry.
#
#   https://x.services.ai.azure.com          -> https://x.services.ai.azure.com/openai/v1/chat/completions
#   https://x.openai.azure.com               -> https://x.openai.azure.com/openai/v1/chat/completions
#   https://api.openai.com/v1                -> https://api.openai.com/v1/chat/completions
#   http://ollama:11434/v1                   -> http://ollama:11434/v1/chat/completions
#   ...anything already naming the route is taken verbatim, including the deployment-scoped
#   '/openai/deployments/<dep>/chat/completions?api-version=...' form.
#
# /openai/v1 is preferred over the deployment-scoped form because it takes the model from the
# request body, which is what this adapter sends — so one endpoint serves every deployment.
function Resolve-OpenAiChatUrl {
    param([Parameter(Mandatory)][string]$Endpoint)
    $e = $Endpoint.Trim()
    if ($e -match 'chat/completions') { return $e }        # caller gave the full route already
    $e = $e.TrimEnd('/')
    # The Responses API is a DIFFERENT protocol (input/output, not messages/choices) and this
    # adapter does not speak it — but it is the route Foundry's sample code hands people for
    # GPT-5, so it is the URL they arrive with. Point it at the sibling chat route rather than
    # appending to it, which would build .../responses/chat/completions and 404.
    if ($e -match '/responses$') { return ($e -replace '/responses$', '/chat/completions') }
    if ($e -match '\.(openai\.azure\.com|services\.ai\.azure\.com)$') { return "$e/openai/v1/chat/completions" }
    if ($e -match '/openai$') { return "$e/v1/chat/completions" }
    return "$e/chat/completions"
}

# Reasoning models (o-series, GPT-5) changed the sampling parameters: 'max_tokens' became
# 'max_completion_tokens', and 'temperature' accepts only its default. Sending the old shape is
# a hard 400 — and one that looks exactly like a schema rejection, so it would burn the
# prompt-only fallback and then fail the call outright.
#
# The model id is only a hint: under BYOK the caller may be pointing at an Azure deployment or a
# gateway alias whose name says nothing about the model behind it. So the request shape is seeded
# from the id and then corrected from the provider's own 400, which is the one reliable signal.
# Returns $true when something changed and the call is worth repeating.
function Update-OpenAiRequestShape {
    param([Parameter(Mandatory)][hashtable]$Shape, $ErrorRecord)
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    if ($msg -notlike 'AI provider returned HTTP 400:*') { return $false }

    $changed = $false
    # "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."
    if ($msg -match 'max_completion_tokens' -and $Shape.TokenParam -ne 'max_completion_tokens') {
        $Shape.TokenParam = 'max_completion_tokens'
        # Learning this from a 400 means it IS a reasoning model, whatever the deployment is
        # called — so give it room to think and keep the thinking cheap. Without this the next
        # attempt succeeds and returns an empty string, which is a far worse failure to debug.
        $Shape.TokenBudget = [Math]::Max($Shape.TokenBudget * 4, 2000)
        if (-not $Shape.EffortRejected) { $Shape.ReasoningEffort = 'minimal' }
        $changed = $true
    }
    # "Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported."
    if ($msg -match "'temperature'" -and $Shape.SendTemperature) {
        $Shape.SendTemperature = $false; $changed = $true
    }
    # "Function tools with reasoning_effort are not supported for <model> in /v1/chat/completions.
    # To use function tools, use /v1/responses or set reasoning_effort to 'none'." — newer reasoning
    # models. Leaving the parameter out is NOT the same: the model then applies its default effort
    # and refuses again, so it must be sent as 'none' explicitly (and never dropped afterwards).
    if ($msg -match "reasoning_effort to 'none'" -and $Shape.ReasoningEffort -ne 'none') {
        $Shape.ReasoningEffort = 'none'; $Shape.EffortRejected = $true
        return $true
    }
    # "Unrecognized request argument supplied: reasoning_effort" — an older deployment or a
    # gateway that took the rest of the modern shape but not this one.
    if ($msg -match 'reasoning_effort' -and $Shape.ReasoningEffort -and $Shape.ReasoningEffort -ne 'none') {
        $Shape.ReasoningEffort = $null; $Shape.EffortRejected = $true; $changed = $true
    }
    return $changed
}

# Drive the "request structured output, parse, retry once" flow shared by all adapters.
#   $Call      : scriptblock taking [bool]$Strict, returns @{ Text=<string>; Usage=<hash> }.
#                When $Strict is $false the adapter drops native structured-output and instead
#                instructs the model to emit raw JSON (the universal fallback).
#   $HasSchema : whether the caller asked for structured output at all.
#
# There are TWO ways the strict attempt can fail, and both fall back to the same place:
#   - it answers, but not with parseable JSON  -> reparse path below
#   - it REJECTS the request outright (4xx)    -> Test-SchemaRejection path
# The second used to be unreachable: Invoke-HttpJson throws on a 400, so the exception blew
# past this function and the caller lost the narration entirely — the fallback was documented
# but could never actually run for the failure mode most likely to need it.
function Resolve-StructuredResult {
    param([scriptblock]$Call, [bool]$HasSchema)

    if (-not $HasSchema) {
        $plain = & $Call $true
        return @{ Text = $plain.Text; Parsed = $null; Usage = $plain.Usage }
    }

    $r = $null
    try {
        $r = & $Call $true
    } catch {
        if (-not (Test-SchemaRejection -ErrorRecord $_)) { throw }
        Write-Host "  AI provider rejected the structured-output request ($($_.Exception.Message)) — retrying with a prompt-only JSON instruction."
        $rf = & $Call $false
        return @{ Text = $rf.Text; Parsed = (ConvertFrom-JsonLoose $rf.Text); Usage = $rf.Usage }
    }

    $parsed = ConvertFrom-JsonLoose $r.Text
    if ($null -ne $parsed) { return @{ Text = $r.Text; Parsed = $parsed; Usage = $r.Usage } }

    # One retry: ask for raw JSON without the provider's native structured-output mode.
    $r2 = & $Call $false
    $parsed2 = ConvertFrom-JsonLoose $r2.Text
    if ($null -eq $parsed2) {
        # Both attempts produced something we can't parse. The caller turns this into a flat
        # "could not translate the question" with nowhere to go next, so record what actually
        # came back — an empty string means a token-budget problem, prose means a prompt one,
        # and telling those apart from the outside is otherwise guesswork.
        $sample = if ([string]::IsNullOrEmpty($r2.Text)) { '<empty>' }
                  else { $r2.Text.Substring(0, [Math]::Min(300, $r2.Text.Length)) }
        Write-Host "  Model output was not parseable JSON after both attempts. First 300 chars: $sample"
    }
    return @{ Text = $r2.Text; Parsed = $parsed2; Usage = $r2.Usage }
}

# ----------------------------------------------------------------------------
# DAILY AI BUDGET — the customer's key, the customer's money.
#
# Nightly narration is bounded by design, but the interactive paths (Ask, Explain, brief
# regeneration) are not: nothing stopped a curious user from spending the key all afternoon.
# Every call through Invoke-AiCompletion is counted against PortalConfig 'settings'/'current'
# AiDailyCallLimit (default 200, 0 = AI switched off). The counter lives in PortalConfig
# PK 'aiusage', RK = UTC date, and is incremented BEFORE the provider is called.
#
# Over the limit the call throws a message starting with AI_BUDGET_EXCEEDED (see
# Test-AiBudgetExceeded). Timers already treat AI as best-effort and fall back to their
# deterministic text; HTTP endpoints answer 429.
#
# The counter is approximate: the worker runs up to three invocations at once and a table
# MERGE carries no ETag here, so two concurrent calls can both read N and both write N+1.
# That can let a handful of calls past the limit on a busy day — acceptable for a spend guard,
# which is about not running away, not about the exact count. One Invoke-AiCompletion counts
# as one call even when the adapter retries internally (schema fallback, throttling).
#
# If the counter itself cannot be read or written the call proceeds (logged). A storage
# outage already breaks every page; failing AI closed on top of that would hide the real fault.
# ----------------------------------------------------------------------------
$script:AiBudgetMarker = 'AI_BUDGET_EXCEEDED'
$script:DefaultAiDailyCallLimit = 200
$script:AiLimitCache = @{ Value = $null; At = [datetime]::MinValue }

# The configured limit, cached for five minutes so a timer narrating 20 findings doesn't read
# the settings row 20 times. Clamped to 0..10000; unset or unreadable = the default.
function Get-AiDailyCallLimit {
    param([Parameter(Mandatory)][string]$StorageToken, [switch]$NoCache)
    if (-not $NoCache -and $null -ne $script:AiLimitCache.Value -and
        ([datetime]::UtcNow - $script:AiLimitCache.At).TotalMinutes -lt 5) {
        return [int]$script:AiLimitCache.Value
    }
    $limit = $script:DefaultAiDailyCallLimit
    try {
        $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'current'" -Token $StorageToken) | Select-Object -First 1
        if ($row -and $null -ne $row.AiDailyCallLimit) {
            $limit = [int][Math]::Max(0, [Math]::Min(10000, [int]$row.AiDailyCallLimit))
        }
    } catch { Write-Host "AI limit read failed, using $limit`: $($_.Exception.Message)" }
    $script:AiLimitCache = @{ Value = $limit; At = [datetime]::UtcNow }
    return $limit
}

# Today's usage row as { Calls; InputTokens; OutputTokens } (zeros when nothing yet).
function Get-AiUsageToday {
    param([Parameter(Mandatory)][string]$StorageToken)
    $day = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'aiusage' and RowKey eq '$day'" -Token $StorageToken) | Select-Object -First 1
    return [PSCustomObject]@{
        Date         = $day
        Calls        = if ($row -and $null -ne $row.Calls) { [int]$row.Calls } else { 0 }
        InputTokens  = if ($row -and $null -ne $row.InputTokens) { [long]$row.InputTokens } else { 0 }
        OutputTokens = if ($row -and $null -ne $row.OutputTokens) { [long]$row.OutputTokens } else { 0 }
    }
}

# True when an error is the budget refusal rather than a provider failure.
function Test-AiBudgetExceeded {
    param($ErrorRecord)
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    return $msg -like "$($script:AiBudgetMarker)*"
}

# Reserve one call against today's budget, or throw. Returns the state needed to record token
# usage afterwards ($null when the counter was unavailable).
function Request-AiBudget {
    param([string]$Purpose)
    $token = $null; $limit = $null; $usage = $null
    try {
        $token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
        $limit = Get-AiDailyCallLimit -StorageToken $token
        $usage = Get-AiUsageToday -StorageToken $token
    } catch {
        Write-Host "AI budget check unavailable, allowing the call: $($_.Exception.Message)"
        return $null
    }

    if ($limit -eq 0) {
        throw "$($script:AiBudgetMarker): AI is switched off for this portal (AiDailyCallLimit = 0)."
    }
    if ($usage.Calls -ge $limit) {
        throw "$($script:AiBudgetMarker): the daily limit of $limit AI calls has been reached ($($usage.Calls) used today, UTC). It resets at midnight UTC; an admin can raise AiDailyCallLimit."
    }

    try {
        Set-TableEntity -Table 'PortalConfig' -Token $token -Entity @{
            PartitionKey = 'aiusage'; RowKey = $usage.Date
            Calls = [int]($usage.Calls + 1); LastPurpose = [string]$Purpose
            LastAt = ([datetime]::UtcNow.ToString('o'))
        }
    } catch { Write-Host "AI usage counter write failed (call allowed): $($_.Exception.Message)" }
    return @{ Token = $token; Date = $usage.Date }
}

# Add a call's token counts to today's row. Best-effort, never throws.
function Add-AiTokenUsage {
    param($Reservation, $Usage)
    if (-not $Reservation -or -not $Usage) { return }
    try {
        $now = Get-AiUsageToday -StorageToken $Reservation.Token
        Set-TableEntity -Table 'PortalConfig' -Token $Reservation.Token -Entity @{
            PartitionKey = 'aiusage'; RowKey = $Reservation.Date
            InputTokens  = [long]($now.InputTokens + [long]($Usage.InputTokens ?? 0))
            OutputTokens = [long]($now.OutputTokens + [long]($Usage.OutputTokens ?? 0))
        }
    } catch { Write-Host "AI token usage write failed: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------
# Invoke-AiCompletion — the single entry point / agnostic contract.
#
#   -System / -User / -Schema (optional JSON-schema hashtable) / -MaxTokens
#   -Purpose  short label for logs and the usage row, e.g. 'spike-explanation', 'ask'
# Returns: [PSCustomObject] @{ Text; Parsed; Usage; Provider; Model }
# Throws AI_BUDGET_EXCEEDED… when the daily call limit is reached (Test-AiBudgetExceeded).
# ----------------------------------------------------------------------------
function Invoke-AiCompletion {
    param(
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User,
        [hashtable]$Schema,
        [int]$MaxTokens = 1024,
        [string]$Purpose = 'unspecified'
    )

    $provider = ($env:AI_PROVIDER ?? 'openai').ToLower()
    $endpoint = $env:AI_ENDPOINT
    $model    = $env:AI_MODEL
    $apiKey   = $env:AI_API_KEY   # Key Vault reference resolved by the platform (empty in managedIdentity mode)

    Assert-AiConfigured
    if ($provider -notin @('openai', 'anthropic')) { throw "Unsupported AI_PROVIDER '$provider'. Supported: openai, anthropic." }

    $reservation = Request-AiBudget -Purpose $Purpose

    $params = @{
        Endpoint = $endpoint; Model = $model; ApiKey = $apiKey
        System = $System; User = $User; Schema = $Schema; MaxTokens = $MaxTokens
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = if ($provider -eq 'anthropic') { Invoke-AnthropicMessages @params } else { Invoke-OpenAiCompatible @params }
    $sw.Stop()

    # One line per call, so spend is visible in Application Insights traces by purpose.
    $inTok = if ($result.Usage) { $result.Usage.InputTokens } else { $null }
    $outTok = if ($result.Usage) { $result.Usage.OutputTokens } else { $null }
    Write-Host "[ai] purpose=$Purpose provider=$provider model=$model inputTokens=$inTok outputTokens=$outTok ms=$($sw.ElapsedMilliseconds)"
    Add-AiTokenUsage -Reservation $reservation -Usage $result.Usage

    return $result
}

# ----------------------------------------------------------------------------
# Invoke-OpenAiCompatible — any OpenAI-compatible /chat/completions API.
#   Auth: 'Authorization: Bearer' for OpenAI-style; 'api-key' for Azure OpenAI
#         (detected by an *.azure.com endpoint).
#   URL : see Resolve-OpenAiChatUrl — the bare Azure host needs '/openai/v1' inserted.
#   Structured output: response_format = json_schema (strict) when -Schema given.
#   Sampling params: see Update-OpenAiRequestShape — reasoning models renamed them.
# ----------------------------------------------------------------------------
function Invoke-OpenAiCompatible {
    param($Endpoint, $Model, $ApiKey, $System, $User, $Schema, $MaxTokens)

    $url = Resolve-OpenAiChatUrl -Endpoint $Endpoint
    $headers = Get-AiAuthHeaders -Provider 'openai' -Endpoint $Endpoint -ApiKey $ApiKey

    # A hashtable, not separate variables: the scriptblock below mutates it in place across
    # attempts, so what one call learns from a 400 the next one already knows.
    $shape = @{ TokenParam = 'max_tokens'; SendTemperature = $true
                ReasoningEffort = $null; EffortRejected = $false; TokenBudget = $MaxTokens }
    if ($Model -match '(?i)^(o[1-9]|gpt-5)') {
        $shape.TokenParam = 'max_completion_tokens'
        $shape.SendTemperature = $false
        # On a reasoning model max_completion_tokens covers the THINKING as well as the answer,
        # so a budget sized for the answer alone gets spent before a single visible token is
        # emitted — the call succeeds and returns ''. Two defences: ask for the least reasoning
        # the model offers (this product narrates precomputed numbers, it does not solve
        # anything), and raise the ceiling. Raising it is free — it is a cap, not a reservation,
        # and output tokens are billed as used.
        $shape.ReasoningEffort = 'minimal'
        $shape.TokenBudget = [Math]::Max($MaxTokens * 4, 2000)
    }

    $call = {
        param([bool]$Strict)
        $sys = $System
        $bodyObj = @{
            model      = $Model
            messages   = @(
                @{ role = 'system'; content = $sys }
                @{ role = 'user';   content = $User }
            )
        }
        if ($Schema -and $Strict) {
            $bodyObj.response_format = @{ type = 'json_schema'; json_schema = @{ name = 'result'; schema = $Schema; strict = $true } }
        } elseif ($Schema) {
            $bodyObj.messages[0].content = $sys + "`n`nRespond with ONLY a single minified JSON object matching the schema. No prose, no markdown, no code fences."
        }

        # Bounded by construction: three parameter corrections are available and each fires at
        # most once (Update-OpenAiRequestShape returns $true only when it actually changed
        # something), plus two budget escalations before the cap gives up. The loop cannot spin.
        $resp = $null
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $bodyObj.Remove('max_tokens');  $bodyObj.Remove('max_completion_tokens')
            $bodyObj.Remove('temperature'); $bodyObj.Remove('reasoning_effort')
            $bodyObj[$shape.TokenParam] = $shape.TokenBudget
            if ($shape.SendTemperature) { $bodyObj['temperature'] = 0 }
            if ($shape.ReasoningEffort)  { $bodyObj['reasoning_effort'] = $shape.ReasoningEffort }

            try { $resp = Invoke-HttpJson -Url $url -Headers $headers -BodyObj $bodyObj }
            catch {
                if (-not (Update-OpenAiRequestShape -Shape $shape -ErrorRecord $_)) { throw }
                Write-Host "  AI provider rejected a request parameter — retrying with $($shape.TokenParam)=$($shape.TokenBudget), temperature $(if ($shape.SendTemperature) { '0' } else { 'omitted' }), reasoning_effort $(if ($shape.ReasoningEffort) { $shape.ReasoningEffort } else { 'omitted' })."
                continue
            }

            # A reasoning model can spend the entire budget thinking and return EMPTY content
            # with finish_reason 'length'. That is a 200, so nothing throws; the empty string
            # parses to $null and reaches the user as "could not translate the question" — a
            # content error blamed for what is really a budget one. Catch it here instead.
            $choice = $resp.choices[0]
            if ([string]::IsNullOrWhiteSpace([string]$choice.message.content) -and $choice.finish_reason -eq 'length') {
                $spent = [int]$resp.usage.completion_tokens
                if ($shape.TokenBudget -lt 16000) {
                    $shape.TokenBudget = $shape.TokenBudget * 4
                    Write-Host "  Model returned no content — all $spent completion tokens went to reasoning. Retrying with a budget of $($shape.TokenBudget)."
                    continue
                }
                throw "AI provider returned no content: '$Model' spent all $spent completion tokens on reasoning without emitting an answer. Lower reasoning_effort or raise the token budget."
            }
            break
        }
        if ($null -eq $resp) { throw "AI provider gave no usable response after $($shape.TokenBudget)-token attempts." }

        $text = [string]$resp.choices[0].message.content
        $usage = @{ InputTokens = $resp.usage.prompt_tokens; OutputTokens = $resp.usage.completion_tokens }
        return @{ Text = $text; Usage = $usage }
    }

    $res = Resolve-StructuredResult -Call $call -HasSchema:([bool]$Schema)
    return [PSCustomObject]@{ Text = $res.Text; Parsed = $res.Parsed; Usage = $res.Usage; Provider = 'openai'; Model = $Model }
}

# ----------------------------------------------------------------------------
# Invoke-AnthropicMessages — the Anthropic Messages API.
#   Auth: 'x-api-key' + 'anthropic-version: 2023-06-01'.
#   URL : append '/v1/messages' unless already present.
#   Structured output: output_config.format = json_schema when -Schema given.
#   Thinking is omitted (cheap, short narration; omitting is safe across models).
# ----------------------------------------------------------------------------
function Invoke-AnthropicMessages {
    param($Endpoint, $Model, $ApiKey, $System, $User, $Schema, $MaxTokens)

    $url = if ($Endpoint -match '/v1/messages') { $Endpoint } else { $Endpoint.TrimEnd('/') + '/v1/messages' }
    $headers = Get-AiAuthHeaders -Provider 'anthropic' -Endpoint $Endpoint -ApiKey $ApiKey

    $call = {
        param([bool]$Strict)
        $sys = $System
        $bodyObj = @{
            model      = $Model
            max_tokens = $MaxTokens
            system     = $sys
            messages   = @(@{ role = 'user'; content = $User })
        }
        if ($Schema -and $Strict) {
            $bodyObj.output_config = @{ format = @{ type = 'json_schema'; schema = $Schema } }
        } elseif ($Schema) {
            $bodyObj.system = $sys + "`n`nRespond with ONLY a single minified JSON object matching the schema. No prose, no markdown, no code fences."
        }
        $resp = Invoke-HttpJson -Url $url -Headers $headers -BodyObj $bodyObj
        $textBlock = @($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1)
        $text = if ($textBlock.Count) { [string]$textBlock[0].text } else { '' }
        $usage = @{ InputTokens = $resp.usage.input_tokens; OutputTokens = $resp.usage.output_tokens }
        return @{ Text = $text; Usage = $usage }
    }

    $res = Resolve-StructuredResult -Call $call -HasSchema:([bool]$Schema)
    return [PSCustomObject]@{ Text = $res.Text; Parsed = $res.Parsed; Usage = $res.Usage; Provider = 'anthropic'; Model = $Model }
}

# ----------------------------------------------------------------------------
# Invoke-AiAgent — a bounded tool-calling loop for the weekly / monthly findings (CostAgent.psm1).
#
# The model may call READ-ONLY tools that the caller defines; the caller's -ToolHandler runs each
# call and returns a result object, which goes back to the model as JSON. The loop ends when the
# model answers without calling a tool, or after -MaxSteps model calls (the last one is made with
# tool_choice 'none', so it has to answer).
#
#   -Tools        @( @{ name; description; parameters = <JSON schema hashtable> } )
#   -ToolHandler  { param([string]$Name, $Arguments) ... return <object> } — never throws to here:
#                 an error is returned to the model as { error = '...' } so it can recover.
# Returns [PSCustomObject] @{ Text; Parsed; Steps; ToolCalls = @(@{ Name; Arguments; Result }) }
#
# Every model call counts against the daily AI limit, like Invoke-AiCompletion. The final text
# is parsed as JSON (ConvertFrom-JsonLoose); when that fails and -Schema is given, ONE extra
# Invoke-AiCompletion turns the text into the schema.
# ----------------------------------------------------------------------------
function Invoke-AiAgent {
    param(
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][object[]]$Tools,
        [Parameter(Mandatory)][scriptblock]$ToolHandler,
        [hashtable]$Schema,
        [int]$MaxSteps = 8,
        [int]$MaxTokens = 2000,
        [string]$Purpose = 'agent'
    )
    $provider = ($env:AI_PROVIDER ?? 'openai').ToLower()
    $endpoint = $env:AI_ENDPOINT; $model = $env:AI_MODEL; $apiKey = $env:AI_API_KEY
    Assert-AiConfigured
    if ($provider -notin @('openai', 'anthropic')) { throw "Unsupported AI_PROVIDER '$provider'. Supported: openai, anthropic." }

    $calls = [System.Collections.Generic.List[object]]::new()
    $runTool = {
        param([string]$Name, $ArgsObj)
        $result = $null
        try { $result = & $ToolHandler $Name $ArgsObj }
        catch { $result = [PSCustomObject]@{ error = $_.Exception.Message } }
        $calls.Add([PSCustomObject]@{ Name = $Name; Arguments = $ArgsObj; Result = $result })
        return ($result | ConvertTo-Json -Depth 10 -Compress)
    }

    $text = ''; $step = 0
    if ($provider -eq 'anthropic') {
        $url = if ($endpoint -match '/v1/messages') { $endpoint } else { $endpoint.TrimEnd('/') + '/v1/messages' }
        $headers = Get-AiAuthHeaders -Provider 'anthropic' -Endpoint $endpoint -ApiKey $apiKey
        $toolDefs = @($Tools | ForEach-Object { @{ name = $_.name; description = $_.description; input_schema = $_.parameters } })
        $messages = [System.Collections.Generic.List[object]]::new()
        $messages.Add(@{ role = 'user'; content = $User })
        for ($step = 1; $step -le $MaxSteps; $step++) {
            $last = ($step -eq $MaxSteps)
            $body = @{ model = $model; max_tokens = $MaxTokens; system = $System; messages = @($messages); tools = $toolDefs
                       tool_choice = @{ type = $(if ($last) { 'none' } else { 'auto' }) } }
            $reservation = Request-AiBudget -Purpose $Purpose
            $resp = Invoke-HttpJson -Url $url -Headers $headers -BodyObj $body
            Add-AiTokenUsage -Reservation $reservation -Usage @{ InputTokens = $resp.usage.input_tokens; OutputTokens = $resp.usage.output_tokens }
            Write-Host "[ai] purpose=$Purpose step=$step provider=anthropic model=$model inputTokens=$($resp.usage.input_tokens) outputTokens=$($resp.usage.output_tokens)"
            $uses = @($resp.content | Where-Object { $_.type -eq 'tool_use' })
            if (-not $uses.Count) {
                $text = (@($resp.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n")
                break
            }
            $messages.Add(@{ role = 'assistant'; content = @($resp.content) })
            $results = @(foreach ($u in $uses) {
                @{ type = 'tool_result'; tool_use_id = [string]$u.id; content = (& $runTool ([string]$u.name) $u.input) }
            })
            $messages.Add(@{ role = 'user'; content = $results })
        }
    } else {
        $url = Resolve-OpenAiChatUrl -Endpoint $endpoint
        $headers = Get-AiAuthHeaders -Provider 'openai' -Endpoint $endpoint -ApiKey $apiKey
        $shape = @{ TokenParam = 'max_tokens'; SendTemperature = $true; ReasoningEffort = $null; EffortRejected = $false; TokenBudget = $MaxTokens }
        if ($model -match '(?i)^(o[1-9]|gpt-5)') {
            # Reasoning model: the budget covers the thinking too (see Invoke-OpenAiCompatible).
            $shape.TokenParam = 'max_completion_tokens'; $shape.SendTemperature = $false
            $shape.ReasoningEffort = 'low'; $shape.TokenBudget = [Math]::Max($MaxTokens * 4, 8000)
        }
        $toolDefs = @($Tools | ForEach-Object { @{ type = 'function'; function = @{ name = $_.name; description = $_.description; parameters = $_.parameters } } })
        $messages = [System.Collections.Generic.List[object]]::new()
        $messages.Add(@{ role = 'system'; content = $System })
        $messages.Add(@{ role = 'user'; content = $User })
        for ($step = 1; $step -le $MaxSteps; $step++) {
            $last = ($step -eq $MaxSteps)
            $body = @{ model = $model; messages = @($messages); tools = $toolDefs; tool_choice = $(if ($last) { 'none' } else { 'auto' }) }
            $reservation = Request-AiBudget -Purpose $Purpose
            $resp = $null
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                $body.Remove('max_tokens'); $body.Remove('max_completion_tokens'); $body.Remove('temperature'); $body.Remove('reasoning_effort')
                $body[$shape.TokenParam] = $shape.TokenBudget
                if ($shape.SendTemperature) { $body['temperature'] = 0 }
                if ($shape.ReasoningEffort) { $body['reasoning_effort'] = $shape.ReasoningEffort }
                try { $resp = Invoke-HttpJson -Url $url -Headers $headers -BodyObj $body; break }
                catch { if (-not (Update-OpenAiRequestShape -Shape $shape -ErrorRecord $_)) { throw } }
            }
            if ($null -eq $resp) { throw "AI provider gave no usable response." }
            Add-AiTokenUsage -Reservation $reservation -Usage @{ InputTokens = $resp.usage.prompt_tokens; OutputTokens = $resp.usage.completion_tokens }
            Write-Host "[ai] purpose=$Purpose step=$step provider=openai model=$model inputTokens=$($resp.usage.prompt_tokens) outputTokens=$($resp.usage.completion_tokens)"
            $msg = $resp.choices[0].message
            $toolCalls = @($msg.tool_calls | Where-Object { $_ })
            if (-not $toolCalls.Count) { $text = [string]$msg.content; break }
            $messages.Add(@{ role = 'assistant'; content = $(if ($msg.content) { [string]$msg.content } else { $null })
                             tool_calls = @($toolCalls | ForEach-Object { @{ id = [string]$_.id; type = 'function'; function = @{ name = [string]$_.function.name; arguments = [string]$_.function.arguments } } }) })
            foreach ($tc in $toolCalls) {
                $argsObj = $null
                try { $argsObj = ([string]$tc.function.arguments | ConvertFrom-Json) } catch { $argsObj = $null }
                $messages.Add(@{ role = 'tool'; tool_call_id = [string]$tc.id; content = (& $runTool ([string]$tc.function.name) $argsObj) })
            }
        }
    }

    $parsed = ConvertFrom-JsonLoose $text
    if ($null -eq $parsed -and $Schema -and -not [string]::IsNullOrWhiteSpace($text)) {
        $fix = Invoke-AiCompletion -System 'Convert the text into a single JSON object that matches the schema. Keep its content and figures exactly; add nothing.' `
            -User $text -Schema $Schema -MaxTokens $MaxTokens -Purpose "$Purpose-format"
        $parsed = $fix.Parsed
    }
    return [PSCustomObject]@{ Text = $text; Parsed = $parsed; Steps = [Math]::Min($step, $MaxSteps); ToolCalls = @($calls) }
}

Export-ModuleMember -Function Invoke-AiCompletion, Invoke-OpenAiCompatible, Invoke-AnthropicMessages, `
    Invoke-AiAgent, Test-AiBudgetExceeded, Get-AiDailyCallLimit, Get-AiUsageToday, `
    Test-AiConfigured, Get-AiAuthHeaders
