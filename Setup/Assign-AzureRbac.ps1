<#
.SYNOPSIS
    Grants the Azure RBAC roles the Function App managed identity needs. Run AFTER the
    first infrastructure deploy, by a privileged operator (the pipeline SP only has
    Contributor, which cannot write role assignments).

.DESCRIPTION
    Assigns to the Function App's system-assigned managed identity:

      - Cost Management Reader        (mgmt group*)    — read cost across all subscriptions
      - Reader                        (mgmt group*)    — Resource Graph inventory + Advisor (all subs)
      - Storage Table Data Contributor (storage acct)  — the portal tables
      - Storage Blob Data Owner       (storage acct)   — identity-based host storage (AzureWebJobsStorage)
      - Key Vault Secrets User        (key vault)      — resolve the AI_API_KEY reference
      - Monitoring Metrics Publisher  (app insights)   — Entra-authed telemetry (if local auth disabled)
      - Reservations Reader           (tenant, OPTIONAL via -IncludeReservationsReader)
                                                       — reservation names, utilisation and expiry
                                                         on the Savings page's commitments section
      - Savings plan Reader           (tenant, OPTIONAL via -IncludeSavingsPlanReader)
                                                       — savings plan utilisation and expiry

    * Cost/read roles are granted at the management group (-ManagementGroupId) so they cascade
      to every subscription (tenant-wide). Omit it to grant at the deployment subscription only.

    Idempotent — skips assignments that already exist. Writes Setup/_setup-context.json
    for Validate-Deployment.ps1.

.PARAMETER ResourceGroupName
.PARAMETER FunctionAppName
.PARAMETER SubscriptionId
    Optional. Defaults to the current Az context subscription. Scope for the two
    subscription-level roles.
.PARAMETER StorageAccountName
    Optional. Defaults to the single storage account in the resource group.
.PARAMETER KeyVaultName
    Optional. Defaults to the single key vault in the resource group (if any).
.PARAMETER AppInsightsName
    Optional. Defaults to the single Application Insights component in the resource group.
.PARAMETER AiAccountResourceId
    Optional. Resource ID of the Azure OpenAI / Foundry account the app calls with
    aiAuthMode=managedIdentity. Grants 'Cognitive Services OpenAI User' there (data-plane calls
    only, no keys). The account may be in another subscription; you need rights to assign roles on it.
.PARAMETER LogAnalyticsWorkspaceResourceId
    Deprecated and ignored. Log Analytics Reader is no longer granted: the app does not query a
    workspace (cost-change evidence reads the Activity Log through ARM, covered by Reader). Kept
    so existing command lines still run. An assignment made by an earlier version is harmless
    and can be removed by hand.

.EXAMPLE
    .\Assign-AzureRbac.ps1 -ResourceGroupName "FinOpsPortal-dev" -FunctionAppName "FinOpsPortal-api-dev"

.NOTES
    Required role: Owner, or User Access Administrator / RBAC Administrator on the
    subscription (to write role assignments at subscription + resource scope).
    Requires Az.Accounts, Az.Resources, Az.Websites, Az.Storage, Az.KeyVault,
    Az.ApplicationInsights and an active Connect-AzAccount session.
#>
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [Parameter(Mandatory = $true)][string]$FunctionAppName,
    [string]$SubscriptionId,
    [string]$StorageAccountName,
    [string]$KeyVaultName,
    [string]$AppInsightsName,
    [string]$LogAnalyticsWorkspaceResourceId,   # deprecated, ignored (see help)
    [string]$AiAccountResourceId,
    # Management group ID (name/GUID, not the full path) to grant tenant-wide cost/read access.
    # Cost Management Reader + Reader are granted here so they CASCADE to every child
    # subscription — that's what makes ingest/Advisor/savings tenant-wide. Omit to grant at the
    # single deployment subscription only (the app then only sees that one subscription).
    [string]$ManagementGroupId,
    # OPTIONAL: also grant 'Reservations Reader' at tenant scope (/providers/Microsoft.Capacity)
    # so reservation-order display names resolve via the Reservations API. Reservations have
    # their own RBAC — management-group Reader does NOT include them. Assigning at this scope
    # requires User Access Administrator rights at tenant root (Global Admin "elevate access").
    # Without it, names still resolve from cost data in most cases; the UI otherwise shows a
    # "Reservation order {short-id}" fallback.
    [switch]$IncludeReservationsReader,
    # OPTIONAL: also grant 'Savings plan Reader' at tenant scope (/providers/Microsoft.BillingBenefits)
    # so the Savings page can show each savings plan's utilisation and expiry. Same tenant-root
    # rights as -IncludeReservationsReader are needed to assign it.
    [switch]$IncludeSavingsPlanReader
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Assign Azure RBAC to Function App MI" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
    Write-Host "[ERROR] Az module not found. Install with: Install-Module Az -Scope CurrentUser" -ForegroundColor Red
    exit 1
}
$ctx = Get-AzContext
if (-not $ctx) { Write-Host "Connecting to Azure..." -ForegroundColor Yellow; Connect-AzAccount | Out-Null; $ctx = Get-AzContext }
if (-not $SubscriptionId) { $SubscriptionId = $ctx.Subscription.Id }
$subScope = "/subscriptions/$SubscriptionId"
Write-Host "Subscription: $SubscriptionId" -ForegroundColor Green

