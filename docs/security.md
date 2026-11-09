# Security

## Trust boundary

The solution runs entirely in the **customer's** subscription. The publisher operates
nothing and holds no customer data or credentials. The AI key never leaves the tenant; the
only data that does is what the AI features send to the provider **the customer configured**
(see *AI data flow* below). With no provider configured, nothing leaves at all.

## Identity & access

- **No secrets for Azure access.** The Function App uses its system-assigned **managed
  identity** for Cost Management, Resource Graph, the Activity Log, Advisor, Azure Monitor
  metrics, Storage, Key Vault (when deployed) and, with `aiAuthMode=managedIdentity`, Azure
  OpenAI / Foundry. EasyAuth signs in with the portal's **user-assigned identity** through a
  federated credential on the app registration, so there is no client secret either.
- **Least privilege.** Granted roles are read-only over Azure data plus read/write on the
  portal's own storage tables (`Setup/Assign-AzureRbac.ps1`). No write access to customer
  resources — the portal recommends, it does not act. Reviewed role by role:

  | Role | Scope | Why it can't be narrower |
  |---|---|---|
  | Cost Management Reader | management group | Read-only, and the whole product is tenant-wide cost. Subscription scope would limit the app to one subscription. |
  | Reader | management group | Resource Graph inventory, Advisor, and Azure Monitor metrics all need resource read. Cost Management Reader alone does not grant it. |
  | Storage Table Data Contributor | the app's storage account | The portal's own tables are read *and written*; there is no read-only variant that works. |
  | Storage Blob Data Owner | the app's storage account | Required by the Functions host for identity-based `AzureWebJobsStorage` (Microsoft's documented minimum — Contributor is not sufficient). Scoped to the app's own account, which holds no customer data. |
  | Storage Queue Data Contributor | the app's storage account | The `cost-tasks` queue the cost ingest plans and works through. |
  | Key Vault Secrets User | the app's key vault (only when deployed) | Read the one BYOK secret. Cannot read vault metadata or write. |
  | Cognitive Services OpenAI User | the AI account (**opt-in**, `-AiAccountResourceId`) | Call the model with `aiAuthMode=managedIdentity`. Inference only; no key, no management rights. |
  | Monitoring Metrics Publisher | the app's App Insights | Publish telemetry when instrumentation-key auth is disabled. Write-only, to the app's own component. |
  | Reservations Reader | tenant (**opt-in**, `-IncludeReservationsReader`) | Reservation names, utilisation and expiry on the Reservations page and the Savings page's commitments panel. Read-only. Off by default; the pages then say it is missing. Which resources use each reservation needs only Cost Management Reader. |
  | Savings plan Reader | tenant (**opt-in**, `-IncludeSavingsPlanReader`) | Savings plan utilisation and expiry. Read-only. Off by default. |
- **AuthN/AuthZ.** EasyAuth (Entra) fronts both sites when `authClientId` is set; the API
  returns 401 to anonymous calls. `Get-Caller` enforces `FinOps.Admin` vs `FinOps.Member`
  server-side. Timer triggers don't traverse HTTP auth.
- **The API fails closed.** Every function is `authLevel: anonymous`, so `Get-Caller` is the
  only gate when EasyAuth is off. With no principal header it **denies** (HTTP 403 with a
  reason) unless the operator explicitly set `allowAnonymousAccess=true`, which surfaces as
  the `ALLOW_ANONYMOUS_ACCESS` app setting. Deploying without EasyAuth therefore yields a
  closed portal, not an open one — running it open is a deliberate, auditable choice, and
  `Setup/Validate-Deployment.ps1` fails a check while it is on.

## Error surfaces

Upstream exception text (Cost Management, Resource Graph, Key Vault, the AI provider) can
carry resource ids, tenant/subscription identifiers, endpoint URLs and provider diagnostics.
No endpoint returns it. `Write-ErrorBody` logs the detail to Application Insights against a
**correlation id** and returns only that id plus a generic message, so a user can quote the id
in a support request without the response itself becoming an information-disclosure channel.

## The BYOK AI key

- **None at all with `aiAuthMode=managedIdentity`** (Azure OpenAI / Foundry): the Function App's
  identity calls the model, and `deployKeyVault=false` leaves the vault out. The rest of this
  section applies to `aiAuthMode=apiKey`.
- Stored **only** in Key Vault; surfaced to the Function App as a
  `@Microsoft.KeyVault(...)` reference resolved by the managed identity.
- Never in source, Bicep parameters, logs, or any API response. `GetPortalConfig` returns
  the provider/model but never the key.
