# profile.ps1 — runs once per PowerShell worker startup; functions defined here are
# available to every function in the app.
#
# Shared library code lives in ./Modules (AiAdapter.psm1, CostAnalysis.psm1, SavingsFinder.psm1).
# We import them EXPLICITLY here: the Functions runtime adds ./Modules to PSModulePath, but
# PowerShell command auto-loading only discovers modules laid out as Modules/<Name>/<Name>.psm1 —
# loose .psm1 files are not auto-imported. Importing here makes their exported functions available
# to every function in the app.
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Modules') -Filter '*.psm1' -ErrorAction SilentlyContinue |
    ForEach-Object { Import-Module $_.FullName -Force -Global }

# ============================================================================
# No credentials in logs.
#
# When Invoke-RestMethod / Invoke-WebRequest throw on an HTTP error, the ErrorRecord's TargetObject
# is the HttpRequestMessage — WITH its headers. The Functions worker writes an uncaught error record
# in full to the log, so a failing storage call put a live 'Authorization: Bearer ...' token (and a
# failing token request the X-IDENTITY-HEADER secret) into Application Insights.
#
# These global wrappers shadow the two cmdlets for every function and module (functions take
# precedence over cmdlets, and the modules fall back to the global scope). On failure they throw a
# NEW error that keeps what is useful — status, method, host and path, and the service's own error
# text — and drops the request object. The query string is dropped too, in case it ever carries a
# SAS. Behaviour on success is unchanged. Tests replace both with stubs (Tests/TestKit.ps1).
# ============================================================================
function global:ConvertTo-SafeWebError {
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    $req = $ErrorRecord.TargetObject
    $where = ''
    if ($req -is [System.Net.Http.HttpRequestMessage] -and $req.RequestUri) {
        $u = $req.RequestUri
        $where = " from $($req.Method) $($u.Scheme)://$($u.Host)$($u.AbsolutePath)"
    }
    $status = ''
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and $resp.StatusCode) { $status = "HTTP $([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
    $detail = [string]$ErrorRecord.ErrorDetails.Message
    if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + '…' }
    $msg = if ($status) { "$status$where" } else { "$($ErrorRecord.Exception.Message)$where" }
    if ($detail) { $msg += ": $detail" }
    return [System.Exception]::new($msg)
}
function global:Invoke-RestMethod {
    try { Microsoft.PowerShell.Utility\Invoke-RestMethod @args }
    catch { throw (ConvertTo-SafeWebError -ErrorRecord $_) }
}
function global:Invoke-WebRequest {
    try { Microsoft.PowerShell.Utility\Invoke-WebRequest @args }
    catch { throw (ConvertTo-SafeWebError -ErrorRecord $_) }
}