# ── Function App managed identity ──
$functionApp = Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
if (-not $functionApp) { Write-Host "[ERROR] Function App '$FunctionAppName' not found in '$ResourceGroupName'." -ForegroundColor Red; exit 1 }
$principalId = $functionApp.Identity.PrincipalId
if (-not $principalId) { Write-Host "[ERROR] Function App has no system-assigned managed identity." -ForegroundColor Red; exit 1 }
Write-Host "Function App identity (principalId): $principalId" -ForegroundColor Green

# ── Resolve target resources ──
if (-not $StorageAccountName) {
    $sa = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName)
    if ($sa.Count -ne 1) { Write-Host "[ERROR] Expected exactly one storage account (found $($sa.Count)). Pass -StorageAccountName." -ForegroundColor Red; exit 1 }
    $StorageAccountName = $sa[0].StorageAccountName
}
$storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
Write-Host "Storage account: $StorageAccountName" -ForegroundColor Green

if (-not $KeyVaultName) { $kv = @(Get-AzKeyVault -ResourceGroupName $ResourceGroupName); if ($kv.Count -eq 1) { $KeyVaultName = $kv[0].VaultName } }
$keyVault = $null
if ($KeyVaultName) { $keyVault = Get-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $KeyVaultName; Write-Host "Key Vault: $KeyVaultName" -ForegroundColor Green }
else { Write-Host "Key Vault: none found — skipping Key Vault role assignment" -ForegroundColor Yellow }

if (-not $AppInsightsName) { $ai = @(Get-AzApplicationInsights -ResourceGroupName $ResourceGroupName); if ($ai.Count -eq 1) { $AppInsightsName = $ai[0].Name } }
$appInsights = $null
if ($AppInsightsName) { $appInsights = Get-AzApplicationInsights -ResourceGroupName $ResourceGroupName -Name $AppInsightsName; Write-Host "Application Insights: $AppInsightsName" -ForegroundColor Green }

if ($LogAnalyticsWorkspaceResourceId) {
    Write-Host "-LogAnalyticsWorkspaceResourceId is ignored: Log Analytics Reader is no longer needed." -ForegroundColor Yellow
}

# ── Assign roles (idempotent) ──
function Add-RoleAssignment {
    param([string]$RoleName, [string]$Scope)
    $existing = Get-AzRoleAssignment -ObjectId $principalId -Scope $Scope -RoleDefinitionName $RoleName -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $Scope }
    if ($existing) { Write-Host "[SKIP] $RoleName @ $Scope" -ForegroundColor Yellow; return }
    try {
        New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName $RoleName -Scope $Scope -ObjectType 'ServicePrincipal' | Out-Null
        Write-Host "[OK]   $RoleName" -ForegroundColor Green
    } catch { Write-Host "[FAIL] $RoleName — $($_.Exception.Message)" -ForegroundColor Red }
}

# Cost/read roles go at the management group when supplied (cascades to all subscriptions =
# tenant-wide), else at the single deployment subscription.
$costScope = if ($ManagementGroupId) { "/providers/Microsoft.Management/managementGroups/$ManagementGroupId" } else { $subScope }
Write-Host "Cost/read scope: $costScope" -ForegroundColor Green

Write-Host ""
Add-RoleAssignment -RoleName "Cost Management Reader"          -Scope $costScope
Add-RoleAssignment -RoleName "Reader"                          -Scope $costScope
Add-RoleAssignment -RoleName "Storage Table Data Contributor"  -Scope $storage.Id
Add-RoleAssignment -RoleName "Storage Blob Data Owner"         -Scope $storage.Id
# The cost ingest's work queue (cost-tasks): the planner enqueues, the queue trigger reads.
Add-RoleAssignment -RoleName "Storage Queue Data Contributor"  -Scope $storage.Id
if ($keyVault)    { Add-RoleAssignment -RoleName "Key Vault Secrets User"     -Scope $keyVault.ResourceId }
if ($appInsights) { Add-RoleAssignment -RoleName "Monitoring Metrics Publisher" -Scope $appInsights.Id }
if ($AiAccountResourceId) { Add-RoleAssignment -RoleName "Cognitive Services OpenAI User" -Scope $AiAccountResourceId }
if ($IncludeReservationsReader) { Add-RoleAssignment -RoleName "Reservations Reader" -Scope "/providers/Microsoft.Capacity" }
if ($IncludeSavingsPlanReader) { Add-RoleAssignment -RoleName "Savings plan Reader" -Scope "/providers/Microsoft.BillingBenefits" }

# ── Persist setup context for validation ──
$contextPath = Join-Path $PSScriptRoot "_setup-context.json"
@{
    ResourceGroupName  = $ResourceGroupName
    FunctionAppName    = $FunctionAppName
    ManagedIdentityId  = $principalId
    SubscriptionId     = $SubscriptionId
    StorageAccountName = $StorageAccountName
    KeyVaultName       = $KeyVaultName
    AppInsightsName    = $AppInsightsName
    RbacAssigned       = $true
} | ConvertTo-Json | Set-Content -Path $contextPath -Encoding utf8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure RBAC assigned" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Role assignments can take a few minutes to propagate. Restart the Function App" -ForegroundColor Yellow
Write-Host "if it started before the roles were in place." -ForegroundColor Yellow
