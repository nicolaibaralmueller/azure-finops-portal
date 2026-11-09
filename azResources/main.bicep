// ============================================================================
// Azure AI FinOps Portal - Main Infrastructure Template
// ============================================================================
// Parameterized so the solution can be provisioned in any tenant /
// subscription / resource group. Customer-hosted: the customer deploys this into
// their OWN subscription, so their cost data, activity logs, and AI provider key
// never leave their tenant.
//
// Deploys: Storage Account (+ tables), shared App
//          Service Plan, Function App (API/timers), Web App (portal), Application
//          Insights (on the central Log Analytics workspace), Key Vault (holds the BYOK AI key),
//          and EasyAuth (optional).
//
// NOT here (granted post-deploy by Setup/Assign-AzureRbac.ps1, privileged operator):
//   Function App managed-identity RBAC — Cost Management Reader, Reader (Resource
//   Graph, Activity Log), Storage Table/Blob Data roles, Key Vault Secrets User,
//   Monitoring Metrics Publisher.
// ============================================================================

@description('Base name for all resources, e.g. "azFinOps"')
param appName string

@description('Environment identifier')
@allowed(['dev', 'tst', 'acc', 'prd'])
param environment string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Function App (API) name')
param functionAppName string = '${appName}-api-${environment}'

@description('Web App (portal) name')
param webAppName string = '${appName}-portal-${environment}'

@description('Shared App Service plan name (hosts both the Function App and the Web App)')
param appPlanName string = 'asp-${appName}-${environment}'

@description('Storage Account name (3-24 lowercase alphanumeric, globally unique)')
param storageAccountName string = toLower('${take(replace(appName, '-', ''), 13)}${take(uniqueString(resourceGroup().id), 6)}${environment}')

@description('''SKU for the shared Linux App Service plan, which hosts both apps with Always On. B2 (2 vCPU / 3.5 GB)
is the minimum. B3 or P0v3/P1v3 give more memory for a large tenant. Consumption (Y1) cannot run Always On, and B1 is
too small for two sites plus the nightly timers, so neither is offered.''')
@allowed(['B2', 'B3', 'P0v3', 'P1v3'])
param appPlanSku string = 'B2'

@description('Storage Account SKU')
param storageSku string = 'Standard_LRS'

@description('Linux runtime stack for the portal site')
param portalLinuxFxVersion string = 'NODE|24-lts'

@description('''Startup command serving the static portal from wwwroot. server.mjs ships in the portal build
(src/web-app/public) and sets long-lived cache headers on the hashed bundles, no-cache on index.html and
config.json, and brotli/gzip compression — none of which `pm2 serve` can do.''')
param portalStartupCommand string = 'node /home/site/wwwroot/server.mjs'

@description('''Optional. CIDR ranges allowed to reach the PORTAL site. When non-empty, all other
inbound traffic to the portal is denied. When empty (default), the portal is open to all networks.
The SCM/Kudu endpoint is intentionally left open so the pipeline can still deploy.
With frontDoorId set, the portal admits only Front Door instead, and this list still feeds the API (apiAllowedIpRanges).''')
param portalAllowedIpRanges array = []

@description('''Optional. CIDR ranges allowed to reach the API (Function App). The portal SPA calls the
API directly from the user's browser, so these must be the same client ranges as portalAllowedIpRanges —
leave EMPTY (default) to inherit exactly that list. Pass an explicit list only to diverge from it.''')
param apiAllowedIpRanges array = []

@description('''Optional. The Front Door ID (Front Door profile -> Overview -> Front Door ID) when the portal is
published through Azure Front Door. When set, the PORTAL admits only that Front Door (AzureFrontDoor.Backend service
tag + X-Azure-FDID header) instead of portalAllowedIpRanges, and EasyAuth builds its redirects from the forwarded
host (forwardProxy Standard). Client IP filtering then belongs in the Front Door WAF policy. The API keeps
apiAllowedIpRanges / portalAllowedIpRanges: the browser calls it directly.''')
param frontDoorId string = ''