- Set via `Setup/Configure-AiProvider.ps1` (read as a SecureString).
- **Bounded spend.** Every model call — `Invoke-AiCompletion` and each step of `Invoke-AiAgent` —
  counts against `AiDailyCallLimit` (PortalConfig, default 200 calls per UTC day; `0` switches AI
  off). A spend cap on the model deployment itself (e.g. in Azure AI Foundry) is a second limit.
  Over the limit the timers fall back to their deterministic output and the interactive endpoints
  answer HTTP 429. Per-call token usage is logged to Application Insights, and every
  interactive AI action (`ExplainSpike`, `QueryCosts`, `RegenerateBrief`) writes an
  `AuditLog` row.

## AI data flow

Every AI call goes through `AiAdapter.psm1` to the customer's own provider. What each path sends:

| Path | Trigger | Sent to the provider | Returned |
|---|---|---|---|
| Cost-change explanation | `DetectCostSpikes-Timer` (largest findings only), `ExplainSpike` (admin) | The change (period, subscription name, resource name, meter category, rounded USD figures), the resource's type / SKU / location, and the numbered evidence: meter / resource / service names with their figures, recorded operations and configuration changes (old → new values), new resources, owner / cost-centre tags | Headline, cause, cited fact ids, explained flag, recommendation |
| Key findings (agent) | `BuildBrief-Timer` (weekly), `RegenerateBrief` (admin) | Spend figures and Azure's forecast, the largest changes of the last 7 days and of last month with their facts, the largest open savings (titles, resource names, amounts), spend per owner and per resource group. **Owner names, subscription names and every GUID are replaced by tokens** (`OWNER_1`, `SUBN_1`, `ID_1`) before sending, in the payload and in every tool result; tool arguments are mapped back before a query runs. Tools are read-only: a Cost Management query on the Ask allowlist, and stored evidence / saving detail | 3–6 findings with figures copied from the data, cited ids, a proposed command (displayed, never run) |
| Ask | `QueryCosts` (members and admins) | The question as typed, up to three earlier turns, optional page context (names and period of what the user was looking at), the allowed dimensions; then the result rows (resource ids, resource group and subscription names, amounts). The list of subscription names is **not** sent: code finds the ones the question names. | A query spec (validated before use), then a short answer |

The allocation rollup, statements, savings checks and the stored per-resource cost send nothing to
the AI provider — they are computed in code.

The findings agent never acts: it has no write tool, and the command it proposes is text on the
page for a person to review. A finding is stored only when it cites a payload id or a tool call
and every figure in it appears in what the model was given (`Select-InsightFindings`).

Cost-change evidence and Ask results carry **Azure resource IDs**, which contain the subscription
GUID and resource group name (the model needs them to tell resources apart). In the findings
agent's payload and tool results every GUID is replaced by a token. Not sent: raw cost tables, the
AI key, user identities (see below). Savings findings and Advisor recommendations are **not** sent to the AI for rewording —
the app shows its own text and Advisor's.

## Data minimization & privacy

- The model receives **precomputed numbers + minimal labels**, never raw cost tables. Everything
  in the table above is the customer's own Azure metadata, sent to the provider the customer
  configured.
- Identities from the Activity Log (UPNs) are **pseudonymized** before being sent to the model.
- **Turning AI off** is one setting: `AiDailyCallLimit = 0`. The portal then shows the figures,
  evidence, savings and findings ranked by amount without any provider call.
- **Figures come from the data.** The findings agent may only copy figures from its payload and
  tool results; a finding with any other figure is dropped, and amounts, ids and field names are
  removed from the text it writes (the page shows the figures in the reader's currency).
- The model is never asked "why" without evidence: a finding with none gets no written
  explanation rather than a guess, and an explanation must cite the facts it used.
- Every AI path (cost-change explanations, the key findings, the Ask answer) runs
  `Test-NarrativeGrounding` over the model's prose: any figure it states that was not in the
  payload we sent flags the text as unverified in the UI.

## Network

- HTTPS only, TLS 1.3, FTP/SCM basic publishing disabled on both sites.
- Optional IP allow-lists on the portal (`portalAllowedIpRanges`) **and the API**
  (`apiAllowedIpRanges`, which inherits the portal list when left empty — the SPA calls the
  API straight from the browser, so both need the same client ranges).
- Storage: no public blob access, OAuth-default, cross-tenant replication off.
- Outbound-only AI calls; no inbound inference endpoint is exposed.

## Reporting

See [SECURITY.md](../SECURITY.md) for how to report a vulnerability.
