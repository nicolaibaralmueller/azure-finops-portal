<#
.SYNOPSIS
    Validates the Azure AI FinOps Portal deployment: resources, managed-identity RBAC,
    AI provider wiring, the cost export, and connectivity. Read-only.

.DESCRIPTION
    Confirms the infrastructure deploy and the Setup scripts completed. Reads
    Setup/_setup-context.json (written by Assign-AzureRbac.ps1).

.EXAMPLE
    .\Validate-Deployment.ps1

.NOTES
    No elevated roles needed — read-only checks. Requires Az.Accounts, Az.Websites,
    Az.Storage, Az.Resources. Connect-AzAccount first.
#>

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Validate Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$contextPath = Join-Path $PSScriptRoot "_setup-context.json"
if (-not (Test-Path $contextPath)) {
    Write-Host "[ERROR] Setup context not found. Run Assign-AzureRbac.ps1 first." -ForegroundColor Red
    exit 1
}
$ctx = Get-Content $contextPath | ConvertFrom-Json
$results = @()

function Add-Check {
    param([string]$Check, [bool]$Passed, [string]$Detail = "")
    $script:results += [PSCustomObject]@{ Check = $Check; Status = if ($Passed) { "PASS" } else { "FAIL" }; Detail = $Detail }
    $color = if ($Passed) { "Green" } else { "Red" }
    $symbol = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    Write-Host "$symbol $Check" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
}

# ── Resources ──
Write-Host "--- Azure Resources ---" -ForegroundColor White
$func = Get-AzWebApp -ResourceGroupName $ctx.ResourceGroupName -Name $ctx.FunctionAppName -ErrorAction SilentlyContinue
Add-Check "Function App exists" ($null -ne $func) $ctx.FunctionAppName
if ($func) {
    Add-Check "Function App has managed identity" ($null -ne $func.Identity.PrincipalId) $func.Identity.PrincipalId
    Add-Check "Function App is running" ($func.State -eq "Running")
}

$web = @(Get-AzWebApp -ResourceGroupName $ctx.ResourceGroupName | Where-Object { $_.Kind -like '*app*' -and $_.Name -ne $ctx.FunctionAppName }) | Select-Object -First 1
Add-Check "Web App exists" ($null -ne $web) $web.Name
if ($web) { Add-Check "Web App is running" ($web.State -eq "Running") }

$storage = Get-AzStorageAccount -ResourceGroupName $ctx.ResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Check "Storage Account exists" ($null -ne $storage) $storage.StorageAccountName

# ── Managed-identity RBAC ──
Write-Host ""
Write-Host "--- Managed Identity RBAC ---" -ForegroundColor White
$principalId = $ctx.ManagedIdentityId
$roles = @()
if ($principalId) { $roles = @(Get-AzRoleAssignment -ObjectId $principalId -ErrorAction SilentlyContinue | ForEach-Object { $_.RoleDefinitionName }) }
foreach ($r in @('Cost Management Reader', 'Reader', 'Storage Table Data Contributor', 'Storage Blob Data Owner', 'Key Vault Secrets User')) {
    Add-Check "Role: $r" ($roles -contains $r)
}