# ============================================================================
# Get-Caller — resolve the signed-in user and their portal role from the
# EasyAuth-injected headers. This is the authorization boundary: read endpoints
# and the mutating config endpoints call it to enforce admin vs member access
# server-side.
#
# Trust model:
#   - When EasyAuth is enabled it injects X-MS-CLIENT-PRINCIPAL(-NAME) and strips any
#     client-supplied copy, so these headers cannot be spoofed.
#   - When a principal IS present but carries neither role, access is denied (defense in
#     depth behind "Assignment required = Yes").
#   - When there is NO principal header the request is UNAUTHENTICATED. Every function is
#     `authLevel: anonymous`, so this is the only gate in front of tenant-wide cost data,
#     the config endpoints, and the endpoints that spend the customer's AI key. It
#     therefore FAILS CLOSED: access is denied unless the operator has explicitly opted
#     into public mode by setting the app setting ALLOW_ANONYMOUS_ACCESS=true
#     (bicep param `allowAnonymousAccess`, default false).
#
#     Deploying without EasyAuth used to grant every anonymous caller full admin — anyone
#     who found the Function App hostname. Opting in is now a deliberate, auditable act.
#
# Roles for this product:
#   FinOps.Admin  — full access: change thresholds / AI provider config, see everything.
#   FinOps.Member — read-only: view spikes, narratives, recommendations.
# ============================================================================
function Get-Caller {
    param($Request)

    $hdrs = $Request.Headers
    function script:_hdr([string]$name) {
        if ($null -eq $hdrs) { return $null }
        foreach ($k in $hdrs.Keys) {
            if ($k -ieq $name) { $v = $hdrs[$k]; if ($v -is [array]) { $v = $v[0] }; return $v }
        }
        return $null
    }

    $b64 = script:_hdr 'x-ms-client-principal'
    $upn = script:_hdr 'x-ms-client-principal-name'
    $roles = @()

    if ($b64) {
        try {
            $p = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
            $claims = @($p.claims)
            if (-not $upn) {
                $c = $claims | Where-Object { $_.typ -in @('preferred_username', 'name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn') } | Select-Object -First 1
                if ($c) { $upn = $c.val }
            }
            $roles = @($claims | Where-Object { $_.typ -eq 'roles' -or $_.typ -eq 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role' } | ForEach-Object { $_.val })
        } catch { }
    }

    $authEnabled = [bool]$b64
    # Public mode must be opted into explicitly; absence of the setting means deny.
    $anonAllowed = ($env:ALLOW_ANONYMOUS_ACCESS -eq 'true')

    if ($authEnabled) {
        $isAdmin  = $roles -contains 'FinOps.Admin'
        $isMember = ($roles -contains 'FinOps.Member') -and -not $isAdmin
        $denied   = -not ($isAdmin -or $isMember)
        $reason   = if ($denied) { "signed in as '$upn' but assigned neither FinOps.Admin nor FinOps.Member" } else { $null }
    } elseif ($anonAllowed) {
        # Explicit public mode: no identity to check, so every caller is treated as admin.
        $isAdmin = $true; $isMember = $false; $denied = $false; $reason = $null
    } else {
        $isAdmin = $false; $isMember = $false; $denied = $true
        $reason  = 'unauthenticated: App Service Authentication is not configured on this API. Deploy with authClientId set, or set allowAnonymousAccess=true to run the portal openly.'
    }

    return [PSCustomObject]@{
        Upn         = if ($upn) { $upn.ToLower() } else { $null }
        Roles       = $roles
        AuthEnabled = $authEnabled
        IsAdmin     = $isAdmin
        IsMember    = $isMember
        Denied      = $denied
        DenyReason  = $reason
    }
}

# Standard 403 body for a denied caller — carries the reason so an operator who deployed
# without EasyAuth (and without opting into public mode) can see why everything is closed.
function Get-DenyBody {
    param($Caller, [string]$Error = 'forbidden')
    return (@{ error = $Error; reason = $Caller.DenyReason } | ConvertTo-Json -Compress)
}

# ============================================================================
# Write-ErrorBody — the response body for a failed downstream call.
#
# Upstream exception text (Cost Management, Resource Graph, Key Vault, the AI provider) can
# carry resource ids, tenant/subscription identifiers, endpoint URLs and provider-side
# diagnostics. Endpoints used to pass `$_.Exception.Message` straight back to the browser,
# which hands all of that to any Member-role user — and to anyone at all in public mode.
#
# The detail goes to the logs (Application Insights traces) with a correlation id; the caller
# gets the id and a generic message, which is enough for a user to quote in a support request
# and for an operator to find the exact invocation.
# ============================================================================
function Write-ErrorBody {
    param(
        [Parameter(Mandatory)][string]$Message,   # safe, caller-facing summary
        $Exception,                                # logged, never returned
        $TriggerMetadata
    )
    $correlationId = if ($TriggerMetadata -and $TriggerMetadata.InvocationId) { [string]$TriggerMetadata.InvocationId }
                     else { [guid]::NewGuid().ToString() }
    if ($Exception) {
        $detail = if ($Exception -is [System.Management.Automation.ErrorRecord]) { $Exception.Exception.Message } else { "$Exception" }
        Write-Host "[$correlationId] $Message — $detail"
    } else {
        Write-Host "[$correlationId] $Message"
    }
    return (@{ error = $Message; correlationId = $correlationId } | ConvertTo-Json -Compress)
}

# ============================================================================
# Write-AuditEntry — one AuditLog row per privileged or budget-spending action.
#
# Partitioned by month so a month's trail is one partition read. Never throws: an audit write
# that fails is logged, but must not turn a successful action into an error for the user.
# Details is serialised as compact JSON; keep it small (ids, not payloads).
# ============================================================================
function Write-AuditEntry {
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$Action,
        [string]$Target = '',
        $Details,
        [string]$StorageToken
    )
    try {
        $tok = if ($StorageToken) { $StorageToken } else { Get-ManagedIdentityToken -Resource 'https://storage.azure.com/' }
        $now = [datetime]::UtcNow
        Set-TableEntity -Table 'AuditLog' -Token $tok -Entity @{
            PartitionKey = $now.ToString('yyyy-MM')
            RowKey       = ($now.ToString('o') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Actor        = if ($Caller.Upn) { [string]$Caller.Upn } else { 'anonymous' }
            Action       = $Action
            Target       = $Target
            Details      = if ($null -ne $Details) { ($Details | ConvertTo-Json -Compress -Depth 5) } else { '' }
            At           = $now.ToString('o')
        }
    } catch { Write-Host "audit write failed for ${Action}: $($_.Exception.Message)" }
}

# ============================================================================
# Get-ManagedIdentityToken — acquire an access token for an Azure resource via the
# Function App's system-assigned managed identity (no secrets). Used by every
# function that reads cost data, queries Log Analytics / Resource Graph, or reads
# table storage.
#
# Common resource URIs:
#   https://management.azure.com/        — Cost Management, Resource Graph, Advisor
#   https://storage.azure.com/           — table + blob storage
#   https://api.loganalytics.io/         — Log Analytics query API
#   https://vault.azure.net/             — Key Vault (AI provider key)
# ============================================================================
function Get-ManagedIdentityToken {
    param([Parameter(Mandatory)][string]$Resource)

    return (Invoke-RestMethod -Method GET `
        -Uri "$($env:IDENTITY_ENDPOINT)?resource=$Resource&api-version=2019-08-01" `
        -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER } -TimeoutSec 15).access_token
}

# ============================================================================
# Table storage helpers — thin REST wrappers over the Azure Table service, authed
# with the managed identity (no connection string). Used by the timers and read
# endpoints. $Token is a storage.azure.com token from Get-ManagedIdentityToken.
# ============================================================================
function Get-StorageHeaders {
    param([Parameter(Mandatory)][string]$Token)
    return @{
        Authorization  = "Bearer $Token"
        Accept         = "application/json;odata=nometadata"
        "x-ms-version" = "2020-12-06"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
    }
}

function Get-TableBaseUri {
    $u = $env:AzureWebJobsStorage__tableServiceUri
    # Name the setting. Without this the first .EndsWith() on $null fails every endpoint and
    # every timer with "You cannot call a method on a null-valued expression" — which points at
    # this line instead of at the missing app setting, and looks like a code fault rather than a
    # deployment one. Same class of misdirection that cost a day on the deploy issue.
    if ([string]::IsNullOrWhiteSpace($u)) {
        throw ("App setting 'AzureWebJobsStorage__tableServiceUri' is not set, so there is no table " +
               "endpoint to talk to. It is written by the bicep deployment; if this app was deployed " +
               "by hand, set it to https://<storage-account>.table.core.windows.net/")
    }
    if (-not $u.EndsWith("/")) { $u += "/" }
    return $u
}

# Escape a value for use as an OData string literal inside a $filter.
#
# The Table service takes filters as TEXT, so a value carrying a single quote doesn't just break
# the query — it can extend it. A RowKey of  x' or RowKey ne 'y  turns
#     RowKey eq '<id>'
# into
#     RowKey eq 'x' or RowKey ne 'y'
# which is "return everything". OData escapes a quote by doubling it, the same rule the batch
# helpers below already apply to keys going into a URL.
#
# This is defence in depth, NOT the primary gate. Anything interpolated into a filter should
# first be validated for shape and rejected if it doesn't match (see ExplainSpike,
# GetSubscriptionBreakdown) — that fails at the boundary with a 400
# instead of quietly matching nothing, and it survives someone later editing the filter string.
function ConvertTo-ODataLiteral {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    return ([string]$Value).Replace("'", "''")
}

# Query a table, following continuation tokens. Returns an array of entities.
#
# -Top caps how many rows come back AND stops the continuation walk once that many are in hand.
# Both halves matter: the Table service treats $top as a per-page hint, so without the local
# break this would still march through every page. Use it whenever the caller only needs "some"
# rows — the retention prune wants 20,000 to delete and does not care that a million match.
function Get-TableEntities {
    param(
        [Parameter(Mandatory)][string]$Table,
        [string]$Filter,
        [string]$Select,
        [int]$Top = 0,
        [Parameter(Mandatory)][string]$Token
    )
    $base = Get-TableBaseUri
    $headers = Get-StorageHeaders -Token $Token
    $qparts = @()
    if ($Filter) { $qparts += '$filter=' + [uri]::EscapeDataString($Filter) }
    if ($Select) { $qparts += '$select=' + [uri]::EscapeDataString($Select) }
    # The Table service accepts at most 1000 per page and answers a larger $top with 400 Bad
    # Request — which is what failed the nightly retention prune (it asked for 20000). Larger
    # caps are honoured by paging below.
    if ($Top -gt 0) { $qparts += '$top=' + [Math]::Min([int]$Top, 1000) }
    $baseQs = if ($qparts.Count) { '?' + ($qparts -join '&') } else { '' }

    $results = @()
    $uri = "$base$Table()$baseQs"
    do {
        $resp = Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -TimeoutSec 60
        $data = ($resp.Content | ConvertFrom-Json).value
        if ($data) { $results += $data }
        # Enough in hand — stop following continuations rather than paging to the end.
        if ($Top -gt 0 -and @($results).Count -ge $Top) { break }

        $npk = $resp.Headers['x-ms-continuation-NextPartitionKey']; if ($npk -is [array]) { $npk = $npk[0] }
        $nrk = $resp.Headers['x-ms-continuation-NextRowKey'];       if ($nrk -is [array]) { $nrk = $nrk[0] }
        if ($npk) {
            $cont = "NextPartitionKey=$([uri]::EscapeDataString($npk))"
            if ($nrk) { $cont += "&NextRowKey=$([uri]::EscapeDataString($nrk))" }
            $sep = if ($baseQs) { '&' } else { '?' }
            $uri = "$base$Table()$baseQs$sep$cont"
        } else { $uri = $null }
    } while ($uri)

    # A page can overshoot -Top (the service returns whole pages), so trim.
    if ($Top -gt 0 -and @($results).Count -gt $Top) { $results = @($results | Select-Object -First $Top) }

    # Return unrolled — every caller wraps in @(...), so a leading-comma array wrap here would
    # NEST the result (a 1-element array containing the entity array), causing member-enumeration
    # bugs like `$_.CostUsd` returning Object[]. Do NOT re-add the comma.
    return $results
}

# Insert-or-merge a single entity. $Entity must contain PartitionKey and RowKey.
function Set-TableEntity {
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][hashtable]$Entity,
        [Parameter(Mandatory)][string]$Token
    )
    $base = Get-TableBaseUri
    $pk = [uri]::EscapeDataString([string]$Entity.PartitionKey)
    $rk = [uri]::EscapeDataString([string]$Entity.RowKey)
    $headers = Get-StorageHeaders -Token $Token
    $headers['Content-Type'] = 'application/json'
    Invoke-RestMethod -Method Merge -Uri "$base$Table(PartitionKey='$pk',RowKey='$rk')" `
        -Headers $headers -Body ($Entity | ConvertTo-Json -Depth 10) -TimeoutSec 30 | Out-Null
}

# Insert-or-merge MANY entities via Entity Group Transactions: up to 100 per request,
# grouped by PartitionKey (a Table service requirement). The daily ingest writes ~16k
# rows; one-by-one MERGEs meant 10-15 minutes of silent sequential REST calls (looks like
# a hang), batching cuts it to seconds. Any chunk whose batch request fails falls back to
# per-entity writes — a batch problem degrades to slow-but-correct, never data loss.
function Set-TableEntityBatch {
    param(
        [Parameter(Mandatory)][string]$Table,
        [array]$Entities,
        [Parameter(Mandatory)][string]$Token
    )
    $all = @($Entities)
    if (-not $all.Count) { return }
    $base = Get-TableBaseUri

    foreach ($group in ($all | Group-Object -Property { [string]$_.PartitionKey })) {
        $items = @($group.Group)
        for ($i = 0; $i -lt $items.Count; $i += 100) {
            $chunk = @($items[$i..([Math]::Min($i + 99, $items.Count - 1))])
            $batchBoundary = 'batch_' + [guid]::NewGuid().ToString()
            $csBoundary    = 'changeset_' + [guid]::NewGuid().ToString()

            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append("--$batchBoundary`r`nContent-Type: multipart/mixed; boundary=$csBoundary`r`n`r`n")
            foreach ($e in $chunk) {
                $pk = [uri]::EscapeDataString(([string]$e.PartitionKey).Replace("'", "''"))
                $rk = [uri]::EscapeDataString(([string]$e.RowKey).Replace("'", "''"))
                $json = $e | ConvertTo-Json -Depth 10 -Compress
                [void]$sb.Append("--$csBoundary`r`nContent-Type: application/http`r`nContent-Transfer-Encoding: binary`r`n`r`n")
                [void]$sb.Append("MERGE $base$Table(PartitionKey='$pk',RowKey='$rk') HTTP/1.1`r`n")
                [void]$sb.Append("Content-Type: application/json`r`nAccept: application/json;odata=nometadata`r`n`r`n$json`r`n")
            }
            [void]$sb.Append("--$csBoundary--`r`n--$batchBoundary--`r`n")

            $headers = Get-StorageHeaders -Token $Token
            $headers['Content-Type'] = "multipart/mixed; boundary=$batchBoundary"
            $headers['DataServiceVersion'] = '3.0;NetFx'
            $headers['MaxDataServiceVersion'] = '3.0;NetFx'

            $ok = $false
            try {
                $resp = Invoke-WebRequest -Method POST -Uri "$base`$batch" -Headers $headers `
                    -Body $sb.ToString() -TimeoutSec 60
                # The outer request is 202 even when an inner operation failed — inspect the body.
                $ok = ($resp.Content -notmatch 'HTTP/1\.1 [45]\d\d')
                if (-not $ok) { Write-Host "  table batch had failing operation(s) — retrying $($chunk.Count) entities one-by-one" }
            } catch {
                Write-Host "  table batch request failed ($($_.Exception.Message)) — retrying $($chunk.Count) entities one-by-one"
            }
            if (-not $ok) {
                foreach ($e in $chunk) { Set-TableEntity -Table $Table -Entity $e -Token $Token }
            }
        }
    }
}