@description('''Optional. Public host name of the portal behind Front Door, e.g. finops.example.com. Added to the
API's CORS origins (the browser calls the API from this origin). The app registration's redirect URI must use it.''')
param portalPublicHostName string = ''

@description('''REQUIRED. ARM resource ID of the central Log Analytics workspace that backs
Application Insights. No workspace is created here (policy denyLAWorkspace). Telemetry only: the app itself never
queries a workspace (cost-change evidence reads the Activity Log through ARM).''')
@minLength(1)
param logAnalyticsWorkspaceId string

@description('''Optional. Full ARM scope path used by the "Ask" (natural-language cost query) feature for
tenant-wide aggregate questions, e.g. /providers/Microsoft.Management/managementGroups/<mgId>. Cost
ingest, Advisor, and the savings detectors are already tenant-wide (they enumerate every accessible
subscription) and do NOT use this. Empty = the Ask feature falls back to the deployment subscription.''')
param costQueryScope string = ''

@description('''Optional. The resource tags that say who is responsible for spend, comma-separated, in order,
e.g. "ServiceLead, ProjectName, CostCenter, Environment". Each becomes a tab on Statements and
"Who spends it"; the FIRST is shown as the owner on every finding and in the brief. Matching ignores case
and punctuation. Empty = owner, costcenter, environment, application. A value saved through
SavePortalConfig (allocationTagKeys) overrides this.''')
param allocationTagKeys string = ''

@description('''The portal's language: 'en' (English, default) or 'da' (Danish). Set by deploy.ps1 -Language.
The Function App writes its own texts (savings, notes) and asks the AI for findings, explanations and Ask
answers in it; the web app reads the same choice from config.json.''')
@allowed([ 'en', 'da' ])
param portalLanguage string = 'en'

@description('''The portal's theme: a folder name under src/web-app/src/themes (e.g. azure-portal, contoso). Written
to the Web App as PORTAL_THEME, so a CI/CD pipeline can read it into config.json; it should refuse a theme
that isn't in the build. Empty = the app's default (azure-portal). deploy.ps1 uses its own -Theme instead.''')
param portalTheme string = ''

@description('''Disable instrumentation-key (local) auth on Application Insights and ingest telemetry with the
managed identity instead. DEFAULT FALSE — do NOT enable until the Function App identity holds Monitoring
Metrics Publisher (Setup/Assign-AzureRbac.ps1). Order: deploy (false) -> Assign-AzureRbac.ps1 -> set true and redeploy.''')
param disableAppInsightsLocalAuth bool = false

@description('Deploy a Key Vault for the BYOK AI provider key (secret value added after deploy by Setup/Configure-AiProvider.ps1)')
param deployKeyVault bool = true

@description('Key Vault name (3-24 chars, globally unique)')
param keyVaultName string = toLower('kv${take(replace(appName, '-', ''), 13)}${take(uniqueString(resourceGroup().id), 4)}${environment}')

// ---- BYOK AI provider configuration (the key itself lives in Key Vault, never here) ----

@description('AI provider the customer brought. "openai" covers any OpenAI-compatible endpoint (OpenAI, Azure OpenAI, Gemini compat, Mistral, Groq, Together, Ollama, vLLM, ...).')
@allowed(['openai', 'anthropic'])
param aiProvider string = 'openai'

@description('AI API base endpoint, e.g. https://api.openai.com/v1 or an Azure OpenAI deployment URL or https://api.anthropic.com')
param aiEndpoint string = ''

@description('Model id, e.g. gpt-4o-mini, claude-haiku-4-5. A cheap model is plenty — the model explains evidence the app gathered and never calculates.')
param aiModel string = ''

@description('Name of the Key Vault secret holding the AI provider API key. Set after running Setup/Configure-AiProvider.ps1. Empty = AI features disabled until configured.')
param aiApiKeySecretName string = ''