# ── Access control ──
# Every endpoint is authLevel:anonymous, so the API is only protected by EasyAuth (or, when
# that is off, by Get-Caller denying unauthenticated callers). Flag an open API loudly.
Write-Host ""
Write-Host "--- Access Control ---" -ForegroundColor White
if ($func) {
    $funcSettings = @{}; foreach ($s in $func.SiteConfig.AppSettings) { $funcSettings[$s.Name] = $s.Value }
    $anonAllowed = ($funcSettings['ALLOW_ANONYMOUS_ACCESS'] -eq 'true')
    $authOn = $false
    try {
        $authCfg = Invoke-AzRestMethod -Path "$($func.Id)/config/authsettingsV2/list?api-version=2023-12-01" -Method POST -ErrorAction Stop
        $authOn = (($authCfg.Content | ConvertFrom-Json).properties.platform.enabled -eq $true)
    } catch { Write-Host "       (could not read authsettingsV2: $($_.Exception.Message))" -ForegroundColor Gray }

    Add-Check "API requires authentication (EasyAuth enabled)" $authOn `
        $(if ($authOn) { "unauthenticated calls get 401" } else { "EasyAuth is OFF — deploy with authClientId set" })
    Add-Check "API is not open to anonymous callers" (-not $anonAllowed -or $authOn) `
        $(if ($anonAllowed -and -not $authOn) { "ALLOW_ANONYMOUS_ACCESS=true and EasyAuth is off: ANY caller who reaches this host gets full admin over tenant-wide cost data and can spend the BYOK AI key. Set allowAnonymousAccess=false and configure EasyAuth." } else { "" })
    if (-not $authOn -and -not $anonAllowed) {
        Write-Host "       API is closed (all calls 403) until EasyAuth is configured — see docs/setup-guide.md." -ForegroundColor Gray
    }
    $ipRules = @($func.SiteConfig.IpSecurityRestrictions | Where-Object { $_.Action -eq 'Allow' -and $_.IpAddress -ne 'Any' })
    Add-Check "API network allow-list configured" ($ipRules.Count -gt 0 -or $authOn) `
        $(if ($ipRules.Count) { "$($ipRules.Count) allowed range(s)" } else { "optional — set apiAllowedIpRanges to restrict by network too" })
}

# ── AI provider wiring ──
Write-Host ""
Write-Host "--- BYOK AI Provider ---" -ForegroundColor White
if ($func) {
    $settings = @{}; foreach ($s in $func.SiteConfig.AppSettings) { $settings[$s.Name] = $s.Value }
    Add-Check "AI_PROVIDER set" (-not [string]::IsNullOrWhiteSpace($settings['AI_PROVIDER'])) $settings['AI_PROVIDER']
    Add-Check "AI_ENDPOINT set" (-not [string]::IsNullOrWhiteSpace($settings['AI_ENDPOINT'])) $settings['AI_ENDPOINT']
    Add-Check "AI_MODEL set" (-not [string]::IsNullOrWhiteSpace($settings['AI_MODEL'])) $settings['AI_MODEL']
    Add-Check "AI_API_KEY is a Key Vault reference" ($settings['AI_API_KEY'] -like '@Microsoft.KeyVault(*')
}

# ── Tenant-wide cost access ──
Write-Host ""
Write-Host "--- Cost Access (tenant-wide) ---" -ForegroundColor White
$principalId = $func.Identity.PrincipalId
if ($principalId) {
    $costRoles = @(Get-AzRoleAssignment -ObjectId $principalId -ErrorAction SilentlyContinue | Where-Object { $_.RoleDefinitionName -in @('Cost Management Reader', 'Reader') })
    $mgScoped = @($costRoles | Where-Object { $_.Scope -like '*/managementGroups/*' })
    Add-Check "Cost Management Reader + Reader granted" ($costRoles.Count -ge 2) "$($costRoles.Count) assignment(s)"
    Add-Check "Granted at a management group (tenant-wide)" ($mgScoped.Count -gt 0) $(if ($mgScoped.Count) { $mgScoped[0].Scope } else { "only subscription-scoped — the app will see one subscription; grant at a management group for tenant-wide" })
}

# ── Connectivity ──
Write-Host ""
Write-Host "--- Connectivity ---" -ForegroundColor White
if ($func) {
    try {
        Invoke-RestMethod -Uri "https://$($func.DefaultHostName)/api/health" -Method Get -TimeoutSec 10 -ErrorAction Stop | Out-Null
        Add-Check "Function App health endpoint" $true
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -in @(401, 404)) { Add-Check "Function App responds ($code)" $true "protected by EasyAuth or no anon health" }
        else { Add-Check "Function App reachable" $false $_.Exception.Message }
    }
}
if ($web) {
    try { $r = Invoke-WebRequest -Uri "https://$($web.DefaultHostName)" -Method Get -TimeoutSec 10 -ErrorAction Stop; Add-Check "Web App reachable" ($r.StatusCode -eq 200) }
    catch { Add-Check "Web App reachable" $false $_.Exception.Message }
}

# ── Subscription scope (information, not a check — covering a subset is a choice) ──
Write-Host ""
Write-Host "--- Subscription Scope ---" -ForegroundColor White
if ($storage) {
    try {
        $tok = (Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/').Token
        if ($tok -is [System.Security.SecureString]) { $tok = [System.Net.NetworkCredential]::new('', $tok).Password }
        $h = @{ Authorization = "Bearer $tok"; Accept = 'application/json;odata=nometadata'; 'x-ms-version' = '2020-12-06' }
        $tbl = "https://$($storage.StorageAccountName).table.core.windows.net/PortalConfig()"
        $scopeRow = @((Invoke-RestMethod -Uri "$tbl`?`$filter=$([uri]::EscapeDataString("PartitionKey eq 'settings' and RowKey eq 'scope'"))" -Headers $h).value) | Select-Object -First 1
        $marker = @((Invoke-RestMethod -Uri "$tbl`?`$filter=$([uri]::EscapeDataString("PartitionKey eq 'backfill' and RowKey eq 'dailytotal90'"))" -Headers $h).value) | Select-Object -First 1
        $ids = @(([string]$scopeRow.IncludedSubscriptionIds) -split '[,;\s]+' | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' })
        $current = if ($ids.Count) { [string]$scopeRow.ScopeHash } else { 'all' }
        $built = if ($marker -and $marker.ScopeHash) { [string]$marker.ScopeHash } else { 'all' }
        Write-Host "       Covers: $(if ($ids.Count) { "$($ids.Count) selected subscription(s)" } else { 'all subscriptions' }) — details: Setup/Set-SubscriptionScope.ps1 -ResourceGroupName $($ctx.ResourceGroupName) -Show" -ForegroundColor Gray
        if ($current -ne $built) { Write-Host "       Scope changed; the totals are rebuilt on the next nightly ingest (02:00 UTC)." -ForegroundColor Yellow }
    } catch {
        Write-Host "       Could not read it ($($_.Exception.Message)). Use Setup/Set-SubscriptionScope.ps1 -Show." -ForegroundColor Gray
    }
}

# ── Summary ──
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$passed = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$failed = ($results | Where-Object { $_.Status -eq "FAIL" }).Count
if ($failed -eq 0) {
    Write-Host " All $($results.Count) checks passed!" -ForegroundColor Green
    if ($web) { Write-Host " Portal URL: https://$($web.DefaultHostName)" -ForegroundColor Cyan }
} else {
    Write-Host " $passed/$($results.Count) passed, $failed failed" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Host "   - $($_.Check)" -ForegroundColor Red
        if ($_.Detail) { Write-Host "     $($_.Detail)" -ForegroundColor Gray }
    }
}
Write-Host "========================================" -ForegroundColor Cyan
