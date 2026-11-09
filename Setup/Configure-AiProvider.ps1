<#
.SYNOPSIS
    Stores the customer's BYOK AI provider key in Key Vault and wires the non-secret
    provider settings onto the Function App. The key never appears in source, Bicep
    parameters, or any API response — only in Key Vault.

.DESCRIPTION
    1. Writes the API key as a Key Vault secret (default name 'ai-api-key').
    2. Sets AI_PROVIDER / AI_ENDPOINT / AI_MODEL and AI_API_KEY (a Key Vault reference)
       on the Function App, preserving existing app settings.
    3. Restarts the Function App so the settings load and the reference resolves.

    The Function App managed identity needs 'Key Vault Secrets User' for the reference to
    resolve (granted by Assign-AzureRbac.ps1). Pass -GrantVaultAccess to ensure it here.

.PARAMETER ResourceGroupName
.PARAMETER FunctionAppName
.PARAMETER Provider          openai | anthropic  ("openai" = any OpenAI-compatible endpoint)
.PARAMETER Endpoint          e.g. https://api.openai.com/v1 | AOAI deployment URL | https://api.anthropic.com
.PARAMETER Model             e.g. gpt-4o-mini | claude-haiku-4-5 (a cheap model is plenty)
.PARAMETER ApiKey            SecureString. If omitted, the script prompts for it.
.PARAMETER KeyVaultName      Optional. Resolved from the latest deployment output if omitted.
.PARAMETER SecretName        Key Vault secret name. Default 'ai-api-key'.
.PARAMETER GrantVaultAccess  Also ensure the Function App MI has 'Key Vault Secrets User'.

.EXAMPLE
    .\Configure-AiProvider.ps1 -ResourceGroupName "FinOpsPortal-dev" -FunctionAppName "FinOpsPortal-api-dev" `
        -Provider openai -Endpoint "https://api.openai.com/v1" -Model "gpt-4o-mini" -GrantVaultAccess

.NOTES
    Requires Az.Accounts, Az.Websites, Az.KeyVault, Az.Resources. Connect-AzAccount first.
#>
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$FunctionAppName,
    [Parameter(Mandatory = $true)][ValidateSet('openai', 'anthropic')][string]$Provider,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$Model,
    [securestring]$ApiKey,
    [string]$KeyVaultName,
    [string]$SecretName = 'ai-api-key',
    [switch]$GrantVaultAccess
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Configure BYOK AI Provider" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$ctx = Get-AzContext
if (-not $ctx) { Write-Host "[ERROR] Not connected to Azure. Run Connect-AzAccount first." -ForegroundColor Red; exit 1 }
Write-Host "Subscription: $($ctx.Subscription.Name)" -ForegroundColor Green

if (-not $ApiKey) { $ApiKey = Read-Host "Enter the AI provider API key" -AsSecureString }
$plainKey = [System.Net.NetworkCredential]::new("", $ApiKey).Password
if ([string]::IsNullOrWhiteSpace($plainKey)) { Write-Host "[ERROR] API key is empty." -ForegroundColor Red; exit 1 }

$functionApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
if (-not $functionApp) { Write-Host "[ERROR] Function App '$FunctionAppName' not found in '$ResourceGroupName'." -ForegroundColor Red; exit 1 }

# ── Resolve Key Vault (from deployment outputs when not supplied) ──
if (-not $KeyVaultName) {
    $deployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName |
        Where-Object { $_.Outputs.Keys -contains 'keyVaultName' -and $_.Outputs['keyVaultName'].Value } |
        Sort-Object Timestamp -Descending | Select-Object -First 1
    if ($deployment) { $KeyVaultName = $deployment.Outputs['keyVaultName'].Value }
}
if (-not $KeyVaultName) { Write-Host "[ERROR] Could not determine Key Vault name. Pass -KeyVaultName." -ForegroundColor Red; exit 1 }
$vault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
if (-not $vault) { Write-Host "[ERROR] Key Vault '$KeyVaultName' not found." -ForegroundColor Red; exit 1 }
Write-Host "Using Key Vault: $KeyVaultName" -ForegroundColor Green

if ($GrantVaultAccess) {
    $principalId = $functionApp.Identity.PrincipalId
    if (-not $principalId) { Write-Host "[ERROR] Function App has no managed identity." -ForegroundColor Red; exit 1 }
    $existing = Get-AzRoleAssignment -ObjectId $principalId -Scope $vault.ResourceId -RoleDefinitionName "Key Vault Secrets User" -ErrorAction SilentlyContinue
    if ($existing) { Write-Host "[SKIP] MI already has 'Key Vault Secrets User'." -ForegroundColor Yellow }
    else { New-AzRoleAssignment -ObjectId $principalId -Scope $vault.ResourceId -RoleDefinitionName "Key Vault Secrets User" | Out-Null; Write-Host "[OK]   Granted 'Key Vault Secrets User' to MI." -ForegroundColor Green }
}

# ── Store the key + build the Key Vault reference ──
Write-Host "Writing secret '$SecretName' to Key Vault..." -ForegroundColor Yellow
$secret = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -SecretValue $ApiKey
$secretUri = "$($secret.Id -replace '/[^/]+$','')/"
$apiKeyRef = "@Microsoft.KeyVault(SecretUri=$secretUri)"
Write-Host "AI_API_KEY will reference: $secretUri" -ForegroundColor Green

# ── Merge into existing app settings (Set-AzWebApp replaces the whole collection) ──
$settings = @{}
foreach ($s in $functionApp.SiteConfig.AppSettings) { $settings[$s.Name] = $s.Value }
$settings['AI_PROVIDER'] = $Provider
$settings['AI_ENDPOINT'] = $Endpoint
$settings['AI_MODEL']    = $Model
$settings['AI_API_KEY']  = $apiKeyRef

Set-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -AppSettings $settings | Out-Null
Write-Host "[OK]   AI_PROVIDER / AI_ENDPOINT / AI_MODEL / AI_API_KEY set." -ForegroundColor Green

Restart-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName | Out-Null
Write-Host "[OK]   Function App restarted." -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " AI provider configured ($Provider / $Model)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "The AI key resolves via Key Vault — it is not in app configuration." -ForegroundColor Gray
Write-Host "If you did not pass -GrantVaultAccess, confirm the MI has 'Key Vault Secrets User'." -ForegroundColor Gray