@description('''How the Function App authenticates to the AI provider. apiKey (default): the key from Key Vault
(aiApiKeySecretName). managedIdentity: no key; the Function App's identity gets an Entra token (Azure OpenAI /
Foundry only; grant it Cognitive Services OpenAI User on the account). Use managedIdentity whenever the account
allows it, and always when it sits behind a network security perimeter that admits this subscription.''')
@allowed([
  'apiKey'
  'managedIdentity'
])
param aiAuthMode string = 'apiKey'

@description('''Entra app registration (client) ID used for App Service Authentication (EasyAuth) on BOTH the portal and the API.
Create this app registration first (a tenant-level object). When set, the API rejects unauthenticated calls (HTTP 401);
when empty, EasyAuth is NOT deployed and both sites stay public.''')
param authClientId string = ''

@description('Scope so the portal token is valid against the API. Empty = "api://<authClientId>/user_impersonation".')
param authApiScope string = ''

@description('''Run the portal WITHOUT any authentication. Every Function App endpoint is authLevel:anonymous,
so with authClientId empty the only gate is Get-Caller in profile.ps1 — which fails CLOSED unless this is true.
Setting this to true grants every anonymous caller FULL ADMIN over tenant-wide cost data, the config endpoints,
and the endpoints that spend the BYOK AI key. Only ever use it together with apiAllowedIpRanges /
portalAllowedIpRanges on a trusted network, or for a throwaway dev deployment. Ignored when authClientId is set.''')
param allowAnonymousAccess bool = false

// ============================================================================
// Variables
// ============================================================================

var appInsightsName = '${appName}-AppInsights-${environment}'
var portalIdentityName = 'id-${appName}-portal-${environment}'

// Tables used by the Function App
var tableNames = [
  'AuditLog'        // who changed config
  'CostSnapshots'   // ingested daily cost, grouped by dimension (+ trailing baseline)
  'CostPeriods'     // daily snapshots rolled up per complete week/month — what detection reads
  'CostSpikes'      // detected period findings + evidence + AI explanations
  'CostSummary'     // precomputed dashboard cards
  'PortalConfig'    // thresholds / baseline window / scopes
  'Recommendations' // Azure Advisor cost recommendations
  'SavingsFindings' // the app's OWN deterministic savings conclusions
  'SavingsStatus'   // what an admin did with each one (open / in progress / done / dismissed)
]

// App Service Authentication (EasyAuth) — only deployed when a client ID is supplied
var enableAuth = !empty(authClientId)
var authOpenIdIssuer = '${az.environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
var resolvedApiScope = empty(authApiScope) ? 'api://${authClientId}/user_impersonation' : authApiScope

// Anonymous access is only ever possible when EasyAuth is NOT deployed, and only when the
// operator opted in. With EasyAuth on, unauthenticated calls never reach the code anyway.
var anonymousAccess = !enableAuth && allowAnonymousAccess

// The API is called from the browser, so it needs the same client allow-list as the portal
// unless one is given explicitly.
var apiIpRanges = empty(apiAllowedIpRanges) ? portalAllowedIpRanges : apiAllowedIpRanges

// Portal published through Azure Front Door (see frontDoorId).
var behindFrontDoor = !empty(frontDoorId)
var portalIpRules = [for (cidr, i) in portalAllowedIpRanges: {
  ipAddress: cidr
  action: 'Allow'
  priority: (100 + i)
  name: 'Allowed-${i}'
}]

// AI key Key Vault reference, wired only once the secret name is set
var aiKeyConfigured = aiAuthMode == 'apiKey' && deployKeyVault && !empty(aiApiKeySecretName)

// ============================================================================
// Application Insights
// ============================================================================

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
    IngestionMode: 'LogAnalytics'
    // Retention is the central workspace's; a component-level value is ignored
    // for workspace-based Application Insights.
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableLocalAuth: disableAppInsightsLocalAuth
  }
}

