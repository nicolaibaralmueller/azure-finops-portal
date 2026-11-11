using namespace System.Net
param($Request, $TriggerMetadata)

# On-demand evidence + explanation for ONE stored cost-change finding. Admin-only: it runs Cost
# Management queries (the tightest rate limit in the app) and, when AI is configured, spends a
# call on the customer's key.
#
#   1. Evidence (CostEvidence.psm1): reused from the stored finding when it is complete, unless
#      the body asks for { refreshEvidence: true }; otherwise gathered now, within a budget that
#      leaves room inside the platform's 230-second HTTP limit. Stored either way — evidence is
#      useful on its own, so this works without an AI provider too.
#   2. Explanation: the model explains the change FROM that evidence and cites it. Always a
#      fresh call (the admin asked for one). Over the daily AI limit -> 429.
#
# Body: { spikeId, periodType, period, refreshEvidence? }

$caller = Get-Caller -Request $Request
if (-not $caller.IsAdmin) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller -Error 'admin required'); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$started = [datetime]::UtcNow
$spikeId    = [string]$Request.Body.spikeId
# Optional but strongly preferred: with both, the lookup is a single-partition point read
# instead of a cross-partition scan.
$periodType = if ([string]$Request.Body.periodType -eq 'week') { 'week' } elseif ([string]$Request.Body.periodType -eq 'month') { 'month' } else { $null }
$period     = [string]$Request.Body.period
$refreshEvidence = [bool]$Request.Body.refreshEvidence

# These are the only request values that reach an OData $filter, so they are validated here
# rather than escaped away. A filter is text: a value containing a quote can extend the query
# instead of breaking it, turning a point read into "return every row".
#
# spikeId is a Get-SpikeId hash — 16 hex characters, always — so it can be pinned exactly.
$spikeIdOk = $spikeId -match '^[0-9a-fA-F]{16}$'
# period is checked by CHARACTER SET rather than by date shape: it is 'yyyy-MM' for a month and
# 'yyyy-MM-dd' for the trailing week, and that format has already changed once.
$periodOk = (-not $period) -or ($period -match '^[0-9A-Za-z-]{1,20}$')
if (-not $spikeIdOk -or -not $periodOk) {
    $why = if (-not $spikeIdOk) { 'a valid spikeId is required' } else { 'period is not a valid period key' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::BadRequest; Body = (@{ error = $why } | ConvertTo-Json -Compress); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$storageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

# --- load the stored finding (point read when the period is known, else scan by RowKey) ---
# Escaped as well as validated: the validation above is what should stop bad input, but the
# filter stays correct-by-construction if that check is ever loosened.
$idLiteral = ConvertTo-ODataLiteral -Value $spikeId
$filter = if ($periodType -and $period) {
    "PartitionKey eq '$(ConvertTo-ODataLiteral -Value "$periodType|$period")' and RowKey eq '$idLiteral'"
} else { "RowKey eq '$idLiteral'" }
$row = @(Get-TableEntities -Table 'CostSpikes' -Filter $filter -Token $storageToken) | Select-Object -First 1
# A finding of a subscription outside the operator's scope is treated as not there.
if ($row -and -not (Test-InSubscriptionScope -Scope (Get-SubscriptionScope -Token $storageToken) -Value $row)) { $row = $null }
if (-not $row) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::NotFound; Body = '{"error":"finding not found"}'; Headers = @{ "Content-Type" = "application/json" } })
    return
}

