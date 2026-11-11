# Architecture

The portal has one job: tell a platform / FinOps team and management **what is going on
cost-wise, who to chase, about what, and for how much** — on one page they look at weekly or
monthly. Every part of the design is judged against that.

## Deployment model

Customer-hosted: the customer deploys the solution into
**their own Azure subscription** and it runs there on their data. The only thing that leaves the
tenant is what the AI features send to the **AI provider the customer configured** (see
[security.md](security.md#ai-data-flow)); without a provider, nothing leaves at all. The customer
runs `deploy.ps1`; `-Theme` picks the portal's look.

## Azure resources

The app deploys into one resource group but operates **tenant-wide**: it reads every subscription
its managed identity can see.

| Resource | Role |
|---|---|
| Function App (PowerShell 7.6, Linux, Always On, health check on `/api/health`) | API endpoints + timer jobs |
| Web App (Node 24) | The portal, served by `server.mjs` (cache headers, compression, SPA fallback) |
| App Service Plan (shared, B2 minimum) | Hosts both apps |
| Storage Account — Tables | see below |
| App Service Authentication | EasyAuth on both sites when `authClientId` is set. The API also fails closed on its own: with no principal header it denies unless `allowAnonymousAccess` was explicitly set. |
| Application Insights (on the central Log Analytics workspace) | Telemetry only |
| Key Vault (optional, `deployKeyVault`) | The BYOK AI provider key (the only secret) when `aiAuthMode=apiKey`. Not needed with `aiAuthMode=managedIdentity` |
| Managed Identity (system-assigned, on the Function App) | All Azure data access, and Azure OpenAI / Foundry with `aiAuthMode=managedIdentity` — no secrets |
| User-assigned identity `id-<appName>-portal-<env>` | EasyAuth signs in with it through a federated credential on the app registration — no client secret |

Tables:

| Table | Holds |
|---|---|
| `CostSnapshots` | Daily cost per resource (raw, pruned after `SnapshotRetentionDays`); partition `cat\|yyyy-MM-dd` holds the day's exact total per subscription and meter category |
| `CostPeriods` | Month rollups per resource, for the monthly baseline |
| `CostSpikes` | Cost-change findings + evidence, partitioned `<week\|month>\|<period>` |
| `CostSummary` | `dailytotal` (billed daily totals), `monthly-sub` (monthly total per subscription), `monthoverview` (forecast, budgets), `allocation` (spend per owner / tag / resource group), `resourcecost` (every resource's cost this month and last month), `statement`, `statement-daily` (each month's spend per tag value by day, for the statement trend), `statementbudgets`, `brief` (weekly / monthly payload + findings) |
| `SavingsFindings`, `SavingsStatus` | The app's own savings and what an admin did with each |
| `Recommendations` | Azure Advisor cost recommendations |
| `PortalConfig` | Settings, scope, run markers, AI usage counter |
| `AuditLog` | Every admin and interactive AI action |

The managed identity is granted (post-deploy, `Setup/Assign-AzureRbac.ps1`): **Cost Management
Reader + Reader at a management group** (cost, forecast, budgets, Resource Graph, Advisor, Azure
Monitor metrics and the Activity Log across all subscriptions), Storage Table Data Contributor +
Blob Data Owner (host storage) + Queue Data Contributor (`cost-tasks`), Key Vault Secrets User (when
the vault is deployed), Monitoring Metrics Publisher, and Cognitive Services OpenAI User on the AI
account (with `-AiAccountResourceId`, for `aiAuthMode=managedIdentity`).

### Subscription scope

The operator can limit the portal to some subscriptions with `Setup/Set-SubscriptionScope.ps1`
(no portal UI; the header shows the included subscriptions the identity can read). It is stored in
`PortalConfig` `settings/scope` and applies to everything and everyone:

- **Read-time filter — immediate.** Every timer gets only the included subscriptions
  (`Get-AccessibleSubscriptions -StorageToken`), and every endpoint drops rows of excluded ones as
  it reads (`Test-InSubscriptionScope`). Nothing is deleted.
- **Nightly rebuild — tenant-wide sums.** The daily totals, month view and brief record the
  `ScopeHash` they were built for; a mismatch rebuilds them on the next run, and until then the
  endpoints return `scopePending`.
- **Live queries** at a management group get a `SubscriptionId In [...]` filter; management-group
  budgets are hidden while a scope is set.

A subscription in the scope that the identity cannot read has no cost data and is not listed.

## The rules

1. **Every figure the AI states comes from the data.** Arithmetic is in code (`CostAnalysis.psm1`,
   `CostEvidence.psm1`, `SavingsFinder.psm1`, `Brief.psm1`, `Allocation.psm1`) or comes straight
   from an Azure API. The findings agent may copy figures from its payload and from read-only tool
   results; a finding with any other figure is dropped.
2. **The AI never explains without evidence.** Code gathers what happened first — which meters
   moved, usage or unit price, what was created, resized or deleted. Findings must cite payload ids
   or tool calls.
3. **No names to the model.** Owners, subscription names and GUIDs are replaced by tokens; Activity
   Log identities are pseudonymised.
4. **The AI never acts.** Read-only tools only; proposed commands are text for a person.
5. **Everything works without AI.** Figures, evidence, savings and findings ranked by amount
   render with no provider (or over the daily AI limit).

## Detection grain: weekly and monthly, complete periods only

Detection is **not daily**: a one-day spike is over before anyone looks. The money is in sustained
change.

- **Grains:** a **trailing 7 days** and **complete calendar months**. The 7-day window is rolling
  (always exactly 7 days, ending at D-2) so a change is caught within days instead of waiting for
  a calendar week to close; it ramps in at 1/7 per day, so the signal only grows. Months stay
  calendar and complete-only.
- **Baseline:** the *median* of the prior complete periods — 4 weeks, 3 months — so one unusual
  period can neither mask a change nor manufacture one. Baseline windows never overlap the
  current one. A baseline period in which a key was **created** (it started after the first day
  and had cost every day after; `Get-StartedSpanDays`, stored per dimension on the rollup and
  window rows) counts at its daily level scaled to a whole period, so a VM created on the 12th
  is not a "cheap month". A start in the period's last 2 days is left out of the baseline. Gaps
  mean an intermittent workload, which is never scaled.
- **Thresholds** (`PortalConfig`): weekly `$150 / 25%`, monthly `$500 / 15%`.
- **Sustained increases** (`Find-CostStepUp`, `DetectSavings-Timer`) are reported with the cost
  changes, never as savings.

**Finding lifecycle** (explained on the page under "How these findings are calculated"):

- **State** (`Get-FindingState`) is judged nightly from the *current level*: the mean of the latest
  3 settled days (to D-2), scaled to a whole period — for a closed month, these are days after it.
  `resolved` = that level would no longer clear the bar; `decreasing` = still above it but at most
  75% of the period's average day; `open` otherwise. A month that already ended below the bar
  (`Measure-ExitRunRate`) stays resolved. So a cost that drops is shown as resolved within ~3 days,
  instead of waiting for the high days to leave the 7-day window.
- **New normal:** a lasting increase stops being listed once it dominates the median — about 3
  weeks on the weekly grain, 2 months on the monthly one (listed for the month it started and the
  next).
- **Removal:** nothing is removed by hand. The page shows the newest period; a finding disappears
  when a later period no longer clears the bar. The newest period of each grain is re-analysed
  every night, and that run is the whole answer for it: a stored row it no longer flags (a
  baseline that caught up, a rollup now covered by a resource finding, a changed rule) is deleted
  rather than left with old figures. Rows are kept 800 days and reachable via "Earlier".
- The `analyzed` marker stores the baseline windows/months (`BaselineRangesJson`) and the
  `SettledThrough` day, so the page can name the exact dates compared.

**Rollups make the monthly grain affordable.** `DetectCostSpikes-Timer` rolls each newly complete
month into `CostPeriods`, reading one day at a time so memory stays bounded, only when every day
has snapshots. The trailing 7-day windows are computed from `CostSnapshots` directly (35 days), and
every day in that span must have data. The aggregation streams rows into accumulators
(`Measure-DailyDimensionCost`, `Get-ResourceCostMap`): the B2 plan's memory is shared with the
portal.

**The meter grain uses exact category totals.** A per-resource snapshot row carries one label, the
resource's largest meter category that day, so a category built from those labels misses every
charge that is never a resource's largest: a VM's Defender plan counts as "Virtual Machines", and
a Defender plan switched on across many VMs was invisible to the Defender rollup. The ingest
therefore also writes, from the same query and at no extra cost, one total per (day, subscription,
meter category) into `CostSnapshots` partition `cat|yyyy-MM-dd` (resource-attributed cost, the
same basis as the other grains). Every other reader asks for the plain day partition, so these
rows are never summed in. Detection rolls them into the month's `CostPeriods` partition
(`RowKey cat|…`, `Kind = category`; the rollup marker's `Categories` flag) and the trailing weeks
read them per day. The meter grain uses them only when the analysed period and every baseline
period have them; otherwise it keeps the label basis rather than compare two methods. History
stored before this existed is fetched once more (`backfill/history.CategoryTotals`).

## The cost-change pipeline

```
[queue 'cost-tasks', then nightly timers]
  1. INGEST     PlanCostIngest-Timer (hourly + on start-up) queues one task per subscription from
                02:00 UTC; ProcessCostTask-Queue works them one at a time (CostIngest.psm1):
                per-resource query (USD) -> CostSnapshots, and the subscription's complete day
                total (USD + billing currency) -> CostSummary/'dailysub'. The last task sums the
                in-scope subscriptions -> 'dailytotal', 'monthly-sub', PortalConfig/ingest/lastrun.
                Then the one-time history: one calendar month per task, all subscriptions.
  2. DETECT     Find-CostSpike at three dimensions (resource, meter in a subscription,
                subscription); Δ$ AND Δ% over thresholds; ranked by $; rollups already
                explained by the resources under them are dropped (Select-UnexplainedSpike)
  3. LOCALIZE   Get-ResourceContext: Resource Graph -> type, sku, location, tags, owner
  4. EVIDENCE   Get-CostChangeEvidence for the largest findings (EvidenceMaxFindings, default 10):
                  drivers        which meters / resources / services moved, and their share
                  volume vs rate more units, or a higher price per unit
                  changes        Activity Log (90 days) + Resource Graph change history (old -> new)
                  new resources  cost now, none in the baseline
                  owner          owner / cost-centre tags
                  daily shape    how the cost moved within the period, and where it stands now
                                 (state, current daily level, as-of day)
                A meter-category finding exists because no single resource explains it, so it
                breaks down by meter inside the category first; a resource is listed only when it
                carries at least 10% of the rise, and a 'spread' fact says how many resources rose
                and the largest one's share.
                Every fact is numbered (F1, F2, …) and stored on the finding with the evidence
                version (Get-CostEvidenceVersion); older evidence is gathered again on demand.
  5. EXPLAIN    Invoke-CostChangeExplanation: the model reasons only over those facts, cites them,
                and says explained=false when nothing recorded accounts for the change
  6. PERSIST    citation and grounding checks -> CostSpikes
```

`ExplainSpike` runs steps 3–6 on demand for one finding (admin-only).

**One definition of "daily spend".** Charges Azure attributes to no resource (marketplace, support,
most reservation charges) are no resource's cost, but they are part of the day: the ingest counts
every row of the per-resource query in the subscription's day total (`dailysub`), and the tenant's
`dailytotal` is the sum of those, written only for a day every in-scope subscription has reported.
The trend, month figures and brief all read that one series.

**Why a queue.** Cost Management's Query API budget is per tenant: 12 QPU per 10 s, 60 per minute,
600 per hour, one QPU per month of data a request touches. On a CSP tenant the only scope is the
subscription, so a 42-subscription tenant needs 84 requests a night (per-resource + billing
currency). Done inside one timer, that hit the 30-minute function timeout. As queue tasks, each
invocation is one subscription (or one history month), a throttled task goes back on the queue with
the delay Cost Management asks for, and only the tenant quota sets the pace: the nightly run takes
minutes, and a new deployment's history (one QPU per subscription and month) loads in roughly one
to two hours, after which the analysis timers are run once on it (follow-up tasks).
The per-subscription monthly rows are derived from the daily ones instead of a 13-month query per
subscription (about 1,100 QPU a night).

**Timers** run on fixed offsets in UTC: 02:00 ingest (queued; done in minutes) → 02:35 savings → 02:40 detect → 02:45 Advisor
→ 02:50 commitments → 02:55 monthly totals, forecast and budgets, cost scope
(`SyncMonthlyCosts-Timer`) → 03:05 allocation,
statements, per-resource cost → 03:15 brief and findings. Detection works on settled periods and
does not wait for the ingest; it starts at 02:40, after the ingest has normally finished, and a
month is only rolled up (cached for good) once the ingest has reported or the month lies outside
the ingest's rewrite window (`BaselineDays + 2` days). Savings waits up to 5 minutes for the ingest. `functionTimeout` stays at 30
minutes so a timer can't starve the HTTP endpoints.

**Throttling.** The Cost Management Query API is rate-limited per tenant, so per-subscription
queries run sequentially; `Invoke-CostQueryRest` retries 429/5xx honouring `Retry-After`. HTTP
callers pass `-Interactive`, which caps the whole call (3 attempts, ≤15 s backoff, 45 s per
request) and turns a throttle into HTTP 429 + `Retry-After` instead of a hang past App Service's
230-second limit. Table writes are batched (`Set-TableEntityBatch`).

**Retention.** `CostSnapshots`: `SnapshotRetentionDays` (default 180), floored at what the
detectors read. `CostSpikes` and their markers: 800 days. `CostSummary` history: never pruned.

## Tenant cost scope (and CSP / MCA)

Cost Management answers one scope per query. Portal-wide live questions (forecast, Ask's live
path, unused commitments) are asked at:

1. `costQueryScope` (app setting `COST_QUERY_SCOPE`) when set;
2. else the smallest readable **management group** containing every included subscription, found
   nightly (`Find-CoveringManagementGroup`) — **if its cost data covers at least 85% of the
   per-subscription month-to-date**;
3. else per subscription.

**Cost Management does not answer management-group queries for CSP / Microsoft Customer Agreement
subscriptions** — a root management group can see only a small fraction of the spend. Such a group is stored as
`insufficient` and not used. That is why the nightly jobs query each subscription, why the
forecast is then the sum of per-subscription forecasts, and why Ask answers from the stored
per-resource cost first (below).

## The Overview

One page, both periods at once (no tab):

- **Headline figures:** this month so far vs the same days last month; the month-end forecast vs
  the budget that covers the whole portal (Azure's forecast, or a labelled run-rate when Azure's
  covers only part of the spend or is below what is already spent); last month (closed) vs the
  month before; estimated savings open.
- **Savings by priority** and the **key findings** — from the weekly brief (below).
- **Chase list** — spend and open savings per owner, from the brief payload; a row opens what to
  raise and links to the owner's statement. "No owner tag" and deleted resources link to their
  statements too, but carry no savings figure (see the brief's owners, below).
- **Where the money is** — top resource groups, coloured by an environment guess from the name;
  **daily spend** over ~70 days with the period checked for cost changes shaded.

Data: `GetBrief?grain=week` (findings, this month, owners, groups), `GetBrief?grain=month` (last
month's total for its tile), `GetMonthOverview` (forecast, budgets), `GetCostTrend`, `GetSavings`
(statuses). All storage reads.

## Weekly brief and the findings agent

`Brief.psm1` builds the payload deterministically:

- **spend** — this month to date vs the same days last month (`Build-BriefSpend`), with Azure's
  forecast; for the monthly grain, last month vs the month before;
- **changes** — the largest cost changes of the last 7 days **and of last month**, each with
  `period` and its evidence facts;
- **savings** — open certain + likely savings: one per resource; Advisor purchase alternatives
  (1/3-year terms, look-backs) counted once at their best figure; a saving on a resource with no
  cost for the last three settled days is left out (stopped or deleted since Advisor looked);
- **owners** — spend per owner this month and their open savings; the "(untagged)" and other
  placeholder rows carry **no** savings figure, since what is untagged is mostly billing-scope
  purchases that no owner could act on; **resourceGroups** — spend per group with an environment
  guess. Advisor purchase recommendations with no resource behind them are marked
  `billingScope`: a billing-account decision with no owner.

The **findings agent** (`CostAgent.psm1`, `Invoke-AiAgent` in `AiAdapter.psm1`) gets that payload
with names pseudonymised and may call read-only tools, at most 7 model calls per run:

| Tool | What it does |
|---|---|
| `cost_query` | The Ask allowlist (dimensions, timeframes, up to three filters, compare with the previous period, group by owner). Answered from the stored per-resource cost when possible, else Cost Management (named subscriptions, or each subscription when no management group can answer) |
| `change_evidence` | The stored evidence of one cost change |
| `saving_detail` | The stored detail of one saving |

It returns 3–6 findings `{ priority, title, why, owner, monthlyCost, estMonthlySavings, currency,
action, actionScript, refs }`. `Select-InsightFindings` keeps a finding only when its refs exist
(payload ids or tool calls) and every figure in it is in the payload or a tool result; ids, field
names and amounts are taken out of the reader-facing text (`Remove-InsightJargon`); owner tokens
are mapped back. It also enforces what the prompt asks:

- `estMonthlySavings` only when the finding cites a saving, a cost change or a query result
  (S-, A-, C-, Q…), and never on a finding that cites the untagged owner row;
- `monthlyCost` only when it cites a cost (C-, O-, RG-, Q…) — a savings item carries no cost;
- a finding that cites a `billingScope` purchase and talks about a missing owner is dropped; one
  resting only on such purchases shows "Billing account" as its owner;
- a proposed command that quotes the portal's own ids (A-…, RG-3, Q1, OWNER_1) is removed. The tool calls are stored and shown as evidence. Without AI, `Get-RuleFindings`
ranks the same payload by amount (priority by share of last month's spend).

- `BuildBrief-Timer` (03:15): the weekly brief on Mondays (or when missing, older than 7 days, built
  for another scope or by an older version) with the agent; the monthly brief from the 2nd,
  **without AI** — it only feeds the last-month tile.
- `RegenerateBrief` (admin) rebuilds the weekly brief on demand; `GetBrief` serves both.

## Ask

`QueryCosts`:

1. The model translates the question into a small structured spec (schema-constrained). The
   model is **not** given subscription names; code finds the ones the question names
   (`Find-SubscriptionsInText`) and sets them as the subscription filter (`Set-SpecSubscriptions`).
2. **Stored first:** questions about resources, resource groups, subscriptions or owners, this
   month or last month, are answered from `CostSummary`/`resourcecost` (`Invoke-StoredCostQuery`)
   — every subscription, instant, resource-attributed cost only (the answer says so).
3. **Otherwise live and read-only:** at a management group that covers the subscriptions, or
   against the named subscriptions, or each subscription in scope one by one with the rows added
   up (`Invoke-CostQueryAcrossSubscriptions`, 120 s budget; subscriptions that did not answer are
   named in the scope line).
4. The model summarises the rows; `Test-NarrativeGrounding` flags figures not in them. The executed
   query is shown under the answer.

Open to Members (it can only read); every call counts against the daily AI limit.

**In the UI** Ask is a non-modal panel on the right of every page (`components/AskPanel.tsx`,
state in `lib/ask.tsx`), not a page: the floating **Ask** button, Ctrl/⌘+K, a theme's search box
and every "Ask about this" button open it, and the item asked about stays visible beside the
answer. Only its close button or Esc closes it; the conversation survives closing it and
changing pages. Full screen on a phone. `#/ask` links still open the Overview.

## Who spends it (allocation) and statements

`SyncAllocation-Timer` (03:05) rolls the stored per-resource cost up by the **allocation tags**
(deploy parameter `allocationTagKeys`, e.g. "ServiceLead, ProjectName, CostCenter,
Environment"; the first is the owner) and by resource group — this month to the settled day
against the same days of last month. Tags come from Resource Graph as they are now; a resource
without a tag takes its resource group's. It makes **no Cost Management query** and covers
resource-attributed cost only. Tag values are normalised and an optional alias map merges
spelling variants.

The same pass writes:

- **`resourcecost`** — every resource's cost this month, the same days last month, last month and
  the month before, with its owner (`Write-ResourceCostIndex`), for Ask and the agent;
- **monthly statements** per tag value for the last complete month and a partial one for this
  month (`Measure-AllocationStatement`): services, top resources, open savings, 12-month trend,
  tag and resource-group budgets. Untagged, deleted and shared spend are listed separately so the
  statements add up to the bill.
- **statement trend** — each month's spend per tag value, **cumulative by day**
  (`Measure-AllocationDailySeries`, `CostSummary` `statement-daily`, RowKey
  `<yyyy-MM>|<dim>|<part>`): the months the nightly pass reads are rewritten, one older month still
  within snapshot retention is backfilled per night (oldest first, before its snapshots are
  pruned), rows older than 13 months are dropped. `GetStatement` serves up to 12 months and the
  current month so far; each month's bar shows the 1st to the settled day of the current month
  against the rest of that month, so this month compares like for like. A month stored before
  the series existed shows its whole-month total only.

## Savings

`DetectSavings-Timer` writes the app's own findings; `SyncAdvisor-Timer` caches Azure Advisor's
cost recommendations (with term, look-back and reserved resource type for purchases).

- **Tiers:** `certain` (orphaned disks and public IPs), `likely` (a priced change; Advisor rows
  with an amount), `indicative` (listed, never totalled), `not-a-saving` (sustained increases).
  Only certain + likely, open or in progress, are summed.
- **Right-sizing** is priced from the Retail Prices API (CPU average and p95 both low, memory can
  veto; next size down in the family). Reservation-covered VMs save nothing by downsizing.
- **Non-production VMs running around the clock**, **Hot storage holding cold data**, **Log
  Analytics on the wrong tier**, **unused reservation and savings-plan hours** — each priced.
- **One saving per resource** (`Resolve-OverlappingSavings`).
- **Commitments** (`SyncCommitments-Timer`, `GetCommitments`): utilisation, expiry and Azure's
  purchase recommendations.
- **Reservations page** (`SyncCommitments-Timer`, `GetReservations`): which resources used each
  reservation / savings plan over the last 30 days, from amortized cost data (`PricingModel`
  Reservation / SavingsPlan, grouped by `BenefitId` and `ResourceId`), plus its unused cost.
  Stored per commitment in `CostSummary` `commitment-usage`; resources in subscriptions outside
  the portal's scope are summed, not listed. Needs only Cost Management Reader; utilisation and
  expiry still come from the inventory (Reservations Reader).
- **Status** (`SetSavingsStatus`, admin, audited): open / in progress / done / dismissed; a done
  finding counts as realised once its cost has actually fallen.

## Read path

Every page reads Storage tables the timers wrote. Live Azure calls happen only on explicit actions.

| Endpoint | Data source |
|---|---|
| `GetBrief`, `GetMonthOverview`, `GetCostTrend`, `GetCostSpikes`, `GetSavings`, `GetRecommendations`, `GetStatement`, `GetCommitments`, `GetReservations`, `GetPortalConfig` | Storage tables only |
| `SavePortalConfig`, `SetSavingsStatus` | Storage tables (admin, audited) |
| `GetFxRates` | Storage cache (ECB at most every 12 h) + Azure's billing ratio from `dailytotal` |
| `QueryCosts` (Ask) | Stored per-resource cost, else **live** Cost Management, + AI |
| `ExplainSpike` | **Live** Cost Management + Resource Graph + Activity Log + AI, one finding (admin) |
| `RegenerateBrief` | Storage + the findings agent (admin) |
| `health` | Nothing — anonymous, for the platform health check |

## The AI layer

`AiAdapter.psm1` dispatches on `AI_PROVIDER` (`openai` = any OpenAI-compatible endpoint including
Azure OpenAI / Azure AI Foundry; `anthropic` = the Messages API):

- `Invoke-AiCompletion(System, User, Schema)` — one answer, structured output where the provider
  supports it, with an instruct-and-parse fallback; reasoning-model parameters are learned from
  the provider's own 400s.
- `Invoke-AiAgent(System, User, Tools, ToolHandler, Schema, MaxSteps)` — the tool-calling loop for
  both providers; the last step forbids further tool calls; a tool error goes back to the model as
  its result.

**Daily AI limit.** Every model call (each agent step too) is counted against `AiDailyCallLimit`
(`PortalConfig`, default 200 per UTC day, `0` = AI off) before it is made. Over the limit the call
throws `AI_BUDGET_EXCEEDED`: timers fall back to their deterministic output, interactive endpoints
answer 429. Token usage is logged per call; interactive AI actions write an `AuditLog` row.

## Language and currency

The portal's **language** is set per deployment (`deploy.ps1 -Language en|da`, English by
default) and written to `config.json`; there is no picker. The pages read their text from
`src/web-app/src/i18n/` (`en.ts` is the source; `da.ts` is typed against it, so a missing Danish
message fails the build) and format dates and numbers in that language, not the browser's.
On a full deploy the same choice reaches the Function App as `PORTAL_LANGUAGE` (Bicep
`portalLanguage`): `Text.psm1` holds the API's own texts in both languages (savings titles and
details, the no-AI findings, the brief's notes), and the findings, cost-change and Ask prompts get one
line asking for Danish (`Add-AiLanguageLine`). The missing-owner and figure checks read Danish too.
Azure Advisor's texts stay as Azure writes them; operator diagnostics stay English.

**Currency follows the language**: English shows USD (Azure's own USD figures), Danish shows
DKK. Totals are stored in USD and the billing currency; per-resource figures in USD. When the
tenant is billed in DKK, DKK is shown as billed, and USD-only figures are converted with
**Azure's own ratio** (billed total ÷ USD total over recent days, `Get-BillingCurrencyRate`). On
any other bill DKK is converted at the ECB rate (`Fx.psm1`) and labelled approximate; without a
rate the page stays in USD. Findings carry their own currency: USD for payload figures, the
billing currency for figures from a cost query.

## Cost basis: amortized

Every analysis query uses **`AmortizedCost`**, so a reservation or savings-plan purchase is spread
over its term and attributed to the resources that used it. `PortalConfig` `CostType` switches a
deployment to `ActualCost` for invoice tie-out; the next ingest then rebuilds the 90-day
`dailytotal` history on the new basis. One deliberate exception: reservation display-name
resolution (`ResourceNames.psm1`) stays on `ActualCost`, because it reads purchase rows that
`AmortizedCost` does not produce.

## Web app and themes

React 18, Fluent UI v9 and Recharts, built by Vite to static files; `config.json` (API address,
product name, theme) is written at deploy time, so one build serves every deployment. Pages:
Overview, Savings, Reservations, Statements, Cost changes; every page and filter is in the URL. Ask
is a panel over any page, not a page.

The look is a **theme**: a folder under `src/web-app/src/themes/<id>/` with `index.ts` (Fluent
theme, palette for colours drawn in code, shell), `Shell.tsx` (header, navigation, footer) and
`theme.css` scoped to `html.theme-<id>`. `registry.ts` finds the folders at build time, so a theme
is removed by deleting its folder. Pages use only the shared `fo-*` classes and the palette. See
[THEMES.md](../THEMES.md).
