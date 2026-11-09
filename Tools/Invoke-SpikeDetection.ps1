#requires -Version 7.0
<#
.SYNOPSIS
    Run the app's timer functions on demand, one after another, instead of waiting for the
    nightly schedule. Useful for a first run after deploy, after changing thresholds, or after
    an RBAC change (e.g. granting Reservations Reader so display names resolve).

.DESCRIPTION
    Triggers each timer through the Functions admin endpoint (POST /admin/functions/<name>) with
    the host master key, fetched via ARM using your current Az session.

    The timers run IN PIPELINE ORDER AND ONE AT A TIME, as the nightly schedule does: each is
    triggered only when the one before it has finished. That matters twice over:
      - later timers read what earlier ones wrote (allocation and its statements read the savings;
        the brief reads nearly everything), so starting them together builds from stale data;
      - the worker runs three invocations at a time on a plan whose memory the portal shares,
        and detection, savings and allocation all stream the per-resource snapshots.

    "Finished" is read from Application Insights: every invocation is logged as a request row
    when it ends (host.json excludes requests from sampling). Telemetry arrives a few minutes
    late, so each step takes a little longer than the function itself. When Application Insights
    can't be found or read, the script falls back to fixed pauses sized like the nightly gaps.

.PARAMETER ResourceGroupName
.PARAMETER FunctionAppName
.PARAMETER Functions
    Which timer functions to run. They always run in pipeline order, whatever order they are
    given in. Default: every analysis timer — DetectCostSpikes, DetectSavings, SyncAdvisor,
    SyncCommitments, SyncMonthlyCosts, SyncAllocation, BuildBrief (they read the snapshots the
    last ingest stored, so no ingest is needed). BuildBrief-Timer only rebuilds a brief that is
    due (missing, weekly on Mondays, monthly once a month) — use the Overview's Regenerate button
    to force one. The cost ingest is not in this list: it runs by itself on the 'cost-tasks'
    queue (PlanCostIngest-Timer, hourly and nightly from 02:00 UTC), and a new deployment loads
    its history on its own and then runs this analysis once.
.PARAMETER TimeoutMinutes
    How long to wait for one function to be reported finished before moving on. Default 40: the
    30-minute function timeout plus telemetry delay.
.PARAMETER WaitSeconds
    An extra pause after each function has finished, before the next one. Default 0.
.PARAMETER NoWait
    Trigger everything at once and return (the old behaviour). Not recommended — see above.

.EXAMPLE
    ./Invoke-SpikeDetection.ps1 -ResourceGroupName FinOpsPortal-tst -FunctionAppName FinOpsPortal-api-tst