Write-AuditEntry -Caller $caller -Action 'ExplainSpike' -Target "$($row.PartitionKey)/$($row.RowKey)" -StorageToken $storageToken `
    -Details @{ refreshEvidence = $refreshEvidence }

# --- reconstruct the deterministic finding (numbers come from storage, not the model) ---
$rowPeriodType = [string]$row.PeriodType
$finding = [PSCustomObject]@{
    Id          = [string]$row.RowKey
    Date        = [string]$row.Period
    PeriodType  = $rowPeriodType
    Dimension   = if ($row.Dimension) { [string]$row.Dimension } else { 'resource' }
    Scope       = $row.Scope
    ScopeName   = [string]$row.ScopeName
    Meter       = $row.Meter
    ResourceId  = $row.ResourceId
    ResourceName = [string]$row.ResourceName
    UnexplainedUsd = if ($null -ne $row.UnexplainedUsd -and [double]$row.UnexplainedUsd -ge 0) { [double]$row.UnexplainedUsd } else { $null }
    BaselineUsd = [double]$row.BaselineUsd
    SpikeUsd    = [double]$row.SpikeUsd
    DeltaUsd    = [double]$row.DeltaUsd
    DeltaPct    = if ($row.IsNew -or [double]$row.DeltaPct -lt 0) { $null } else { [double]$row.DeltaPct }
    IsNew       = [bool]$row.IsNew
    # Within-period shape measured by the nightly run (-1 = not measured).
    ExitRunRateUsd = if ($null -ne $row.ExitRunRateUsd -and [double]$row.ExitRunRateUsd -ge 0) { [double]$row.ExitRunRateUsd } else { $null }
    SteppedDownOn  = [string]$row.SteppedDownOn
    Resolved       = [bool]$row.Resolved
    DailyBeforeUsd = $null
    DailyAfterUsd  = $null
    # Where it stands now (DetectCostSpikes-Timer, Get-FindingState).
    State           = [string]$row.State
    CurrentDailyUsd = if ($null -ne $row.CurrentDailyUsd -and [string]$row.CurrentDailyUsd -ne '') { [double]$row.CurrentDailyUsd } else { $null }
    CurrentAsOf     = [string]$row.CurrentAsOf
}
# The before/after daily levels are only kept in the stored daily-shape fact.
if ($row.EvidenceJson) {
    try {
        $shape = @(([string]$row.EvidenceJson | ConvertFrom-Json).facts | Where-Object { [string]$_.kind -eq 'daily-shape' }) | Select-Object -First 1
        if ($shape) { $finding.DailyBeforeUsd = $shape.dailyBeforeUsd; $finding.DailyAfterUsd = $shape.dailyAfterUsd }
    } catch {}
}

$mgmtToken = $null
try { $mgmtToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/' } catch { Write-Host "mgmt token failed: $($_.Exception.Message)" }
$ctx = if ($mgmtToken -and $finding.ResourceId) { Get-ResourceContext -ResourceId $finding.ResourceId -MgmtToken $mgmtToken } else { $null }

# --- 1. evidence ---
$evidence = $null
$evidenceStatus = [string]$row.EvidenceStatus
if (-not $refreshEvidence -and $row.EvidenceJson -and $evidenceStatus -eq 'complete') {
    try { $evidence = [string]$row.EvidenceJson | ConvertFrom-Json } catch { $evidence = $null }
    # Evidence from an older version lacks what the current one collects (e.g. the meter
    # breakdown of a meter finding): gather it again.
    if ($evidence -and [int]$evidence.version -lt (Get-CostEvidenceVersion)) { $evidence = $null }
}
if (-not $evidence -and $mgmtToken) {
    # The windows detection compared against: 4 prior 7-day windows, or 3 prior months.
    $curStart = [datetime]::ParseExact([string]$row.PeriodStart, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $curEnd   = [datetime]::ParseExact([string]$row.PeriodEnd, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $ranges = if ($rowPeriodType -eq 'month') {
        @(1..(Get-PeriodBaselineCount -PeriodType 'month') | ForEach-Object {
            $ms = $curStart.AddMonths(-$_); @{ Start = $ms; End = $ms.AddMonths(1).AddDays(-1) }
        })
    } else {
        @(1..(Get-PeriodBaselineCount -PeriodType 'week') | ForEach-Object {
            $we = $curEnd.AddDays(-7 * $_); @{ Start = $we.AddDays(-6); End = $we }
        })
    }
    $costType = Get-CostTypeSetting -StorageToken $storageToken
    # ~100 s for evidence leaves room for the AI call and the writes inside 230 s.
    $evidence = Get-CostChangeEvidence -Finding $finding -MgmtToken $mgmtToken -CurrentStart $curStart -CurrentEnd $curEnd `
        -BaselineRanges $ranges -Granularity $(if ($rowPeriodType -eq 'month') { 'Monthly' } else { 'Daily' }) `
        -ResourceContext $ctx -CostType $costType -Deadline $started.AddSeconds(100) -Interactive
    $ids = @(Get-EvidenceResourceIds -Evidence $evidence)
    if ($ids.Count) {
        try { Set-EvidenceResourceNames -Evidence $evidence -NameMap (Resolve-ResourceDisplayNames -ResourceIds $ids -MgmtToken $mgmtToken) }
        catch { Write-Host "evidence name lookup failed: $($_.Exception.Message)" }
    }
    Set-EvidenceDailyShape -Evidence $evidence -Finding $finding
    $evidenceStatus = if ($evidence.complete) { 'complete' } else { 'partial' }
    $evidenceJson = $evidence | ConvertTo-Json -Depth 10 -Compress
    while ($evidenceJson.Length -gt 30000 -and @($evidence.facts).Count -gt 1) {
        $evidence.facts = @($evidence.facts | Select-Object -First (@($evidence.facts).Count - 1))
        $evidenceJson = $evidence | ConvertTo-Json -Depth 10 -Compress
    }
    Set-TableEntity -Table 'CostSpikes' -Token $storageToken -Entity @{
        PartitionKey = $row.PartitionKey; RowKey = $row.RowKey
        EvidenceJson = $evidenceJson; EvidenceStatus = $evidenceStatus
        ResourceName = if ($finding.ResourceName) { $finding.ResourceName } elseif ($ctx -and $ctx.name) { [string]$ctx.name } else { '' }
    }
}

# --- 2. explanation ---
$x = Invoke-CostChangeExplanation -Finding $finding -ResourceContext $ctx -Evidence $evidence -Force -Purpose 'cost-change-explanation-on-demand'

if ($x.Status -eq 'explained') {
    Set-TableEntity -Table 'CostSpikes' -Token $storageToken -Entity @{
        PartitionKey   = $row.PartitionKey
        RowKey         = $row.RowKey
        Headline       = [string]$x.Headline
        Cause          = [string]$x.Cause
        Recommendation = [string]$x.Recommendation
        CitedFactsJson = (@($x.CitedFacts) | ConvertTo-Json -Compress -AsArray)
        Explained      = [bool]$x.Explained
        Grounded       = [bool]$x.Grounded
        Confidence     = ''
        NarrativeError = ''
        ExplanationStatus = 'explained'
        # Stamped so tonight's run recognises this explanation as current and reuses it,
        # instead of spending the key to overwrite a refresh the admin just asked for.
        NarrationKey   = [string]$x.NarrationKey
        ExplainedAt    = ([datetime]::UtcNow.ToString('o'))
    }
}

$statusCode = switch ($x.Status) {
    'budget-exceeded' { [HttpStatusCode]::TooManyRequests }
    'failed'          { [HttpStatusCode]::BadGateway }
    default           { [HttpStatusCode]::OK }
}
$message = switch ($x.Status) {
    'budget-exceeded' { ($x.Error -replace '^AI_BUDGET_EXCEEDED:\s*', '') }
    'failed'          { $null }
    'not-configured'  { 'Evidence gathered. No AI provider is configured, so there is no written explanation.' }
    'no-evidence'     { 'No evidence could be gathered for this change, so it was not explained.' }
    default           { $null }
}
if ($x.Status -eq 'failed') {
    # Detail to the logs, a correlation id to the caller.
    $errBody = Write-ErrorBody -Message 'The AI provider call failed. The evidence was still saved.' -Exception $x.Error -TriggerMetadata $TriggerMetadata | ConvertFrom-Json
    $message = [string]$errBody.error
}

$result = [PSCustomObject]@{
    id                = [string]$row.RowKey
    explanationStatus = $x.Status
    message           = $message
    headline          = $x.Headline
    cause             = $x.Cause
    recommendation    = $x.Recommendation
    citedFacts        = @($x.CitedFacts)
    explained         = [bool]$x.Explained
    grounded          = [bool]$x.Grounded
    evidence          = $evidence
    evidenceStatus    = if ($evidence) { $evidenceStatus } else { 'none' }
}
$body = $result | ConvertTo-Json -Depth 12
if ($statusCode -ne [HttpStatusCode]::OK) {
    # Error responses keep the { error } shape the client reads, plus the evidence.
    $body = (@{ error = $message; explanationStatus = $x.Status; evidence = $evidence; evidenceStatus = $result.evidenceStatus } | ConvertTo-Json -Depth 12)
}
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $statusCode
    Body       = $body
    Headers    = @{ "Content-Type" = "application/json" }
})
