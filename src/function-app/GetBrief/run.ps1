using namespace System.Net
param($Request, $TriggerMetadata)

# The stored executive brief (BuildBrief-Timer / RegenerateBrief). Read-only; members allowed.
# Query: ?grain=week|month (default week)
# Returns { grain, available, brief } — brief is { generatedAt, payload, ai, aiStatus, grounded }.

$caller = Get-Caller -Request $Request
if ($caller.Denied) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::Forbidden; Body = (Get-DenyBody -Caller $caller); Headers = @{ "Content-Type" = "application/json" } })
    return
}

$grain = if ($Request.Query -and [string]$Request.Query['grain'] -eq 'month') { 'month' } else { 'week' }
$token = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'

$brief = $null
$scopePending = $false
try {
    $row = @(Get-TableEntities -Table 'CostSummary' -Filter "PartitionKey eq 'brief' and RowKey eq '$grain'" -Token $token) | Select-Object -First 1
    if ($row -and $row.BriefJson) { $brief = [string]$row.BriefJson | ConvertFrom-Json }
    # Briefs built before owners were part of the payload: fill them in from the stored findings
    # (a handful of point reads), so the Overview's action list names an owner straight away.
    if ($brief -and $brief.payload) {
        $ownerKey = @(Get-AllocationTagKeys -StorageToken $token)[0]
        $fill = {
            param($item, [string]$table, [string]$filter)
            if ($item.PSObject.Properties['owner']) { return }
            $o = ''
            try { $r = @(Get-TableEntities -Table $table -Filter $filter -Token $token) | Select-Object -First 1; if ($r) { $o = Get-BriefOwner $r -Key $ownerKey } } catch { }
            $item | Add-Member -NotePropertyName owner -NotePropertyValue $o -Force
        }
        foreach ($c in @($brief.payload.changes.items)) {
            if (-not $c) { continue }
            $pk = "$([string]$brief.payload.changes.periodType)|$([string]$brief.payload.changes.period)"
            & $fill $c 'CostSpikes' "PartitionKey eq '$(ConvertTo-ODataLiteral -Value $pk)' and RowKey eq '$(ConvertTo-ODataLiteral -Value ([string]$c.findingId))'"
        }
        foreach ($sv in @($brief.payload.savings.items)) {
            if (-not $sv) { continue }
            $rk = ([string]$sv.id) -replace '^[SA]-', ''
            if ([string]$sv.source -eq 'advisor') { & $fill $sv 'Recommendations' "PartitionKey eq 'cost' and RowKey eq '$(ConvertTo-ODataLiteral -Value $rk)'" }
            else { & $fill $sv 'SavingsFindings' "PartitionKey eq 'savings' and RowKey eq '$(ConvertTo-ODataLiteral -Value $rk)'" }
        }
    }
    # Built for a different subscription scope: BuildBrief-Timer regenerates it tonight.
    if ($row) { $scopePending = Test-ScopeHashPending -Scope (Get-SubscriptionScope -Token $token) -Stored ([string]$row.ScopeHash) }
} catch { Write-Host "brief read failed: $($_.Exception.Message)" }

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{ grain = $grain; available = ($null -ne $brief); canRegenerate = [bool]$caller.IsAdmin; brief = $brief; scopePending = [bool]$scopePending } | ConvertTo-Json -Depth 16)
    Headers    = @{ "Content-Type" = "application/json" }
})