.EXAMPLE
    # Only the detectors and the brief.
    ./Invoke-SpikeDetection.ps1 -ResourceGroupName rg -FunctionAppName app `
        -Functions DetectCostSpikes-Timer, DetectSavings-Timer, BuildBrief-Timer

.NOTES
    Requires an active Connect-AzAccount session with rights to list the Function App's host keys
    and app settings (e.g. Contributor on the app) and to read its Application Insights component
    (Reader on the resource group). Exits 1 if any function failed or was not seen to finish.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$FunctionAppName,
    [ValidateSet('DetectCostSpikes-Timer', 'DetectSavings-Timer', 'SyncAdvisor-Timer', 'SyncCommitments-Timer', 'SyncMonthlyCosts-Timer', 'SyncAllocation-Timer', 'BuildBrief-Timer')]
    [string[]]$Functions = @('DetectCostSpikes-Timer', 'DetectSavings-Timer', 'SyncAdvisor-Timer', 'SyncCommitments-Timer', 'SyncMonthlyCosts-Timer', 'SyncAllocation-Timer', 'BuildBrief-Timer'),
    [ValidateRange(1, 180)][int]$TimeoutMinutes = 40,
    [int]$WaitSeconds = 0,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'

# The nightly order (function.json schedules, UTC) and, for the fallback, the gap the schedule
# leaves after each one.
$pipeline = [ordered]@{
    'DetectCostSpikes-Timer' = 15   # 02:40 (nightly it runs after savings; the two are independent)
    'DetectSavings-Timer'    = 10   # 02:35
    'SyncAdvisor-Timer'      = 5    # 02:45
    'SyncCommitments-Timer'  = 5    # 02:50
    'SyncMonthlyCosts-Timer' = 10   # 02:55
    'SyncAllocation-Timer'   = 10   # 03:05
    'BuildBrief-Timer'       = 0    # 03:15
}
$run = @($pipeline.Keys | Where-Object { $Functions -contains $_ })
if (($Functions -join ',') -ne ($run -join ',')) { Write-Host "Running in pipeline order: $($run -join ', ')" -ForegroundColor Yellow }

$ctx = Get-AzContext
if (-not $ctx) { Write-Host "Connecting to Azure..." -ForegroundColor Yellow; Connect-AzAccount | Out-Null; $ctx = Get-AzContext }
$siteId = "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"

Write-Host "Fetching host master key for $FunctionAppName..." -ForegroundColor Cyan
$keys = Invoke-AzRestMethod -Method POST -Path "$siteId/host/default/listkeys?api-version=2022-03-01"
if ($keys.StatusCode -ne 200) { throw "Could not list host keys (HTTP $($keys.StatusCode)): $($keys.Content)" }
$masterKey = ($keys.Content | ConvertFrom-Json).masterKey
if (-not $masterKey) { throw "Host key response contained no masterKey." }

# The Application Insights component the app reports to: the one in the resource group whose
# AppId matches the app's connection string.
$aiId = $null
if (-not $NoWait) {
    try {
        $settings = Invoke-AzRestMethod -Method POST -Path "$siteId/config/appsettings/list?api-version=2022-03-01"
        $conn = if ($settings.StatusCode -eq 200) { [string]($settings.Content | ConvertFrom-Json).properties.APPLICATIONINSIGHTS_CONNECTION_STRING } else { '' }
        $appId = if ($conn -match '(?i)ApplicationId=([0-9a-f-]{36})') { $Matches[1] } else { $null }
        $list = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/components?api-version=2020-02-02"
        $components = if ($list.StatusCode -eq 200) { @(($list.Content | ConvertFrom-Json).value) } else { @() }
        $match = if ($appId) { @($components | Where-Object { $_.properties.AppId -eq $appId }) } else { @() }
        if (-not $match.Count -and $components.Count -eq 1) { $match = $components }
        if ($match.Count) { $aiId = [string]$match[0].id }
    } catch { Write-Verbose "Application Insights lookup failed: $($_.Exception.Message)" }
    if ($aiId) { Write-Host "Watching for completion in Application Insights ($(($aiId -split '/')[-1]))." -ForegroundColor Cyan }
    else { Write-Host "Application Insights not found or not readable — pausing for the nightly gap after each function instead." -ForegroundColor Yellow }
}

# The newest completed invocation of a function since a point in time, or $null.
function Get-Completion {
    param([string]$Function, [datetime]$Since)
    $kql = "requests | where timestamp >= datetime($($Since.ToString('o'))) | where name =~ '$Function' or operation_Name =~ '$Function' " +
           "| order by timestamp desc | take 1 | project timestamp, success, duration"
    $resp = Invoke-AzRestMethod -Method POST -Path "$aiId/query?api-version=2018-04-20" -Payload (@{ query = $kql } | ConvertTo-Json)
    if ($resp.StatusCode -ne 200) { throw "Application Insights query failed (HTTP $($resp.StatusCode)): $($resp.Content)" }
    $table = @(($resp.Content | ConvertFrom-Json).tables)[0]
    if (-not $table -or -not @($table.rows).Count) { return $null }
    $row = @($table.rows)[0]
    return [PSCustomObject]@{ Success = [string]$row[1] -in @('True', 'true'); DurationMs = [double]$row[2] }
}

$problems = @()
$i = 0
foreach ($fn in $run) {
    $i++
    Write-Host "[$i/$($run.Count)] Triggering $fn..." -ForegroundColor Cyan
    # A little earlier than now, so a clock difference can't hide the completion.
    $since = [datetime]::UtcNow.AddSeconds(-30)
    $resp = Invoke-WebRequest -Method POST -Uri "https://$FunctionAppName.azurewebsites.net/admin/functions/$fn" `
        -Headers @{ 'x-functions-key' = $masterKey; 'Content-Type' = 'application/json' } `
        -Body '{"input":""}' -UseBasicParsing -SkipHttpErrorCheck
    if ([int]$resp.StatusCode -ne 202) {
        Write-Host "  not accepted: HTTP $($resp.StatusCode) $($resp.Content)" -ForegroundColor Red
        $problems += "$fn was not accepted (HTTP $($resp.StatusCode))"
        continue
    }
    $last = ($i -eq $run.Count)
    if ($NoWait) { Write-Host "  accepted (202) — running in the background" -ForegroundColor Green; continue }

    if ($aiId) {
        Write-Host "  accepted — waiting for it to finish (checked every 30s, up to $TimeoutMinutes min)..." -ForegroundColor Green
        $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
        $done = $null
        while (-not $done -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 30
            try { $done = Get-Completion -Function $fn -Since $since }
            catch { Write-Host "  $($_.Exception.Message) — falling back to fixed pauses." -ForegroundColor Yellow; $aiId = $null; break }
        }
        if ($done) {
            $mins = [Math]::Round($done.DurationMs / 60000, 1)
            if ($done.Success) { Write-Host "  finished in $mins min" -ForegroundColor Green }
            else { Write-Host "  FAILED after $mins min — see its traces in Application Insights" -ForegroundColor Red; $problems += "$fn failed" }
        } elseif ($aiId) {
            Write-Host "  not reported finished within $TimeoutMinutes min — moving on" -ForegroundColor Red
            $problems += "$fn was not seen to finish"
        }
    }
    if (-not $aiId -and -not $last) {
        $gap = $pipeline[$fn] * 60
        Write-Host "  accepted — pausing $($pipeline[$fn]) min (the nightly gap) before the next one..." -ForegroundColor Yellow
        Start-Sleep -Seconds $gap
    }
    if ($WaitSeconds -gt 0 -and -not $last) {
        Write-Host "  waiting ${WaitSeconds}s more..." -ForegroundColor Yellow
        Start-Sleep -Seconds $WaitSeconds
    }
}

Write-Host ""
if ($NoWait) {
    Write-Host "Triggered. Watch progress in Application Insights; the portal reflects results as each function finishes." -ForegroundColor Cyan
} elseif ($problems.Count) {
    Write-Host "Done, with problems:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "Done. The portal shows the new results now$(if (-not $aiId) { ' (or once the last function finishes)' })." -ForegroundColor Green
}