// ============================================================================
// Storage Account: Tables (portal state; cost data is pulled from the API, not stored as blobs)
// ============================================================================

resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2026-04-01' = {
  parent: storageAccount
  name: 'default'
}

resource tables 'Microsoft.Storage/storageAccounts/tableServices/tables@2026-04-01' = [
  for tableName in tableNames: {
    parent: tableService
    name: tableName
  }
]

// Cost data is pulled tenant-wide from the Cost Management Query API at runtime (no blob
// export container is needed).

// The cost ingest's work queue: one message per subscription task (PlanCostIngest-Timer enqueues,
// ProcessCostTask-Queue works through them one at a time). Needs Storage Queue Data Contributor
// for the Function App identity (Setup/Assign-AzureRbac.ps1).
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2026-04-01' = {
  parent: storageAccount
  name: 'default'
}

resource costTaskQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2026-04-01' = {
  parent: queueService
  name: 'cost-tasks'
}

// ============================================================================
// App Service Plan (shared) — one Linux dedicated plan hosts both apps, Always On.
// ============================================================================

resource appPlan 'Microsoft.Web/serverfarms@2025-03-01' = {
  name: appPlanName
  location: location
  kind: 'linux'
  sku: {
    name: appPlanSku
  }
  properties: {
    reserved: true // Linux dedicated
  }
}

// ============================================================================
// Web App (portal, static frontend served by Node)
// ============================================================================

// EasyAuth signs in WITHOUT a client secret: this user-assigned identity is trusted by the app
// registration through a federated identity credential (Setup/Configure-AuthAppRegistration.ps1
// -PortalIdentityPrincipalId), and EasyAuth uses it via OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID.
// https://learn.microsoft.com/azure/app-service/configure-authentication-provider-aad#use-a-managed-identity-instead-of-a-secret
resource portalIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (enableAuth) {
  name: portalIdentityName
  location: location
}

resource webApp 'Microsoft.Web/sites@2025-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  // The identity is used ONLY for EasyAuth sign-in; the portal itself calls nothing in Azure.
  identity: enableAuth ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${portalIdentity.id}': {}
    }
  } : null
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: portalLinuxFxVersion
      appCommandLine: portalStartupCommand
      alwaysOn: true
      // appSettings is a FULL replace on every infrastructure deploy, so every setting the site
      // needs lives here. WEBSITE_RUN_FROM_PACKAGE=1: deploy.ps1 (and any pipeline)
      // deploy with Run From Package; without it here an infra run would leave wwwroot empty.
      appSettings: concat([
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        // Not read by the site itself: for a pipeline that writes config.json.
        { name: 'PORTAL_THEME', value: portalTheme }
      ], enableAuth ? [
        { name: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID', value: portalIdentity!.properties.clientId }
      ] : [])
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.3'
      scmMinTlsVersion: '1.3'
      // Behind Front Door: only OUR Front Door. The service tag alone admits every customer's
      // Front Door, so the X-Azure-FDID header filter is required.
      // https://learn.microsoft.com/azure/app-service/app-service-ip-restrictions#restrict-access-to-a-specific-azure-front-door-instance
      ipSecurityRestrictions: behindFrontDoor ? [
        {
          ipAddress: 'AzureFrontDoor.Backend'
          tag: 'ServiceTag'
          action: 'Allow'
          priority: 100
          name: 'FrontDoor'
          headers: {
            'x-azure-fdid': [ frontDoorId ]
          }
        }
      ] : portalIpRules
    }
  }
}

// ============================================================================
// Function App (API + timers)
// ============================================================================