# Delete MANY entities via Entity Group Transactions, same shape as Set-TableEntityBatch:
# up to 100 per request, grouped by PartitionKey. Used by the CostSnapshots retention prune,
# where a day's worth of rows can be tens of thousands — one DELETE per row would take longer
# than the whole ingest.
#
# If-Match '*' = delete regardless of ETag; we are pruning by age, not doing optimistic
# concurrency. A chunk whose batch fails is retried one-by-one, and individual failures are
# swallowed: a row that survives pruning is harmless (it gets picked up next run), whereas
# throwing here would abort the ingest.
function Remove-TableEntityBatch {
    param(
        [Parameter(Mandatory)][string]$Table,
        [array]$Entities,          # objects with PartitionKey + RowKey
        [Parameter(Mandatory)][string]$Token
    )
    $all = @($Entities)
    if (-not $all.Count) { return 0 }
    $base = Get-TableBaseUri
    $deleted = 0

    foreach ($group in ($all | Group-Object -Property { [string]$_.PartitionKey })) {
        $items = @($group.Group)
        for ($i = 0; $i -lt $items.Count; $i += 100) {
            $chunk = @($items[$i..([Math]::Min($i + 99, $items.Count - 1))])
            $batchBoundary = 'batch_' + [guid]::NewGuid().ToString()
            $csBoundary    = 'changeset_' + [guid]::NewGuid().ToString()

            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append("--$batchBoundary`r`nContent-Type: multipart/mixed; boundary=$csBoundary`r`n`r`n")
            foreach ($e in $chunk) {
                $pk = [uri]::EscapeDataString(([string]$e.PartitionKey).Replace("'", "''"))
                $rk = [uri]::EscapeDataString(([string]$e.RowKey).Replace("'", "''"))
                [void]$sb.Append("--$csBoundary`r`nContent-Type: application/http`r`nContent-Transfer-Encoding: binary`r`n`r`n")
                [void]$sb.Append("DELETE $base$Table(PartitionKey='$pk',RowKey='$rk') HTTP/1.1`r`n")
                [void]$sb.Append("If-Match: *`r`nAccept: application/json;odata=nometadata`r`n`r`n")
            }
            [void]$sb.Append("--$csBoundary--`r`n--$batchBoundary--`r`n")

            $headers = Get-StorageHeaders -Token $Token
            $headers['Content-Type'] = "multipart/mixed; boundary=$batchBoundary"
            $headers['DataServiceVersion'] = '3.0;NetFx'
            $headers['MaxDataServiceVersion'] = '3.0;NetFx'

            try {
                $resp = Invoke-WebRequest -Method POST -Uri "$base`$batch" -Headers $headers `
                    -Body $sb.ToString() -TimeoutSec 60
                if ($resp.Content -notmatch 'HTTP/1\.1 [45]\d\d') {
                    $deleted += $chunk.Count
                } else {
                    Write-Host "  delete batch had failing operation(s) — retrying $($chunk.Count) row(s) one-by-one"
                    foreach ($e in $chunk) {
                        try { Remove-TableEntity -Table $Table -PartitionKey $e.PartitionKey -RowKey $e.RowKey -Token $Token; $deleted++ } catch {}
                    }
                }
            } catch {
                Write-Host "  delete batch request failed ($($_.Exception.Message)) — retrying $($chunk.Count) row(s) one-by-one"
                foreach ($e in $chunk) {
                    try { Remove-TableEntity -Table $Table -PartitionKey $e.PartitionKey -RowKey $e.RowKey -Token $Token; $deleted++ } catch {}
                }
            }
        }
    }
    return $deleted
}

# Delete one entity. Throws on failure (callers decide whether that matters).
function Remove-TableEntity {
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][string]$Token
    )
    $base = Get-TableBaseUri
    $pk = [uri]::EscapeDataString($PartitionKey)
    $rk = [uri]::EscapeDataString($RowKey)
    $headers = Get-StorageHeaders -Token $Token
    $headers['If-Match'] = '*'
    Invoke-RestMethod -Method DELETE -Uri "$base$Table(PartitionKey='$pk',RowKey='$rk')" `
        -Headers $headers -TimeoutSec 30 | Out-Null
}

# ============================================================================
# Wait-ForIngestCompletion — bounded wait for today's the cost ingest (CostIngest.psm1) run.
#
# The timers are scheduled on fixed wall-clock offsets in UTC (02:00 ingest, 02:35 savings, 02:40
# detect) with no dependency between them. On a large tenant the ingest can still be running
# when they start, and the analysis timers would then read a half-populated CostSnapshots table and
# publish it as the whole tenant — spikes missing, totals understated, no signal to the user.
#
# This blocks until the cost ingest (CostIngest.psm1) writes its 'ingest/lastrun' marker for TODAY, or the
# wait budget runs out. It never blocks forever, and it never fails the run: on timeout the
# caller proceeds with whatever data exists and reports the result as incomplete.
# -MaxWaitMinutes 0 reads the marker once and returns straight away. A sleeping invocation
# still holds one of the worker's three slots (PSWorkerInProcConcurrencyUpperBound), which the
# portal API and the platform health check need.
#
# Returns @{ Complete; Reported (today's marker exists); Marker; WaitedSeconds; Reason }.
# ============================================================================
function Wait-ForIngestCompletion {
    param(
        [Parameter(Mandatory)][string]$Token,
        [double]$MaxWaitMinutes = 20,
        [int]$PollSeconds = 60
    )
    $started = [datetime]::UtcNow
    $today   = [datetime]::UtcNow.Date
    $deadline = $started.AddMinutes($MaxWaitMinutes)
    $announced = $false

    while ($true) {
        $marker = $null
        try {
            $marker = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'ingest' and RowKey eq 'lastrun'" -Token $Token) | Select-Object -First 1
        } catch { Write-Host "ingest marker read failed: $($_.Exception.Message)" }

        $waited = [int]([datetime]::UtcNow - $started).TotalSeconds

        if ($marker -and $marker.At) {
            $at = [datetime]::MinValue
            if ([datetime]::TryParse([string]$marker.At, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) {
                if ($at.Date -ge $today) {
                    # Today's ingest has reported in — complete or not, there is nothing more to wait for.
                    $complete = [bool]$marker.Complete
                    $reason = if ($complete) { 'ingest completed' } else { "ingest reported incomplete ($($marker.SubscriptionsOk)/$($marker.SubscriptionsTotal) subscriptions, totals complete: $($marker.TotalsComplete))" }
                    if ($waited -gt 0) { Write-Host "Waited ${waited}s for the ingest marker." }
                    return [PSCustomObject]@{ Complete = $complete; Reported = $true; Marker = $marker; WaitedSeconds = $waited; Reason = $reason }
                }
            }
        }

        if ([datetime]::UtcNow -ge $deadline) {
            # MaxWaitMinutes 0 = a single non-blocking check, not a timeout.
            $prefix = if ($MaxWaitMinutes -le 0) { "today's ingest has not reported yet (not waiting)" } else { "timed out after ${waited}s" }
            $reason = if ($marker) { "$prefix — the newest ingest marker is from a previous day" }
                      else { "$prefix — no ingest marker has ever been written" }
            Write-Host "WARNING: $reason. Proceeding with whatever data is present; results will be reported as incomplete."
            return [PSCustomObject]@{ Complete = $false; Reported = $false; Marker = $marker; WaitedSeconds = $waited; Reason = $reason }
        }

        if (-not $announced) {
            Write-Host "Today's cost ingest hasn't reported yet — waiting up to $MaxWaitMinutes minute(s) for it before analyzing."
            $announced = $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# ============================================================================
# Add-QueueMessage — put one JSON message on a Storage queue, authed with the managed identity
# (Storage Queue Data Contributor). Used by the cost ingest (PlanCostIngest-Timer and
# ProcessCostTask-Queue). -DelaySeconds keeps the message invisible that long: a throttled task
# is put back to come round again later, instead of sleeping in the worker.
# The queue trigger reads plain text (host.json: queues.messageEncoding = none).
# ============================================================================
function Add-QueueMessage {
    param(
        [Parameter(Mandatory)][string]$Queue,
        [Parameter(Mandatory)][hashtable]$Message,
        [int]$DelaySeconds = 0,
        [Parameter(Mandatory)][string]$Token
    )
    $u = $env:AzureWebJobsStorage__queueServiceUri
    if ([string]::IsNullOrWhiteSpace($u)) {
        throw "App setting 'AzureWebJobsStorage__queueServiceUri' is not set, so there is no queue endpoint. It is written by the bicep deployment."
    }
    if (-not $u.EndsWith('/')) { $u += '/' }
    $text = [System.Security.SecurityElement]::Escape(($Message | ConvertTo-Json -Depth 10 -Compress))
    $delay = [Math]::Min([Math]::Max($DelaySeconds, 0), 604800)
    $headers = @{ Authorization = "Bearer $Token"; 'x-ms-version' = '2020-12-06'; 'x-ms-date' = (Get-Date).ToUniversalTime().ToString('R') }
    Invoke-RestMethod -Method POST -Uri "$u$Queue/messages?visibilitytimeout=$delay" -Headers $headers `
        -ContentType 'application/xml' -Body "<QueueMessage><MessageText>$text</MessageText></QueueMessage>" -TimeoutSec 30 | Out-Null
}

# Short deterministic hash (16 hex chars) — used for table RowKeys derived from values
# that can't be a RowKey directly (e.g. a ResourceId contains '/').
function Get-ShortHash {
    param([Parameter(Mandatory)][string]$Value)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Value))
    return (-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') }))
}

# ============================================================================
# Subscription discovery — the app is tenant-wide: it enumerates every subscription its
# managed identity can see (granted via Cost Management Reader + Reader at a management
# group, which cascades to all child subscriptions) and ingests/analyzes them all.
# Returns array of { Id, Name }. Only Enabled subscriptions.
# ============================================================================
#
# -StorageToken applies the operator's SUBSCRIPTION SCOPE (Get-SubscriptionScope): only the
# included subscriptions come back. Every timer passes it; the unscoped form is for callers that
# need everything the identity can see (the cost ingest's 'discovered' list).
function Get-AccessibleSubscriptions {
    param([Parameter(Mandatory)][string]$MgmtToken, [string]$StorageToken)
    $subs = @()
    $uri = 'https://management.azure.com/subscriptions?api-version=2022-12-01'
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $MgmtToken" }
        foreach ($s in @($resp.value)) {
            if ([string]$s.state -eq 'Enabled') {
                $subs += [PSCustomObject]@{ Id = [string]$s.subscriptionId; Name = [string]$s.displayName }
            }
        }
        $uri = $resp.nextLink
    } while ($uri)
    if ($StorageToken) {
        $scope = Get-SubscriptionScope -Token $StorageToken
        if ($scope.Ids) {
            $before = $subs.Count
            $subs = @($subs | Where-Object { $scope.Ids.Contains(([string]$_.Id).ToLowerInvariant()) })
            Write-Host "Subscription scope: $($subs.Count) of $before accessible subscription(s) included."
        }
    }
    return @($subs)
}

# ============================================================================
# SUBSCRIPTION SCOPE — which subscriptions the whole portal covers.
#
# Set by the operator with Setup/Set-SubscriptionScope.ps1 (there is deliberately no portal UI
# for it) in PortalConfig 'settings/scope':
#   IncludedSubscriptionIds  subscription GUIDs, comma-separated (a JSON array is accepted
#                            too); empty or missing = ALL
#   ScopeHash                Get-SubscriptionScopeHash of that list ('all' when empty)
#
# Two mechanisms, and both matter:
#   - READ-TIME FILTER. Every endpoint drops rows of excluded subscriptions as it reads, so a
#     removed subscription disappears from findings, savings, Advisor, the Subscriptions page
#     and budgets immediately. Nothing is deleted: re-adding it brings the rows back.
#   - NIGHTLY REBUILD. Tenant-wide aggregates (the daily totals, month view, forecast, brief)
#     are sums that can't be filtered after the fact. Each records the ScopeHash it was built
#     with; a mismatch makes the next run rebuild it, and until then the endpoints report
#     scopePending so the portal can say so.
# ============================================================================
function Get-SubscriptionScopeHash {
    param([string[]]$Ids)
    $clean = @($Ids | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    if (-not $clean.Count) { return 'all' }
    return (Get-ShortHash -Value ($clean -join ','))
}

# Returns { Ids = HashSet[string] of lower-case GUIDs, or $null for ALL; Hash; Count }.
# A missing, empty or unreadable row means ALL — a storage hiccup must never shrink the portal.
function Get-SubscriptionScope {
    param([Parameter(Mandatory)][string]$Token)
    $row = $null
    try {
        $row = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'settings' and RowKey eq 'scope'" -Token $Token) | Select-Object -First 1
    } catch { Write-Host "subscription scope read failed (treating as all): $($_.Exception.Message)" }
    $ids = @()
    if ($row -and $row.IncludedSubscriptionIds) {
        $raw = ([string]$row.IncludedSubscriptionIds).Trim()
        $parts = @()
        if ($raw.StartsWith('[')) {
            try { $parts = @($raw | ConvertFrom-Json) }
            catch { Write-Host "subscription scope is not valid JSON (treating as all)." }
        } else { $parts = @($raw -split '[,;\s]+') }
        $ids = @($parts | Where-Object { [string]$_ -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' })
    }
    if (-not $ids.Count) { return [PSCustomObject]@{ Ids = $null; Hash = 'all'; Count = 0 } }
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($i in $ids) { [void]$set.Add(([string]$i).ToLowerInvariant()) }
    return [PSCustomObject]@{ Ids = $set; Hash = (Get-SubscriptionScopeHash -Ids @($set)); Count = $set.Count }
}

# The subscription a stored row belongs to: SubscriptionId, else a GUID-shaped Scope, else the
# /subscriptions/<guid>/ segment of ResourceId (or of a plain string). $null when there is none
# — a tenant-level row, which the scope never hides.
function Get-RowSubscriptionId {
    param($Row)
    if ($null -eq $Row) { return $null }
    if ($Row -is [string]) { $cands = @($Row) }
    else { $cands = @($Row.SubscriptionId, $Row.Scope, $Row.ResourceId) }
    foreach ($c in $cands) {
        $s = [string]$c
        if ($s -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $s.ToLowerInvariant() }
        if ($s -match '(?i)^/subscriptions/([0-9a-f-]{36})(/|$)') { return $Matches[1].ToLowerInvariant() }
    }
    return $null
}

# True when a row (or a subscription id / resource id string) is inside the scope. ALL scope,
# and rows that name no subscription, are always in.
function Test-InSubscriptionScope {
    param($Scope, $Value)
    if (-not $Scope -or -not $Scope.Ids) { return $true }
    $id = Get-RowSubscriptionId -Row $Value
    if (-not $id) { return $true }
    return $Scope.Ids.Contains($id)
}

# True when a tenant-wide aggregate was built for a different scope than the current one, i.e.
# the nightly rebuild hasn't caught up yet. -Stored is the aggregate's ScopeHash; rows written
# before scopes existed have none and were built for ALL.
function Test-ScopeHashPending {
    param($Scope, [AllowNull()][AllowEmptyString()][string]$Stored)
    $s = if ($Stored) { $Stored } else { 'all' }
    $current = if ($Scope) { [string]$Scope.Hash } else { 'all' }
    return ($s -ne $current)
}

# The scope the 90-day daily-total history was last built for (the cost ingest (CostIngest.psm1) records it
# on the 'dailytotal90' backfill marker). $null when it can't be read.
function Get-DailyTotalScopeHash {
    param([Parameter(Mandatory)][string]$Token)
    try {
        $m = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'backfill' and RowKey eq 'dailytotal90'" -Token $Token) | Select-Object -First 1
        if ($m) { return [string]$m.ScopeHash }
    } catch { Write-Host "daily-total marker read failed: $($_.Exception.Message)" }
    return $null
}

# The ids of the subscriptions the portal covers, for filters on management-group queries:
# the ingest's 'discovered' list narrowed by the scope (or the scope itself when nothing has
# been discovered yet). Lower-case. Empty = unknown.
function Get-IncludedSubscriptionIds {
    param([Parameter(Mandatory)][string]$Token, $Scope)
    if (-not $Scope) { $Scope = Get-SubscriptionScope -Token $Token }
    $ids = @()
    try {
        $disc = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'subscriptions' and RowKey eq 'discovered'" -Token $Token) | Select-Object -First 1
        if ($disc -and $disc.SubscriptionsJson) { $ids = @(@([string]$disc.SubscriptionsJson | ConvertFrom-Json) | ForEach-Object { ([string]$_.id).ToLowerInvariant() }) }
    } catch { Write-Host "discovered-subscriptions read failed: $($_.Exception.Message)" }
    if ($Scope.Ids) {
        if ($ids.Count) { return @($ids | Where-Object { $Scope.Ids.Contains($_) }) }
        return @($Scope.Ids)
    }
    return $ids
}

# A stored row's AllocationJson (owner, cost centre, environment, application, resource group)
# as an object for the API, or $null when the row has none.
function ConvertFrom-AllocationJson {
    param($Row)
    $j = [string]$Row.AllocationJson
    if (-not $j) { return $null }
    try { return ($j | ConvertFrom-Json) } catch { return $null }
}

# Where a live, portal-wide cost query should be asked, and how to keep it to the portal's own
# subscriptions: the tenant cost scope (Get-ResolvedCostScope) with a SubscriptionId filter
# whenever that group may hold others, else the deployment subscription — flagged, so the
# caller can say the answer covers only that. Returns { Scope; SubscriptionIds; DeploymentOnly;
# Label } or $null when there is no scope at all.
function Resolve-PortalQueryScope {
    param([Parameter(Mandatory)][string]$StorageToken, $SubScope)
    if (-not $SubScope) { $SubScope = Get-SubscriptionScope -Token $StorageToken }
    $r = Get-ResolvedCostScope -StorageToken $StorageToken
    if ($r.Scope) {
        $isSub = ([string]$r.Scope -like '/subscriptions/*')
        $ids = if (-not $isSub -and ($SubScope.Ids -or $r.Extra -ne 0)) { @(Get-IncludedSubscriptionIds -Token $StorageToken -Scope $SubScope) } else { @() }
        return [PSCustomObject]@{ Scope = [string]$r.Scope; SubscriptionIds = $ids; DeploymentOnly = $false
            Label = if ($isSub) { 'the configured subscription' } elseif ($SubScope.Ids) { "the $($ids.Count) subscription(s) in the portal's scope" } else { 'all subscriptions' } }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID)) {
        return [PSCustomObject]@{ Scope = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)"; SubscriptionIds = @(); DeploymentOnly = $true
            Label = $(if ($r.Source -eq 'insufficient') { "only the deployment subscription (the management group $($r.Name) shows only $([Math]::Round([double]$r.CoveragePct, 0))% of the spend in its cost data; set costQueryScope)" } else { 'only the deployment subscription (no readable management group contains all subscriptions; set costQueryScope)' }) }
    }
    return $null
}

# The subscriptions a live question may be asked of, one by one: the ingest's 'discovered' list
# (what the portal's identity can read) narrowed by the scope. [{ Id (lower-case); Name }].
function Get-QuerySubscriptions {
    param([Parameter(Mandatory)][string]$Token, $Scope)
    if (-not $Scope) { $Scope = Get-SubscriptionScope -Token $Token }
    $subs = @()
    try {
        $disc = @(Get-TableEntities -Table 'PortalConfig' -Filter "PartitionKey eq 'subscriptions' and RowKey eq 'discovered'" -Token $Token) | Select-Object -First 1
        if ($disc -and $disc.SubscriptionsJson) {
            $subs = @(@([string]$disc.SubscriptionsJson | ConvertFrom-Json) | ForEach-Object { [PSCustomObject]@{ Id = ([string]$_.id).ToLowerInvariant(); Name = [string]$_.name } })
        }
    } catch { Write-Host "discovered-subscriptions read failed: $($_.Exception.Message)" }
    if ($Scope.Ids) { $subs = @($subs | Where-Object { $Scope.Ids.Contains($_.Id) }) }
    return @($subs)
}

# Filter a list of rows to the scope (pass-through when the scope is ALL).
function Select-InSubscriptionScope {
    param($Scope, $Rows)
    if (-not $Scope -or -not $Scope.Ids) { return @($Rows) }
    return @(@($Rows) | Where-Object { Test-InSubscriptionScope -Scope $Scope -Value $_ })
}
