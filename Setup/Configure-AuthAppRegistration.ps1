<#
.SYNOPSIS
    Creates or updates the Entra app registration that fronts portal sign-in (EasyAuth),
    including the FinOps.Admin / FinOps.Member app roles. Idempotent.

.DESCRIPTION
    Configures in one pass:
      - Web redirect URI for the portal (`https://<portal>/.auth/login/aad/callback`) + ID tokens
      - Application ID URI `api://<clientId>` and the `user_impersonation` delegated scope
      - Pre-authorization of the app to call its own API (no consent prompt)
      - The `FinOps.Admin` and `FinOps.Member` app roles (role IDs preserved per value so
        existing user/group assignments survive a re-run)
      - The enterprise application's "Assignment required = Yes"
    With -PortalIdentityPrincipalId, adds the federated identity credential that lets the portal's
    user-assigned identity sign in as this app registration. EasyAuth then needs NO client secret
    (OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID, set by main.bicep). Never create a client secret.

.PARAMETER PortalHostname
    The portal's full default hostname, e.g. `FinOpsPortal-portal-dev.azurewebsites.net`.
.PARAMETER DisplayName
    App registration display name. Default 'Azure AI FinOps Portal'.
.PARAMETER ApplicationId
    (Optional) Existing app registration's Application (client) ID to update.