resource functionApp 'Microsoft.Web/sites@2025-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    reserved: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    siteConfig: {
      linuxFxVersion: 'PowerShell|7.6'
      alwaysOn: true
      // The platform pings this and restarts an instance that keeps failing it. health is
      // anonymous and does no I/O; with EasyAuth on it is excluded from sign-in below.
      healthCheckPath: '/api/health'
      use32BitWorkerProcess: false
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.3'
      scmMinTlsVersion: '1.3'
      ipSecurityRestrictions: [for (cidr, i) in apiIpRanges: {
        ipAddress: cidr
        action: 'Allow'
        priority: (100 + i)
        name: 'Allowed-${i}'
      }]
      cors: {
        allowedOrigins: concat([
          'https://${webApp.properties.defaultHostName}'
          'https://portal.azure.com'
        ], empty(portalPublicHostName) ? [] : [
          'https://${portalPublicHostName}'
        ])
        supportCredentials: true
      }
      appSettings: concat([
        // Host storage via managed identity (no secret).
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccount.name}.blob.${az.environment().suffixes.storage}/' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccount.name}.queue.${az.environment().suffixes.storage}/' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccount.name}.table.${az.environment().suffixes.storage}/' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        // The PowerShell worker processes ONE invocation at a time by default, so a nightly
        // timer that spends minutes in Cost Management backoff (or waiting on the ingest
        // marker) blocks every portal API call behind it — the UI just hangs until the
        // platform's 230s HTTP limit turns it into a 502. The functions hold no shared
        // mutable state, so a little in-process concurrency is safe.
        // Deliberately 3, not higher: going from 1 to 2 already stops a timer monopolising
        // the worker, and 3 leaves room for two overlapping timers plus a portal request.
        // Every extra slot is another invocation that can hold a detection pass in memory,
        // and the B2 plan's 3.5 GB is shared with the portal site.
        { name: 'PSWorkerInProcConcurrencyUpperBound', value: '3' }
        // Tolerant health check: 10 failed one-minute pings before an instance is replaced, so
        // a nightly timer that briefly fills the worker's slots doesn't trigger a restart.
        { name: 'WEBSITE_HEALTHCHECK_MAXPINGFAILURES', value: '10' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        // Ingest/Advisor/Savings are tenant-wide (the app enumerates every accessible
        // subscription). AZURE_SUBSCRIPTION_ID is the deploy sub, used only as the fallback
        // cost-query scope for the "Ask" feature when COST_QUERY_SCOPE (a management group) is unset.
        { name: 'AZURE_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'COST_QUERY_SCOPE', value: costQueryScope }
        // Which resource tags say who is responsible for spend (Allocation.psm1); the first is the owner.
        { name: 'ALLOCATION_TAG_KEYS', value: allocationTagKeys }
        // Language of the texts the API writes and of the AI's answers (Text.psm1).
        { name: 'PORTAL_LANGUAGE', value: portalLanguage }
        // Read by Get-Caller (profile.ps1). Anything other than 'true' = deny unauthenticated
        // callers. This is the ONLY thing standing in front of the API when EasyAuth is off.
        { name: 'ALLOW_ANONYMOUS_ACCESS', value: anonymousAccess ? 'true' : 'false' }
        // BYOK AI provider. Key is a Key Vault reference resolved by the platform via the
        // Function App identity (needs Key Vault Secrets User — Assign-AzureRbac.ps1). The
        // provider/endpoint/model are non-secret config; only the key lives in Key Vault.
        { name: 'AI_PROVIDER', value: aiProvider }
        { name: 'AI_ENDPOINT', value: aiEndpoint }
        { name: 'AI_MODEL', value: aiModel }
        { name: 'AI_AUTH_MODE', value: aiAuthMode }
        { name: 'AI_API_KEY', value: aiKeyConfigured ? '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=${aiApiKeySecretName})' : '' }
      ], disableAppInsightsLocalAuth ? [
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
      ] : [])
    }
  }
}

// ============================================================================
// Disable basic publishing credentials (FTP / SCM) on both sites
// ============================================================================

