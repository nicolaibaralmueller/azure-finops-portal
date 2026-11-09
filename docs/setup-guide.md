# Setup Guide

End-to-end install into your own Azure subscription.

## AI is optional — no API key required

**You do not need an AI provider key to deploy or use the portal.** Every figure the app
produces is calculated deterministically; the AI only turns those numbers into sentences.

- **Works with no key:** cost-change detection with evidence, the Overview (spend, forecast,
  savings by priority, chase list, findings ranked by amount), the **Savings** page, statements
  and Ask questions answered from the stored per-resource cost.
- **Adds a key later (Step 3, optional):** the AI findings agent's key findings, the written
  explanation of the largest cost changes, and free-form **Ask** questions.

So deploy now without a key and add one whenever you like — no logic changes, just Step 3.

## Prerequisites

- Azure CLI (`az`) and an account with **Owner** (or Contributor + User Access Administrator)
  on the target subscription — role assignments are created post-deploy.
- **(Optional)** An AI provider (BYOK) — provider, endpoint, model id, API key — only if you
  want the AI features. A cheap model is plenty: it explains evidence the app has already
  gathered and never calculates. Usage is capped at `AiDailyCallLimit` calls per day (default
  200, `0` turns AI off; change it with a POST to `SavePortalConfig` `{ "aiDailyCallLimit": n }`;
  the Ask panel shows today's usage).
  Note that subscription Owner does **not** let you write the key to Key Vault — that is a
  separate data-plane role, see Step 3.

## 1. Deploy infrastructure + code

```powershell
az login
Copy-Item azResources/azuredeploy.parameters.dev.json azResources/azuredeploy.parameters.local.json
# Fill in appName and logAnalyticsWorkspaceId (and optionally authClientId, portalAllowedIpRanges).
# logAnalyticsWorkspaceId (required): resource ID of the central Log Analytics workspace
#   that backs App Insights (telemetry only). No workspace is created. AI settings are NOT needed here.
# appPlanSku: B2 (default, the minimum), B3, P0v3 or P1v3.
./deploy.ps1 -ResourceGroupName FinOpsPortal-tst -SubscriptionId <id> -ParametersFile azResources/azuredeploy.parameters.local.json
```

- **`-SubscriptionId`** — always pass it. The Azure CLI keeps its own default subscription,
  separate from Az PowerShell and the portal; the script prints the one it deploys to.
- **`-Theme`** — the portal's look: `azure-portal` (default), or any folder under
  `src/web-app/src/themes/`. Change it later with `-CodeOnly -Theme <name>`.
- **`-Language`** — `en` (English, default) or `da` (Danish). Currency follows it: English shows
  USD, Danish shows DKK. `-CodeOnly -Language da` switches the pages; a full deploy also passes
  it to the Function App so AI-written texts follow.

### If the code deploy is slow on the first run

The first deploy has to wait for a **cold SCM site** (slower still because the function host
can't fully start until Step 2 grants it storage access). `deploy.ps1` handles this with one
automatic retry per site. Expect the first run to take a few minutes.

The two sites deploy with different commands, deliberately:

- **Portal (Web App):** `az webapp deploy --type zip --timeout 600` — AAD auth, so it doesn't
  need the basic publishing credentials the template disables.
- **API (Function App):** `az functionapp deployment source config-zip`. Do **not** switch this
  to `az webapp deploy`: against a Function App that command reports success and recycles the
  container while the host keeps running the previous code.

After the Function App deploy, `deploy.ps1` asks the host how many functions it loaded and
**fails the deploy if the count is short of what was packaged**, so a deploy that silently
lands nothing is caught immediately rather than days later.

If **both** attempts fail, the infrastructure is still fine — only the code step failed. Recover
with:

1. Run **Step 2 (RBAC)** now — the host needs it regardless.
2. Wait 1–2 minutes, then redeploy the code only (skips infra, retries against a warm SCM):
   ```powershell
   ./deploy.ps1 -ResourceGroupName FinOpsPortal-tst -SubscriptionId <id> -CodeOnly -ParametersFile azResources/azuredeploy.parameters.local.json
   ```

## 2. Grant the managed identity its roles

Run this right after the infrastructure exists — the Function App can't fully start until it has
storage access, so doing it early also settles the SCM site.

```powershell
Setup/Assign-AzureRbac.ps1 -ResourceGroupName FinOpsPortal-tst -FunctionAppName <fromOutputs> `
    -ManagementGroupId "<mgId for tenant-wide cost/read>"
```

Grants Storage Table/Blob/Queue data roles, Key Vault Secrets User (when the vault is deployed),
Monitoring Metrics Publisher, Cognitive Services OpenAI User on the AI account (only with
`-AiAccountResourceId`, see Step 3), and —
the tenant-wide part — **Cost Management Reader + Reader at the management group**, which cascade
to every subscription under it. Reader also covers the Activity Log, which cost-change evidence
reads; **Log Analytics Reader is no longer needed** (an assignment left from an earlier version is
harmless).

- **`-ManagementGroupId`** makes cost ingest, Advisor, and the savings detectors span **all
  subscriptions** in that management group. Omit it to grant at the single deployment subscription
  only (the app then sees just that one). Granting at a management group typically needs the
  platform/governance team.
- **`-LogAnalyticsWorkspaceResourceId`** is deprecated and ignored; it is still accepted so older
  command lines run.
- **`-IncludeReservationsReader`** (optional but recommended if you own reservations): grants
  **Reservations Reader** at tenant scope (`/providers/Microsoft.Capacity`) so the portal can show
  the **child reservation names** (e.g. `Standard_D8ds_v5_App01_06-01-2025`) instead
  of the auto-generated numeric order numbers that appear in billing data. Reservations have their
  **own RBAC** — the management-group Reader role does not cover them, which is why the timers log
  a (single, harmless) 403 hint without this role. Without it, names fall back to the billing
  data's `ReservationName` dimension — usually the numeric order number.
  Assigning at tenant scope requires User Access Administrator at root (Global Admin
  ["elevate access"](https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin)).

## 3. Configure an AI provider (OPTIONAL — skip to run without AI)

**Azure OpenAI / Foundry without a key (preferred):** set `"aiAuthMode": { "value": "managedIdentity" }`
with `aiProvider`, `aiEndpoint` and `aiModel` in the params file (and `deployKeyVault: false` if
nothing else needs the vault), redeploy, and grant the Function App *Cognitive Services OpenAI User*
on the account (`Setup/Assign-AzureRbac.ps1 -AiAccountResourceId <account resource ID>`). This is
required when the account sits behind a network security perimeter: a subscription rule there only
admits managed-identity calls, never API keys. The rest of this section is for the key-based setup.

To enable the written explanations and Ask with an API key, store your key in Key Vault:

```powershell
Setup/Configure-AiProvider.ps1 -KeyVaultName <kv> -FunctionAppName <fn> -ResourceGroupName FinOpsPortal-tst `
    -Provider openai -Endpoint https://api.openai.com/v1 -Model gpt-4o-mini -GrantVaultAccess
```

Omit `-ApiKey` and the script prompts for it, which keeps the key out of your shell history.

### You need Key Vault Secrets Officer first — subscription Owner is not enough

The vault is deployed with **`enableRbacAuthorization: true`**, so vault access is Azure RBAC
rather than access policies, and **Owner or Contributor on the subscription grants nothing on the
data plane**. Two different principals need two different roles:

| Principal | Role | Why | Granted by |
| --- | --- | --- | --- |
| **You**, running this script | **Key Vault Secrets Officer** | *writes* the secret | nobody — grant it to yourself, below |
| Function App managed identity | **Key Vault Secrets User** | *reads* it at runtime via the Key Vault reference | Step 2, or `-GrantVaultAccess` here |

`Key Vault Secrets User` is read-only, so giving yourself that one will not work — `setSecret`
needs Officer.

Without it the script prompts for your API key and *then* fails on the write:

```
Operation returned an invalid status code 'Forbidden'
Action: 'Microsoft.KeyVault/vaults/secrets/setSecret/action'
Resource: '/subscriptions/.../vaults/<kv>/secrets/ai-api-key'
Assignment: (not found)
```

`Assignment: (not found)` is the tell — no data-plane role at all, not the wrong one. Grant it at
the vault scope and re-run the script:

```powershell
$vault = Get-AzKeyVault -VaultName <kv>
New-AzRoleAssignment -SignInName <you@example.com> -RoleDefinitionName "Key Vault Secrets Officer" -Scope $vault.ResourceId
```

Creating that assignment needs Owner or User Access Administrator on the vault (or its resource
group). Allow a minute for it to propagate before retrying. The role is only needed to *set* the
key — you can remove it afterwards without affecting the running app, which reads through the
managed identity.

### Endpoint format per provider

| Provider | `-Provider` | `-Endpoint` |
| --- | --- | --- |
| OpenAI | `openai` | `https://api.openai.com/v1` |
| Azure AI Foundry | `openai` | `https://<resource>.services.ai.azure.com` |
| Azure OpenAI | `openai` | `https://<resource>.openai.azure.com` |
| Anthropic | `anthropic` | `https://api.anthropic.com` |
| Ollama / vLLM / gateway | `openai` | `http://host:port/v1` |

Pass the host as shown and the adapter completes the route: on an Azure host it inserts
`/openai/v1/` (the chat route is **not** served at the root — appending `/chat/completions` to a
bare Foundry host is a 404 on every AI call), elsewhere it appends `/chat/completions`. It also
detects `azure.com` and switches to the `api-key` header by itself.

An endpoint that already names `chat/completions` is used verbatim, so the deployment-scoped form
(`…/openai/deployments/<dep>/chat/completions?api-version=…`) still works if you prefer it. The
`/openai/v1/` route is the better default: it takes the model from the request body, so one
endpoint serves every deployment and `-Model` alone selects between them.

`-Model` is the **deployment name**, which on Azure is not necessarily the model name — check the
Deployments blade. A wrong one is a 404 that looks exactly like a wrong endpoint.

**If Foundry gave you a `…/openai/v1/responses` URL**, that is the Responses API — a different
protocol (`input`/`output` rather than `messages`/`choices`), which Foundry's sample code now
defaults to for GPT-5. This portal speaks Chat Completions. The same resource serves both, so pass
the bare host; the adapter also accepts the `/responses` URL and redirects it to the sibling chat
route, so either works.

Confirm afterwards with `Setup/Validate-Deployment.ps1` (Step 6) — the AI check goes from *not
configured* to configured — or open the portal and use **Regenerate** on the key findings (admin).

### Put the same values in your Bicep params — a full redeploy wipes them otherwise

This script sets the four `AI_*` app settings directly, but `main.bicep` also declares them, from
parameters that default to **empty**. So the next `deploy.ps1` run *without* `-CodeOnly` overwrites
all four with blanks and the portal goes back to reporting **"No AI provider is configured yet"** —
with no error, because from the app's point of view nothing is configured. (The Key Vault secret
survives; only the settings pointing at it are lost.)

Add the block to your params file so the deploy sets what you actually want:

```json
"aiProvider":         { "value": "openai" },
"aiEndpoint":         { "value": "https://<resource>.services.ai.azure.com" },
"aiModel":            { "value": "<deployment-name>" },
"aiApiKeySecretName": { "value": "ai-api-key" }
```

`aiApiKeySecretName` is the secret's **name**, not its value — the key stays in Key Vault, and
Bicep emits the reference. Nothing secret goes in the params file.

If it has already happened, you do not need the API key again — the secret is still there, so just
restore the settings:

```powershell
az functionapp config appsettings set -g <rg> -n <fn> --settings AI_PROVIDER=openai AI_ENDPOINT=<endpoint> AI_MODEL=<deployment> "AI_API_KEY=@Microsoft.KeyVault(VaultName=<kv>;SecretName=ai-api-key)"
```

Any provider works (`openai` covers any OpenAI-compatible endpoint; `anthropic` for the Messages
API).

## 4. Cost data ingestion — nothing to configure

There is **no export or per-subscription setup**. `PlanCostIngest-Timer` runs when the app starts
and then hourly: it enumerates every subscription the managed identity can see (via the
management-group grant in Step 2) and queues one task per subscription on the `cost-tasks` queue,
which `ProcessCostTask-Queue` works through one at a time. After that first run it loads about
120 days of history, one calendar month per task, and then runs the analysis once (savings,
detection, statements, the brief), so a new deployment is complete within an hour or two. Cost
Management's per-tenant quota (600 QPU an hour) sets the pace; nothing needs to be started by hand.
From then on the nightly run starts at 02:00 UTC. Needs *Storage Queue Data Contributor* on the
storage account (Step 2).

### Optional: allocation tags and commitment roles

- **Who owns spend** is read from tags — `owner`, `costcenter`, `environment` and `application`
  by default, taken from the resource group when a resource has none. If your tenant uses other
  names, POST them to `SavePortalConfig`: `{ "allocationTagKeys": "owner, team, env" }` (up to
  6; case and punctuation are ignored). The `environment` tag also drives the "non-production VM
  running around the clock" savings check.
- **Reservations and savings plans** utilisation and expiry need two optional tenant-scope roles:
  `Setup/Assign-AzureRbac.ps1 … -IncludeReservationsReader -IncludeSavingsPlanReader` (needs
  tenant-root User Access Administrator). Without them the Savings page shows only unused
  commitment cost and Azure's purchase recommendations, and says which role is missing.
  The **Reservations page** (which resources use each commitment, and its unused cost) needs no
  extra role: it reads amortized cost data with Cost Management Reader. Without a management
  group covering every subscription it asks each subscription, and unused hours then show only
  where the subscription that bought the commitment is in scope.
- **Tenant-wide forecast and Ask** use a management group containing every included
  subscription. The portal finds one itself when its identity can read it; set `costQueryScope`
  in the Bicep params to choose it explicitly. For CSP / Microsoft Customer Agreement
  subscriptions Cost Management does not answer management-group queries; Ask then answers from
  the stored per-resource cost or queries each subscription.

### Optional: limit the portal to some subscriptions

By default the portal covers every subscription its identity can see. To leave some out
(sandboxes, Visual Studio subscriptions), run:

```powershell
Setup/Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst            # pick from a list
Setup/Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -Exclude 'Sandbox'
Setup/Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -All       # back to everything
Setup/Set-SubscriptionScope.ps1 -ResourceGroupName FinOpsPortal-tst -Show
```

- **One scope for everything and everyone:** ingest, cost changes, savings, Advisor, the
  Overview, forecast, budgets, the key findings and Ask. There is no portal UI for it — the
  banner only shows "N of M subscriptions" while a scope is set.
- **A removed subscription is hidden at once** on every page; **tenant totals** (month-to-date,
  the trend, the month view, forecast, brief) are **rebuilt on the next nightly run**. Until
  then the banner says the scope changed. Nothing is deleted: adding it back restores it, and
  its per-resource history is refetched.
- The list offered is what the portal's identity sees (recorded by the nightly ingest); before
  the first ingest it is what *your* account sees.
- The script writes with your Entra identity if you hold Storage Table Data Contributor on the
  portal's storage account, otherwise with the account key (Contributor is enough). Each change
  is recorded in the portal's `AuditLog`.
- With `costQueryScope` set to a management group, the forecast and Ask are filtered to the
  included subscriptions, and management-group budgets are hidden while a scope is set.

## 5. Enable sign-in (EasyAuth — REQUIRED unless you deliberately run open)

```powershell
Setup/Configure-AuthAppRegistration.ps1 -PortalHostname "<portal>.azurewebsites.net"
```

Set the printed `authClientId` in the Bicep params and redeploy. That deploys the portal's
user-assigned identity (`id-<appName>-portal-<env>`); EasyAuth signs in with it, so there is
**no client secret**. Then trust that identity on the app registration with a federated
credential (the principal ID is the deployment output `portalIdentityPrincipalId`):

```powershell
Setup/Configure-AuthAppRegistration.ps1 -PortalHostname "<portal>.azurewebsites.net" `
    -ApplicationId <authClientId> -PortalIdentityPrincipalId <portalIdentityPrincipalId>
```

Finally assign users to the `FinOps.Admin` / `FinOps.Member` app roles.

**Until you do this the API answers every call with HTTP 403** (`"reason": "unauthenticated:
App Service Authentication is not configured on this API…"`), and the portal shows no data.
That is deliberate: every function is `authLevel: anonymous`, so with EasyAuth off the only
thing in front of tenant-wide cost data — and of the endpoints that spend your AI key — is
the app's own check, and it fails closed.

To run open anyway (throwaway dev deployment, or a network where you trust every caller),
set `allowAnonymousAccess: true` in the Bicep params and redeploy. Every anonymous caller
then gets **full admin**, so pair it with `apiAllowedIpRanges` / `portalAllowedIpRanges`.
`Validate-Deployment.ps1` reports a failing check for as long as it is on.

## 6. Validate

```powershell
Setup/Validate-Deployment.ps1 -ResourceGroupName FinOpsPortal-tst -FunctionAppName <fn>
```

## Order of operations

```
deploy (infra) → RBAC (incl. management-group cost/read) → [optional AI key] → [optional EasyAuth] → validate
```

- The **first code deploy may time out** (see Step 1) — run RBAC, then redeploy with `-CodeOnly`.
- Steps in [brackets] are optional; the app is fully functional (minus AI findings, written
  explanations, free-form Ask, and sign-in) without them.
- **Timers (UTC — `WEBSITE_TIME_ZONE` is not set, so these are *not* local time):** ingest 02:00,
  savings finder 02:35, cost-change detection 02:40, Advisor sync 02:45, commitments 02:50,
  monthly + month-view sync 02:55, allocation + per-resource cost 03:05, brief and key findings
  03:15.
  The whole pipeline finishes inside an hour, well before a European workday in either DST phase.
  Run the pipeline immediately with `Tools/Invoke-SpikeDetection.ps1` once RBAC is in place
  (there is no export to wait for).