.PARAMETER PortalIdentityPrincipalId
    (Optional) Object (principal) ID of the portal's user-assigned identity: deployment output
    portalIdentityPrincipalId (exists after the first infrastructure deploy with authClientId set).
    Adds the federated credential (issuer https://login.microsoftonline.com/<tenant>/v2.0,
    subject = this ID, audience api://AzureADTokenExchange). Idempotent.

.EXAMPLE
    .\Configure-AuthAppRegistration.ps1 -PortalHostname "FinOpsPortal-portal-prd.azurewebsites.net" `
        -ApplicationId <client-id> -PortalIdentityPrincipalId <principal-id>

.NOTES
    Requires the Microsoft.Graph module and Application.ReadWrite.All.
    Required Entra role: Application Administrator (or owner of the app registration).
#>
param(
    [Parameter(Mandatory = $true)][string]$PortalHostname,
    [string]$DisplayName = "Azure AI FinOps Portal",
    [string]$ApplicationId,
    [string]$PortalIdentityPrincipalId
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Configure Auth App Registration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "[ERROR] Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" -ForegroundColor Red
    exit 1
}
if (-not (Get-MgContext)) { Connect-MgGraph -Scopes "Application.ReadWrite.All" | Out-Null }

$redirectUri = "https://$PortalHostname/.auth/login/aad/callback"

# ── Find or create the app registration ──
$app = $null
if ($ApplicationId) {
    $app = Get-MgApplication -Filter "appId eq '$ApplicationId'" -ErrorAction SilentlyContinue
    if (-not $app) { Write-Host "[ERROR] No app registration with appId '$ApplicationId'." -ForegroundColor Red; exit 1 }
} else {
    $app = Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $app) {
    $app = New-MgApplication -DisplayName $DisplayName -SignInAudience "AzureADMyOrg"
    Write-Host "Created app registration '$DisplayName' (appId $($app.AppId))" -ForegroundColor Green
} else {
    Write-Host "Updating existing app registration (appId $($app.AppId))" -ForegroundColor Yellow
}
$clientId = $app.AppId

# ── user_impersonation scope (reuse existing Id if present) ──
$existingScope = $app.Api.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'user_impersonation' } | Select-Object -First 1
$scopeId = if ($existingScope) { $existingScope.Id } else { [guid]::NewGuid().ToString() }
$scope = @{
    Id                      = $scopeId
    Value                   = "user_impersonation"
    Type                    = "User"
    IsEnabled               = $true
    AdminConsentDisplayName = "Access the Azure AI FinOps Portal API"
    AdminConsentDescription = "Allow the app to access the FinOps Portal API on behalf of the signed-in user."
    UserConsentDisplayName  = "Access the Azure AI FinOps Portal API"
    UserConsentDescription  = "Allow the app to access the API on your behalf."
}

# ── App roles (reuse existing Id per value so assignments survive re-runs) ──
function New-FinOpsRole { param([string]$Value, [string]$Display, [string]$Desc)
    $id = ($app.AppRoles | Where-Object { $_.Value -eq $Value } | Select-Object -First 1).Id
    if (-not $id) { $id = [guid]::NewGuid().ToString() }
    return @{ Id = $id; AllowedMemberTypes = @("User"); Value = $Value; DisplayName = $Display; Description = $Desc; IsEnabled = $true }
}
$finopsRoles = @(
    (New-FinOpsRole "FinOps.Admin"  "FinOps Admin"  "Full access: view everything and change thresholds / AI provider config."),
    (New-FinOpsRole "FinOps.Member" "FinOps Member" "View-only access to spikes, narratives, and recommendations.")
)
$otherRoles = @($app.AppRoles | Where-Object { $_.Value -notin @('FinOps.Admin', 'FinOps.Member') } | ForEach-Object {
        @{ Id = $_.Id; AllowedMemberTypes = $_.AllowedMemberTypes; Value = $_.Value; DisplayName = $_.DisplayName; Description = $_.Description; IsEnabled = $_.IsEnabled }
    })
$allRoles = @($otherRoles + $finopsRoles)

# ── Ensure the portal redirect URI is present (merge, don't clobber) ──
$redirects = @($app.Web.RedirectUris)
if ($redirects -notcontains $redirectUri) { $redirects += $redirectUri }

# ── Apply (two-step: scope must persist before preAuthorizedApplications can reference it) ──
Update-MgApplication -ApplicationId $app.Id `
    -IdentifierUris @("api://$clientId") `
    -Web @{ RedirectUris = $redirects; ImplicitGrantSettings = @{ EnableIdTokenIssuance = $true } } `
    -Api @{ Oauth2PermissionScopes = @($scope); RequestedAccessTokenVersion = 2 } `
    -AppRoles $allRoles

Update-MgApplication -ApplicationId $app.Id `
    -Api @{ Oauth2PermissionScopes = @($scope); RequestedAccessTokenVersion = 2; PreAuthorizedApplications = @(@{ AppId = $clientId; DelegatedPermissionIds = @($scopeId) }) }

Write-Host "[OK] Redirect URI, api://$clientId scope, self pre-authorization, and FinOps.Admin/Member roles configured." -ForegroundColor Green

# ── Enterprise application (service principal): require assignment ──
$sp = Get-MgServicePrincipal -Filter "appId eq '$clientId'" -ErrorAction SilentlyContinue
if (-not $sp) { $sp = New-MgServicePrincipal -AppId $clientId; Write-Host "Created enterprise application (service principal)." -ForegroundColor Green }
Update-MgServicePrincipal -ServicePrincipalId $sp.Id -AppRoleAssignmentRequired:$true
Write-Host "[OK] Enterprise application: Assignment required = Yes." -ForegroundColor Green

# ── Federated credential for the portal's identity (no client secret) ──
if ($PortalIdentityPrincipalId) {
    $tenantId = (Get-MgContext).TenantId
    $issuer = "https://login.microsoftonline.com/$tenantId/v2.0"
    $existing = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id |
        Where-Object { $_.Issuer -eq $issuer -and $_.Subject -eq $PortalIdentityPrincipalId }
    if ($existing) {
        Write-Host "[OK] Federated credential for $PortalIdentityPrincipalId already present." -ForegroundColor Green
    } else {
        New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
            Name      = "easyauth-portal-identity"
            Issuer    = $issuer
            Subject   = $PortalIdentityPrincipalId
            Audiences = @("api://AzureADTokenExchange")
        } | Out-Null
        Write-Host "[OK] Federated credential added: EasyAuth signs in with the portal identity, no secret." -ForegroundColor Green
    }
} else {
    Write-Host "Skipped the federated credential: pass -PortalIdentityPrincipalId after the first infra deploy." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Done. Application (client) ID: $clientId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Put this client ID in azuredeploy.parameters.<env>.json -> authClientId, then redeploy." -ForegroundColor Gray
Write-Host "  2. Entra ID -> Enterprise applications -> this app -> Users and groups: assign users to" -ForegroundColor Gray
Write-Host "     'FinOps Admin' or 'FinOps Member'. Only assigned users can sign in." -ForegroundColor Gray