resource functionAppFtpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: functionApp
  name: 'ftp'
  properties: { allow: false }
}

resource functionAppScmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: functionApp
  name: 'scm'
  properties: { allow: false }
}

resource webAppFtpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: webApp
  name: 'ftp'
  properties: { allow: false }
}

resource webAppScmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: webApp
  name: 'scm'
  properties: { allow: false }
}

// ============================================================================
// App Service Authentication (EasyAuth) — deployed only when authClientId is supplied
// ============================================================================

resource functionAppAuth 'Microsoft.Web/sites/config@2025-03-01' = if (enableAuth) {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      // The platform health probe carries no token; without this it gets 401 and the
      // instance is marked unhealthy.
      excludedPaths: [
        '/api/health'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: authOpenIdIssuer
          clientId: authClientId
        }
        validation: {
          defaultAuthorizationPolicy: {
            allowedApplications: [
              authClientId
            ]
          }
          allowedAudiences: [
            'api://${authClientId}'
            authClientId
          ]
        }
      }
    }
    // No token store: the API only validates bearer tokens. The portal site keeps its store,
    // because the SPA reads its access token from /.auth/me.
  }
}

resource webAppAuth 'Microsoft.Web/sites/config@2025-03-01' = if (enableAuth) {
  parent: webApp
  name: 'authsettingsV2'
  properties: {
    platform: { enabled: true }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      // The icons carry no data; a browser fetching one for a bookmark or tab without a session
      // would otherwise get the sign-in page instead of an image.
      excludedPaths: [
        '/favicon.ico'
        '/favicon.svg'
        '/apple-touch-icon.png'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: authOpenIdIssuer
          clientId: authClientId
          // Not a secret: names the app setting holding the identity's client ID (see portalIdentity).
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
        }
        login: {
          loginParameters: [
            'scope=openid profile email ${resolvedApiScope}'
          ]
        }
      }
    }
    login: {
      tokenStore: { enabled: true }
    }
    // Behind Front Door the redirect URI is on the public host: Front Door sets X-Forwarded-Host and
    // EasyAuth builds its redirects from it. Only behind Front Door, where nothing else can set it.
    httpSettings: behindFrontDoor ? {
      forwardProxy: { convention: 'Standard' }
    } : null
  }
}

// ============================================================================
// Key Vault (optional) — holds the BYOK AI provider key.
// Secret value is added after deploy by Setup/Configure-AiProvider.ps1.
// RBAC (Key Vault Secrets User for the Function App identity) is granted by
// Setup/Assign-AzureRbac.ps1, not here.
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2026-02-01' = if (deployKeyVault) {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
  }
}

// ============================================================================
// Outputs — consumed by the pipeline (config.json injection) and Setup scripts
// ============================================================================

output functionAppName string = functionApp.name
output functionAppHostName string = functionApp.properties.defaultHostName
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}/api'
output functionAppPrincipalId string = functionApp.identity.principalId
output webAppName string = webApp.name
output webAppHostName string = webApp.properties.defaultHostName
// The address users open: the public host behind Front Door when set, else the default host.
output webAppUrl string = 'https://${empty(portalPublicHostName) ? webApp.properties.defaultHostName : portalPublicHostName}'
output storageAccountName string = storageAccount.name
output appInsightsName string = appInsights.name
output keyVaultName string = deployKeyVault ? keyVault.name : ''
output easyAuthEnabled bool = enableAuth
// True = the API is deliberately open to unauthenticated callers. deploy.ps1 and
// Validate-Deployment.ps1 surface this loudly.
output anonymousAccessEnabled bool = anonymousAccess
// Principal (object) ID of the portal's EasyAuth identity: the SUBJECT of the federated
// credential on the app registration. Empty when EasyAuth is off.
output portalIdentityPrincipalId string = enableAuth ? portalIdentity!.properties.principalId : ''
// The central workspace backing Application Insights.
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspaceId
