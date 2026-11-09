#requires -Version 5.1
<#
.SYNOPSIS
    One-shot deployment of the Azure AI FinOps Portal (infrastructure + code)
    using only the Azure CLI (az). No Az PowerShell module required.

.DESCRIPTION
    The supported deploy path. From your
    machine or Azure Cloud Shell:

      0. Gate: offline tests (PowerShell parse check, Tests/*.Tests.ps1, node --test) and
         az bicep build — nothing is deployed if either fails
      1. Ensure the resource group exists
      2. Deploy infrastructure from azResources/main.bicep
      3. Zip-deploy the Function App (API + timers)
      4. Inject config.json with the resolved API hostname
      5. Zip-deploy the Web App (portal)

    Post-deploy setup (managed-identity RBAC, the BYOK AI provider key
    and the EasyAuth app registration) is NOT done here — run the
    Setup/ scripts afterwards. See docs/setup-guide.md.

.PARAMETER ResourceGroupName
    Target resource group. Created if it does not exist.

.PARAMETER Location
    Azure region used when creating the resource group. Default: westeurope.

.PARAMETER ParametersFile
    Bicep parameters file. Default: azResources/azuredeploy.parameters.dev.json.
    Copy that file to azResources/azuredeploy.parameters.local.json, fill in real
    values, and pass it here. The *.local.json pattern is git-ignored.

.PARAMETER SubscriptionId
    Optional. Sets the active subscription before deploying.

.PARAMETER ProductName
    Name shown in the portal banner and browser tab. Default: 'FinOps Portal'. Written to
    config.json at deploy time, so it can differ per deployment without a rebuild.

.PARAMETER Theme
    The portal's look: the name of a folder under src/web-app/src/themes/ (e.g.
    'azure-portal'). Default: 'azure-portal'. Written to config.json, so changing it needs no rebuild of
    the code — but the folder must exist in the build, which this script checks. Add a theme by
    adding its folder; remove one by deleting it.

.PARAMETER Language
    The portal's language: 'en' (English, the default) or 'da' (Danish). Currency follows it:
    English shows USD, Danish shows DKK. Written to config.json for the pages and, on a full
    deploy, to the Function App (PORTAL_LANGUAGE) so findings, explanations and Ask answers are
    written in it too — changing it with -CodeOnly changes the pages only.

.PARAMETER CodeOnly
    Skip the infrastructure deployment and only (re)deploy the app code.

.PARAMETER WhatIf
    Preview infrastructure changes (az deployment group what-if) and exit. Skips the test gate.

.PARAMETER SkipTests
    Skip the offline test gate (Tests/Invoke-OfflineTests.ps1). The bicep build check still
    runs for an infrastructure deploy. For emergencies only — the tests take about a minute.

.EXAMPLE
    az login
    ./deploy.ps1 -ResourceGroupName FinOpsPortal-dev -ParametersFile azResources/azuredeploy.parameters.local.json

.EXAMPLE
    # Re-deploy only the Function App + portal code after a code change
    ./deploy.ps1 -ResourceGroupName FinOpsPortal-dev -CodeOnly

.EXAMPLE
    # Same code, the Azure Portal look
    ./deploy.ps1 -ResourceGroupName FinOpsPortal-dev -CodeOnly -Theme azure-portal
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [string]$Location = 'westeurope',
    [string]$ParametersFile = "$PSScriptRoot/azResources/azuredeploy.parameters.dev.json",
    [string]$SubscriptionId,
    [string]$ProductName = 'FinOps Portal',
    [string]$Theme = 'azure-portal',
    [ValidateSet('en', 'da')][string]$Language = 'en',
    [switch]$CodeOnly,
    [switch]$WhatIf,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'

$deploymentName = 'azureAiFinOps'
$bicep   = Join-Path $PSScriptRoot 'azResources/main.bicep'
$funcSrc = Join-Path $PSScriptRoot 'src/function-app'
$webSrc  = Join-Path $PSScriptRoot 'src/web-app'

# Run az and throw on a non-zero exit code so the script stops on failure.
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    if (-not $Quiet) { Write-Host "az $($Arguments -join ' ')" -ForegroundColor DarkGray }
    $out = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
    return $out
}

# Zip-deploy the WEB APP (portal) with `az webapp deploy`.
#
# This replaced the legacy `... deployment source config-zip` because that command leans on SCM
# BASIC credentials, which main.bicep disables, and has a fixed short poll timeout that made the
# first deploy to a cold SCM site fail routinely. `az webapp deploy` uses the AAD token from
# `az login` and takes an explicit --timeout, and it has worked reliably for the portal.
#
# It is NOT used for the Function App — see Publish-FunctionAppZip for why.
#
# The first deploy after infrastructure creation still waits for the SCM site to warm up, so one
# retry with a longer timeout is built in rather than documented as a manual "run it again".
function Publish-SiteZip {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ZipPath,
        [int]$TimeoutSeconds = 600
    )
    $deployArgs = @('webapp', 'deploy', '-g', $ResourceGroupName, '-n', $AppName,
        '--src-path', $ZipPath, '--type', 'zip', '--timeout', "$TimeoutSeconds")
    try {
        Invoke-Az $deployArgs | Out-Null
    } catch {
        Write-Host "    deploy attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    retrying once with a longer timeout (cold SCM site)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        $retryArgs = @('webapp', 'deploy', '-g', $ResourceGroupName, '-n', $AppName,
            '--src-path', $ZipPath, '--type', 'zip', '--timeout', "$($TimeoutSeconds * 2)")
        Invoke-Az $retryArgs | Out-Null
    }
}

# Zip-deploy the FUNCTION APP with the Functions-specific command.
#
# DO NOT "modernise" this to `az webapp deploy`. That was tried, and against a Function App it
# reports success while never updating the running app: the CLI exits 0, an entry appears in the
# deployment history with "Deployment successful", the container recycles — and the host keeps
# serving the previous code. Every deploy for two days looked green while nothing landed, which
# is exactly the kind of failure that is expensive to diagnose because every signal says it
# worked. `az functionapp deployment source config-zip` is the documented path for Functions and
# is what actually delivers the code.
#
# If this ever fails with 401/403, SCM basic publishing credentials are disabled by main.bicep
# and this az version needs them. Allow them just for the deploy, then set properties.allow back
# to false:
#   az resource update -g <rg> --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies `
#       --name scm --parent sites/<app> --set properties.allow=true
function Publish-FunctionAppZip {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ZipPath
    )
    $deployArgs = @('functionapp', 'deployment', 'source', 'config-zip',
        '-g', $ResourceGroupName, '-n', $AppName, '--src', $ZipPath)
    try {
        Invoke-Az $deployArgs | Out-Null
    } catch {
        Write-Host "    deploy attempt failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    retrying once (cold SCM site)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        Invoke-Az $deployArgs | Out-Null
    }
}

# Fail loudly when a deploy lands nothing.
#
# Asks the HOST what it has actually loaded, rather than trusting the deployment record. A
# silent no-op deploy previously looked identical to a successful one from every other angle,
# so this is the check that turns "green but broken" into an error.
function Assert-FunctionsLoaded {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][int]$Expected
    )
    Write-Host "==> Verifying the Function App loaded its functions" -ForegroundColor Cyan
    # ~3 minutes of polling: the host is commonly still starting for a minute or two after a
    # deploy, and a false failure here would block the portal deploy that follows.
    $names = @()
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Start-Sleep -Seconds 15
        try {
            $json = Invoke-Az @('functionapp', 'function', 'list', '-g', $ResourceGroupName,
                '-n', $AppName, '--query', '[].name', '-o', 'json') -Quiet
            $names = @(($json -join "`n") | ConvertFrom-Json)
        } catch {
            # The host is often still starting right after a deploy; keep polling.
            $names = @()
        }
        if ($names.Count -ge $Expected) {
            Write-Host "    $($names.Count)/$Expected function(s) loaded." -ForegroundColor Green
            return
        }
        Write-Host "    $($names.Count)/$Expected loaded (attempt $attempt/12), waiting..." -ForegroundColor DarkGray
    }
    throw ("Function App '$AppName' reports $($names.Count) of $Expected functions after deployment. " +
           "The code did NOT land — do not treat this deploy as successful. See Publish-FunctionAppZip for the known cause.")
}

# Create the resource group only when it is missing. `az group create` on an existing group is
# still a write, so it needs rights on the group that a deployer with Contributor on its
# resources alone does not have; `az group exists` is a read.
function Initialize-ResourceGroup {
    $exists = (Invoke-Az @('group', 'exists', '-n', $ResourceGroupName) -Quiet | Out-String).Trim()
    if ($exists -eq 'true') { Write-Host "  Resource group exists." ; return }
    Invoke-Az @('group', 'create', '-n', $ResourceGroupName, '-l', $Location) | Out-Null
}

# --- preflight -------------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
}
if (-not (Test-Path $bicep)) { throw "Bicep template not found: $bicep" }

# The theme is a folder under src/web-app/src/themes/ with an index.ts; check it before anything
# is changed in Azure, so a typo can't ship a portal that falls back to another look.
$themesDir = Join-Path $webSrc 'src/themes'
$themes = @(Get-ChildItem -Path $themesDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'index.ts') } | ForEach-Object { $_.Name })
$Theme = $Theme.Trim().ToLowerInvariant()
if ($themes -notcontains $Theme) {
    throw "Theme '$Theme' not found. Available: $(if ($themes.Count) { $themes -join ', ' } else { 'none' }) (folders under src/web-app/src/themes/)."
}

if ($SubscriptionId) { Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null }
try { $account = Invoke-Az @('account', 'show', '--query', '{id:id,name:name}', '-o', 'json') -Quiet | Out-String | ConvertFrom-Json }
catch { throw "Not logged in to Azure. Run 'az login' first." }
# The Azure CLI keeps its own default subscription, separate from Az PowerShell and the portal.
Write-Host "==> Azure CLI subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan

# --- what-if (preview, then exit) ------------------------------------------
if ($WhatIf) {
    if (-not (Test-Path $ParametersFile)) { throw "Parameters file not found: $ParametersFile" }
    Initialize-ResourceGroup
    Invoke-Az @('deployment', 'group', 'what-if', '-g', $ResourceGroupName,
        '--template-file', $bicep, '--parameters', "@$ParametersFile")
    return
}

# --- gate: offline tests + bicep build --------------------------------------
# Before anything is changed in Azure. The tests need PowerShell 7.2+ (pwsh) and, for the portal
# server tests, Node — both of which a deploy needs anyway.
if ($SkipTests) {
    Write-Host "==> Offline tests SKIPPED (-SkipTests)" -ForegroundColor Yellow
} else {
    Write-Host "==> Running offline tests" -ForegroundColor Cyan
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        throw "pwsh (PowerShell 7.2+) not found — it runs the offline tests. Install it, or pass -SkipTests."
    }
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Tests/Invoke-OfflineTests.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Offline tests failed — nothing was deployed. Fix them, or pass -SkipTests to override." }
}
if (-not $CodeOnly) {
    Write-Host "==> Building main.bicep" -ForegroundColor Cyan
    Invoke-Az @('bicep', 'build', '--file', $bicep, '--stdout') -Quiet | Out-Null
}

# --- infrastructure --------------------------------------------------------
# The language reaches the Function App as PORTAL_LANGUAGE, when the template takes it.
$Language = $Language.ToLowerInvariant()
$languageParam = @(if ((Get-Content $bicep -Raw) -match '(?m)^param portalLanguage\b') { "portalLanguage=$Language" })
if (-not $CodeOnly) {
    if (-not (Test-Path $ParametersFile)) { throw "Parameters file not found: $ParametersFile" }
    if ((Get-Content $ParametersFile -Raw) -match '<[a-zA-Z]') {
        throw "Parameters file '$ParametersFile' still contains <placeholder> values. " +
              "Copy it to a *.local.json, fill in real values, and pass it with -ParametersFile."
    }

    Write-Host "==> Ensuring resource group '$ResourceGroupName' ($Location)" -ForegroundColor Cyan
    Initialize-ResourceGroup

    Write-Host "==> Deploying infrastructure (main.bicep)" -ForegroundColor Cyan
    Invoke-Az (@('deployment', 'group', 'create', '-g', $ResourceGroupName, '-n', $deploymentName,
        '--template-file', $bicep, '--parameters', "@$ParametersFile") + $languageParam) | Out-Null
}

# --- resolve resource names from the deployment outputs --------------------
Write-Host "==> Reading deployment outputs" -ForegroundColor Cyan
$outJson = Invoke-Az @('deployment', 'group', 'show', '-g', $ResourceGroupName, '-n', $deploymentName,
    '--query', 'properties.outputs', '-o', 'json') -Quiet
$outputs = ($outJson -join "`n") | ConvertFrom-Json
$functionAppName = $outputs.functionAppName.value
$webAppName      = $outputs.webAppName.value
$apiBaseUrl      = $outputs.functionAppUrl.value
$portalUrl       = $outputs.webAppUrl.value
if (-not $functionAppName -or -not $webAppName) {
    throw "Could not read app names from deployment '$deploymentName'. Run once without -CodeOnly first."
}

# --- package + deploy code -------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "finops-deploy-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # Function App (API + timers)
    $funcZip = Join-Path $tmp 'functionapp.zip'
    Write-Host "==> Packaging Function App" -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $funcSrc '*') -DestinationPath $funcZip -Force
    # One folder with a function.json per function — the count the host should end up loading.
    $expectedFunctions = @(Get-ChildItem -Path $funcSrc -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'function.json') }).Count
    Write-Host "    packaged $expectedFunctions function(s)" -ForegroundColor DarkGray
    Write-Host "==> Deploying Function App '$functionAppName'" -ForegroundColor Cyan
    Publish-FunctionAppZip -AppName $functionAppName -ZipPath $funcZip
    Assert-FunctionsLoaded -AppName $functionAppName -Expected $expectedFunctions

    # Web App (portal) — Vite build, then inject the runtime config.json into the
    # build output (dist/) so the artifact is tenant-agnostic until deploy time.
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        throw "npm not found. Install Node.js (LTS) to build the portal: https://nodejs.org"
    }
    # Vite 8 needs Node 20.19+ or 22.12+; an older Node fails deep inside the build.
    $nodeVersion = [version]((& node --version) -replace '^v', '')
    if (-not (($nodeVersion.Major -eq 20 -and $nodeVersion.Minor -ge 19) -or
              ($nodeVersion.Major -eq 22 -and $nodeVersion.Minor -ge 12) -or $nodeVersion.Major -ge 23)) {
        throw "Node.js $nodeVersion is too old to build the portal (needs 20.19+ or 22.12+)."
    }
    Write-Host "==> Building portal (Vite)" -ForegroundColor Cyan
    Push-Location $webSrc
    try {
        & npm ci
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed (exit $LASTEXITCODE)" }
        & npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit $LASTEXITCODE)" }
    }
    finally { Pop-Location }

    $webDist = Join-Path $webSrc 'dist'
    if (-not (Test-Path $webDist)) { throw "Portal build output not found: $webDist" }
    Write-Host "==> Injecting config.json (apiBaseUrl=$apiBaseUrl, theme=$Theme, language=$Language)" -ForegroundColor Cyan
    @{ apiBaseUrl = $apiBaseUrl; productName = $ProductName; theme = $Theme; language = $Language } | ConvertTo-Json | Set-Content -Path (Join-Path $webDist 'config.json') -Encoding utf8

    $webZip = Join-Path $tmp 'webapp.zip'
    Compress-Archive -Path (Join-Path $webDist '*') -DestinationPath $webZip -Force
    Write-Host "==> Deploying Web App '$webAppName'" -ForegroundColor Cyan
    Publish-SiteZip -AppName $webAppName -ZipPath $webZip
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- summary ---------------------------------------------------------------
Write-Host ""
Write-Host "Deployment complete." -ForegroundColor Green
Write-Host "  Portal : $portalUrl"
Write-Host "  API    : $apiBaseUrl"
Write-Host ""
Write-Host "Next steps (see docs/setup-guide.md):" -ForegroundColor Yellow
Write-Host "  1. Grant RBAC — Cost Management Reader + Reader at a MANAGEMENT GROUP (tenant-wide),"
Write-Host "     plus Storage data roles, Key Vault Secrets User, Monitoring Metrics Publisher:"
Write-Host "       Setup/Assign-AzureRbac.ps1 -ManagementGroupId <mgId>"
Write-Host "  2. (Optional) Store a BYOK AI provider key in Key Vault to enable AI features:"
Write-Host "       Setup/Configure-AiProvider.ps1   (then redeploy to resolve the KV reference)"
Write-Host "  3. (Optional) Create the Entra app registration for sign-in, set authClientId, redeploy:"
Write-Host "       Setup/Configure-AuthAppRegistration.ps1"
Write-Host "  Cost data ingests automatically across all subscriptions — no export to configure."
