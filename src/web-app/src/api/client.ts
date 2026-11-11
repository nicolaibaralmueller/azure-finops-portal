// API client. The base URL is loaded at RUNTIME from /config.json (written at deploy
// time), NOT baked at build time — so one Vite build is tenant-agnostic and can deploy
// into any customer's subscription.

type AppConfig = {
  apiBaseUrl: string
  /**
   * The name shown in the banner and the browser tab. Set per deployment (deploy.ps1
   * -ProductName) so a customer can call it what they call it; a neutral default otherwise.
   */
  productName?: string
  /** The look: a folder name under src/themes/ (deploy.ps1 -Theme). Default when absent. */
  theme?: string
  /** The language: 'en' (default) or 'da' (deploy.ps1 -Language). Currency follows it. */
  language?: string
}

const DEFAULT_PRODUCT_NAME = 'FinOps Portal'
let config: AppConfig = { apiBaseUrl: '' }

// Call once before the first render (see main.tsx).
export async function loadConfig(): Promise<void> {
  try {
    const res = await fetch('config.json', { cache: 'no-store' })
    config = await res.json()
  } catch {
    config = { apiBaseUrl: '' }
  }
}

export function apiBaseUrl(): string {
  return config.apiBaseUrl
}

export function configuredTheme(): string | null {
  return config.theme?.trim() || null
}

export type Language = 'en' | 'da'
export function configuredLanguage(): Language {
  return config.language?.trim().toLowerCase() === 'da' ? 'da' : 'en'
}

export function productName(): string {
  const n = config.productName?.trim()
  return n ? n.slice(0, 60) : DEFAULT_PRODUCT_NAME
}

// EasyAuth: the portal is fronted by App Service Authentication, and the access token for
// the (separately authenticated) Function App API is in the portal's token store. We read it
// from /.auth/me and send it as a Bearer token. In public mode (no auth configured) /.auth/me
// returns nothing, this is a no-op, and the API is open.
let cachedToken: string | null = null

async function fetchAccessToken(): Promise<string | null> {
  try {
    const res = await fetch('/.auth/me', { credentials: 'include' })
    if (!res.ok) return null
    const data = await res.json()
    return data?.[0]?.access_token ?? null
  } catch {
    return null
  }
}

async function authHeaders(): Promise<Record<string, string>> {
  if (!cachedToken) cachedToken = await fetchAccessToken()
  return cachedToken ? { Authorization: `Bearer ${cachedToken}` } : {}
}

// Display name of the signed-in user (from EasyAuth), or null in public mode.
export async function getCurrentUserName(): Promise<string | null> {
  try {
    const res = await fetch('/.auth/me', { credentials: 'include' })
    if (!res.ok) return null
    const data = await res.json()
    const claims: { typ: string; val: string }[] = data?.[0]?.user_claims ?? []
    return (
      claims.find((c) => c.typ === 'name')?.val ??
      claims.find((c) => c.typ === 'preferred_username')?.val ??
      data?.[0]?.user_id ??
      null
    )
  } catch {
    return null
  }
}

// EasyAuth sign-out endpoint (clears the session, then returns to the portal root).
export const LOGOUT_URL = '/.auth/logout?post_logout_redirect_uri=/'

/**
 * A failed API call. `message` keeps the historical "<path> -> <status>: <error>" shape that
 * callers match on; `status` and `body` carry the details (some error responses — a 429 from
 * the AI limit, say — still include useful data such as freshly gathered evidence).
 */
export class ApiError extends Error {
  status: number
  body: unknown
  constructor(message: string, status: number, body: unknown) {
    super(message)
    this.status = status
    this.body = body
  }
  /** The server's own (already sanitized) error sentence, if it sent one. */
  get serverMessage(): string | null {
    const e = (this.body as { error?: unknown } | null)?.error
    return typeof e === 'string' && e ? e : null
  }
}

async function call<T>(path: string, init?: RequestInit): Promise<T> {
  const doFetch = async () => {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      ...(await authHeaders()),
      ...((init?.headers as Record<string, string>) ?? {}),
    }
    return fetch(`${apiBaseUrl()}${path}`, { ...init, headers })
  }

  let res = await doFetch()
  // Token likely expired — refresh the EasyAuth token store once and retry.
  if (res.status === 401 && cachedToken) {
    cachedToken = null
    try { await fetch('/.auth/refresh', { credentials: 'include' }) } catch { /* ignore */ }
    res = await doFetch()
  }
  if (!res.ok) {
    // Include the server's own (already sanitized) message — the API returns
    // { error, correlationId }. The status code stays first because callers match on it
    // ('403' → admin-only, '409' → AI not configured, '429' → throttled).
    let detail = ''
    let body: unknown = null
    try {
      body = await res.json()
      const e = (body as { error?: unknown })?.error
      if (typeof e === 'string') detail = `: ${e}`
    } catch { /* non-JSON error body */ }
    throw new ApiError(`${path} -> ${res.status}${detail}`, res.status, body)
  }
  return res.json() as Promise<T>
}

// ---- Response shapes (mirror the Function App projections) ----

/**
 * `usd` is Azure's own USD normalization, and is what every cross-currency total is summed in.
 * `billing` is the same figure in the tenant's billing currency, straight from Cost Management
 * with no conversion — present only when the whole tenant bills in one currency. Prefer it for
 * display when it matches the selected currency: converting `usd` back with ECB rates lands
 * ~1.4% away from what the Azure blade shows, and drifts daily even for closed months.
 */
export type TrendPoint = { date: string; usd: number; billing?: number | null; currency?: string | null }


export type CostTrendResponse = { points: TrendPoint[]; count: number; days: number }



export type FxRatesResponse = {
  base: 'USD'
  /** USD -> currency multipliers, or null when no rates could be fetched (UI stays USD). */
  rates: Record<string, number> | null
  asOf: string | null
  source: string | null
  /**
   * The tenant's billing currency and Azure's own USD->billing ratio (from the stored daily
   * totals). Null when the tenant bills in more than one currency or nothing is stored yet.
   */
  billing?: { currency: string; rate: number; days: number } | null
}

export type Confidence = 'low' | 'medium' | 'high'

/**
 * Grain a spike was detected at. 'resource' is one resource; the rollups catch an increase
 * spread across many resources, none of which moved enough to be flagged on its own. Rollups
 * are de-duplicated server-side against the resource spikes underneath them.
 */
export type SpikeDimension = 'resource' | 'meter' | 'subscription'

/** Grain detection runs at. Daily was removed — this is analysis, not alerting. */
export type PeriodType = 'week' | 'month'

/**
 * One numbered piece of evidence about a cost change (CostEvidence.psm1). The written
 * explanation cites these by id. Amounts are USD; the page renders them in the display currency.
 */
export type EvidenceFact =
  | {
      id: string
      kind: 'driver'
      /** meter (inside one resource) | resource (inside a meter category) | service (inside a subscription) */
      driverKind: 'meter' | 'resource' | 'service'
      direction: 'increase' | 'decrease'
      name: string
      resourceId?: string | null
      resourceName?: string | null
      currentUsd: number
      baselineUsd: number
      deltaUsd: number
      /** Share of the gross increase, increases only. */
      sharePct?: number | null
      isNew: boolean
      stopped: boolean
      /** Present when usage quantities were available on both sides. */
      quantityChangePct?: number | null
      unitPriceChangePct?: number | null
      volumeUsd?: number | null
      rateUsd?: number | null
    }
  | { id: string; kind: 'volume-rate'; volumeUsd: number; rateUsd: number; newOrStoppedUsd: number; netDeltaUsd: number }
  | {
      id: string
      kind: 'daily-shape'
      /** The level the period ended at (last 7 days), scaled to a whole period. */
      exitRunRateUsd: number
      /** The period ended at a level that would not be flagged. */
      resolved: boolean
      steppedDownOn?: string | null
      dailyBeforeUsd?: number | null
      dailyAfterUsd?: number | null
      /** Where it stands now: the mean of the latest settled days, as of currentAsOf. */
      state?: FindingState | null
      currentDailyUsd?: number | null
      currentAsOf?: string | null
    }
  /** The rise is spread over resourceCount resources; the largest carries topSharePct % of it. */
  | { id: string; kind: 'spread'; resourceCount: number; topSharePct: number; grossIncreaseUsd: number }
  | { id: string; kind: 'new-resource'; resourceId: string; name: string; resourceName?: string | null; currentUsd: number }
  | {
      id: string
      kind: 'property-change'
      /** 'yyyy-MM-ddTHH:mmZ' */
      time: string
      resourceId: string
      resourceName?: string | null
      changeType: 'create' | 'delete' | 'update'
      path?: string | null
      from?: string | null
      to?: string | null
    }
  | {
      id: string
      kind: 'change'
      time: string
      resourceId: string
      resourceName?: string | null
      operation: string
      /** 'created or updated' | 'deleted' | an action name such as 'start' or 'deallocate' */
      action: string
      /** Pseudonymous actor, e.g. 'user_3fa2'. */
      actor: string
      count: number
    }
  | { id: string; kind: 'owner'; tags: Record<string, string> }

export type CostChangeEvidence = {
  version: number
  dimension: SpikeDimension
  /** One sentence stating what the evidence compares against. */
  basis: string
  currentStart: string
  currentEnd: string
  baselineStart: string | null
  baselineEnd: string | null
  baselinePeriods: number
  costType: string
  currentUsd: number | null
  baselineUsd: number | null
  netDeltaUsd: number | null
  facts: EvidenceFact[]
  /** False = some step could not run (throttled, time budget, ...); see notes. */
  complete: boolean
  notes: string[]
  gatheredAt: string
}

/** 'complete' | 'partial' | 'skipped' (outside the per-run limit) | 'none' (not gathered / older row) */
export type EvidenceStatus = 'complete' | 'partial' | 'skipped' | 'none'

export type ExplanationStatus =
  | 'explained' | 'reused' | 'no-evidence' | 'not-configured' | 'budget-exceeded' | 'skipped' | 'failed' | ''

export type CostSpike = {
  id: string
  /** Period key: '2026-07' for a month, '2026-W31' for an ISO week. */
  period: string
  periodType: PeriodType
  periodStart: string
  periodEnd: string
  dimension?: SpikeDimension | null
  scope: string
  /** Subscription display name for `scope`, when it could be resolved. */
  scopeName?: string | null
  /** Owner / cost centre / environment / application / resource group (resource-level changes only). */
  allocation?: Record<string, string> | null
  /** Rollups only: the part of the increase not attributable to a flagged resource. */
  unexplainedUsd?: number | null
  resourceId: string
  resourceName?: string | null
  meter: string
  baselineUsd: number
  spikeUsd: number
  deltaUsd: number
  deltaPct: number | null
  isNew: boolean
  /** The increase has already fallen back below the bar (same as state === 'resolved'). */
  resolved?: boolean
  /**
   * Where the finding stands NOW, from the mean of the latest settled days (`currentDailyUsd`):
   * 'resolved' = that level would no longer be flagged; 'decreasing' = still above the bar but
   * clearly below the period's average; 'open' otherwise.
   */
  state?: FindingState
  /** Mean daily cost over the latest settled days, up to `currentAsOf`. USD. */
  currentDailyUsd?: number | null
  currentAsOf?: string | null
  /** How far the daily cost has fallen (negative %) from `fallFromDailyUsd` to `currentDailyUsd`. */
  fallPct?: number | null
  fallFromDailyUsd?: number | null
  /** The day the fall started (the step down); null = measured against the period's average day. */
  fallSince?: string | null
  /** The level the period ended at (its last days), scaled to a whole period. */
  exitRunRateUsd?: number | null
  /** The day the daily cost stepped down within the period, when it did. */
  steppedDownOn?: string | null
  /** How many of the baseline periods the key had cost in (the "typical" figure rests on these). */
  baselinePeriods?: number | null
  baselinePeriodsOf?: number | null
  /** 'usage' (genuine anomaly) or 'reservation-installment' (recurring monthly purchase). */
  kind?: 'usage' | 'reservation-installment' | null
  /** Written explanation, produced from `evidence`. Empty when there is none. */
  headline: string | null
  cause: string | null
  recommendation: string | null
  /** Evidence fact ids the explanation relies on. */
  citedFacts?: string[]
  /** True only when the cited evidence accounts for the change. */
  explained?: boolean
  explanationStatus?: ExplanationStatus
  grounded: boolean
  evidence?: CostChangeEvidence | null
  evidenceStatus?: EvidenceStatus
  status: string
  detectedAt: string
}

export type CostSpikesResponse = {
  spikes: CostSpike[]
  count: number
  periodType: PeriodType
  /** null = no complete period of this grain exists yet. */
  period: string | null
  periodStart: string | null
  periodEnd: string | null
  /** False = this period hasn't been analysed yet (as opposed to analysed and clean). */
  analyzed: boolean
  /**
   * Why it wasn't analysed. 'pending' = the run hasn't happened; the others will NOT resolve
   * on the next nightly run and `detail` says what they're waiting for instead.
   */
  reason?: 'pending' | 'insufficient-history' | 'needs-baseline' | 'no-data' | 'not-covered' | null
  /** A ready-to-show sentence explaining `reason`. */
  detail?: string | null
  /** The bar a change had to clear to be listed — both must be met. USD. */
  minDeltaUsd?: number | null
  /** …and this percentage above the period's own baseline. */
  minDeltaPct?: number | null
  /** The windows (weekly) or months whose MEDIAN is the "typical" level, oldest first. */
  baselineRanges?: { start: string; end: string }[]
  /** How many prior periods form the baseline (4 weeks / 3 months). */
  baselineCount?: number
  /** Days excluded at the end because Azure still restates them (data runs to D-n). */
  settlingDays?: number
  /** Newest settled day the "current level" of each finding is measured to. */
  settledThrough?: string | null
  /** When the nightly detection last analysed this period (ISO). */
  analyzedAt?: string | null
}

export type FindingState = 'open' | 'decreasing' | 'resolved'

/** Result of gathering evidence (if needed) and explaining one stored cost change. */
export type ExplainSpikeResponse = {
  id: string
  explanationStatus: ExplanationStatus
  /** A sentence for the user when there is no new explanation (not configured, no evidence). */
  message: string | null
  headline: string | null
  cause: string | null
  recommendation: string | null
  citedFacts: string[]
  explained: boolean
  grounded: boolean
  evidence: CostChangeEvidence | null
  evidenceStatus: EvidenceStatus
}

export type Recommendation = {
  id: string
  resourceId: string
  resourceName?: string | null
  subscriptionName?: string | null
  allocation?: Record<string, string> | null
  impact: string
  problem: string
  solution: string
  recommendationType: string
  currentSku: string
  targetSku: string
  region: string
  /** Advisor's own figure, in `currency` — the authoritative number. */
  savingsAmount: number
  /** Advisor reports in the BILLING currency, which is often not USD. */
  currency: string
  /** USD equivalent — only meaningful when `converted` is true, else 0. */
  estMonthlySavingsUsd: number
  /** False = no FX rate for `currency`; the row is excluded from USD totals. */
  converted: boolean
  /** No longer written (AI rewording removed); older rows may still carry text. */
  narrative?: string
  grounded?: boolean
}

export type RecommendationsResponse = {
  recommendations: Recommendation[]
  count: number
  /** Sums converted rows only — a EUR amount is never added to a USD one. */
  totalMonthlySavingsUsd: number
  /** >0 = the total leaves out this many findings (no rate for their currency). */
  unconvertedCount: number
  lastRun: string | null
}

/** What the user was looking at when they chose "Ask about this". All fields optional. */
export type AskContext = {
  kind: 'cost-change' | 'saving' | 'subscription' | 'commitment'
  title: string
  subscriptionId?: string | null
  subscriptionName?: string | null
  resourceId?: string | null
  resourceName?: string | null
  meter?: string | null
  periodStart?: string | null
  periodEnd?: string | null
  /** Short plain-text summary of the item (figures in USD). */
  summary?: string | null
}

/** An earlier turn, sent back so a follow-up question can build on it. */
export type AskHistoryTurn = { question: string; spec: unknown; answer: string }

export type QueryComparison = {
  currentFrom: string
  currentTo: string
  previousFrom: string
  previousTo: string
  /** True = billing months were approximated by calendar months. */
  approximate: boolean
}

export type QueryCostsResponse = {
  answer: string
  /** False = the answer quotes a figure that is not in the rows it was given. */
  grounded?: boolean
  /** True = the query ran but the daily AI limit stopped the written answer. */
  aiLimitReached?: boolean
  /** The structured spec the question was translated into (send back for follow-ups). */
  spec: unknown
  query: unknown
  /** Which scope the query ran against, in words. */
  scope?: string
  comparison?: QueryComparison | null
  columns?: string[]
  rows: Record<string, unknown>[]
  rowCount: number
}

// ---- Executive brief (Brief.psm1) ----
export type BriefMonthSpend = {
  month: string
  throughDay: number
  usd: number
  billing: number | null
  currency: string | null
  days: number
  /** Days counted (1..throughDay) — for "days missing", not for pace. */
  expectedDays: number
  /** Calendar length of the month; absent on rows stored before 2026-09-21. */
  daysInMonth?: number
  complete: boolean
}
export type BriefSpend = {
  kind: 'month-to-date' | 'complete-month'
  month: string
  throughDate: string
  current: BriefMonthSpend
  previousSamePeriod?: BriefMonthSpend
  previousMonth: BriefMonthSpend
  changeVsPreviousPct: number | null
  /** Straight-line: this month's daily average so far x days in the month. */
  runRateUsd?: number | null
  runRateBilling?: number | null
  runRateVsPreviousMonthPct?: number | null
}
export type BriefFact = {
  kind: string
  driverKind?: string
  name?: string
  resourceName?: string
  deltaUsd?: number
  sharePct?: number
  quantityChangePct?: number
  unitPriceChangePct?: number
  isNew?: boolean
  time?: string
  action?: string
  operation?: string
  path?: string
  from?: string
  to?: string
}
export type BriefChange = {
  id: string
  findingId: string
  dimension: SpikeDimension
  name: string
  resourceId: string
  subscription: string
  currentUsd: number
  baselineUsd: number
  deltaUsd: number
  deltaPct: number | null
  isNew: boolean
  explained: boolean
  cause: string | null
  facts: BriefFact[]
  /** the owner tag of the resource ('' when untagged, a rollup, or not recorded) */
  owner?: string
  /** 'last 7 days' | 'last month' — which analysis found it */
  period?: string
  /** Where the stored finding lives: '<week|month>|<period key>' — for a link to it. */
  periodKey?: string
}
export type BriefSaving = {
  id: string
  source: 'analysis' | 'advisor'
  category: string
  title: string
  detail: string
  resourceId: string
  resourceName: string
  subscription: string
  confidence: string
  monthlyUsd: number
  /** the owner tag of the resource ('' when untagged or not a resource) */
  owner?: string
}
/** Spend per owner this month (to the settled day) and the open savings that are theirs. */
export type BriefOwner = {
  id: string
  owner: string
  currentUsd: number
  previousSameDaysUsd: number
  previousMonthUsd: number
  deltaPct: number | null
  sharePct: number
  resources: number
  /** null on rows without an owner tag: their savings can't be traced to an owner */
  openSavingsUsd: number | null
  openSavingsCount: number | null
}
/** Spend per resource group this month, with a guess at its environment from the name. */
export type BriefResourceGroup = {
  id: string
  name: string
  subscription: string
  subscriptionId: string
  environment: 'non-production' | 'production' | 'unknown'
  currentUsd: number
  previousSameDaysUsd: number
  previousMonthUsd: number
  deltaPct: number | null
  sharePct: number
  resources: number
}
export type BriefPayload = {
  version: number
  grain: PeriodType
  spend: BriefSpend & { forecastUsd?: number | null; forecastVsPreviousMonthPct?: number | null }
  changes: { periodType: PeriodType; period: string | null; periodStart: string | null; periodEnd: string | null; total: number; items: BriefChange[] }
  savings: { totalMonthlyUsd: number; count: number; unconvertedCount: number; items: BriefSaving[] }
  owners?: BriefOwner[]
  resourceGroups?: BriefResourceGroup[]
  notes: string[]
}
/**
 * One key finding. Amounts are in `currency`: 'USD' for figures from the payload, the billing
 * currency for figures the agent read from a cost query. `refs` are payload ids (C-, S-, A-, O-,
 * RG-) and tool-call refs (Q1 …). `actionScript` is a proposal for a person; nothing runs it.
 */
export type Finding = {
  id: string
  priority: 1 | 2 | 3
  title: string
  why: string
  owner: string
  /** rests only on billing-account purchases (reservations / savings plans): no owner applies */
  billingScope?: boolean
  monthlyCost: number | null
  estMonthlySavings: number | null
  currency: string
  action: string
  actionScript: string
  refs: string[]
}
export type ToolCall = { ref: string; tool: 'cost_query' | 'change_evidence' | 'saving_detail' | string; args: string; summary: string }
export type BriefAi = {
  summary: string
  findings: Finding[]
  toolCalls: ToolCall[]
  /** findings the checks dropped (uncited, or a figure not in the data) */
  dropped: number
  model?: string
}
export type BriefDocument = {
  grain: PeriodType
  generatedAt: string
  generatedAtIso: string
  payload: BriefPayload
  ai: BriefAi | null
  /** The same payload ranked by amount — shown when there are no AI findings. */
  ruleFindings?: Finding[]
  aiStatus: 'explained' | 'reused' | 'not-configured' | 'budget-exceeded' | 'failed'
  grounded: boolean
}
export type BriefResponse = { grain: PeriodType; available: boolean; canRegenerate: boolean; brief: BriefDocument | null }

// ---- Overview month view (GetMonthOverview) ----
export type MonthBudget = {
  name: string
  scopeName: string
  timeGrain: string
  amount: number
  spent: number
  /** Azure reports a budget in its own currency; never mix it with other figures. */
  currency: string
  usedPct: number | null
  forecast: number | null
  /** True = Azure's own budget forecast lands above the budget before the period ends. */
  projectedToExceed: boolean
  endDate: string
  /** True = it measures everything the portal covers, so it may speak for the month. */
  coversPortal?: boolean
}
export type MonthOverviewResponse = {
  /** Month-to-date, same days last month, last month's total, run-rate. Null before the first ingest. */
  spend: BriefSpend | null
  month: string | null
  settledThrough: string | null
  costType: string | null
  /** Azure's own month-end projection; `source: 'none'` = unavailable, use the run-rate. */
  forecast: {
    usd: number | null; billing: number | null; currency: string; note: string; source: 'azure' | 'none'
    /** how the forecast covers the subscriptions: one management-group query, a per-subscription sum, or a sum missing a few small ones */
    coverage?: 'scope' | 'per-subscription' | 'partial' | 'none'
  }
  budgets: MonthBudget[]
  /** e.g. management-group budgets hidden while a subscription scope is set */
  budgetNote?: string
  /** the subscription scope changed; the totals are rebuilt on the next nightly run */
  scopePending?: boolean
  savings: {
    totalMonthlyUsd: number
    count: number
    unconvertedCount: number
    /** Monthly savings already banked this month (findings marked done whose cost then fell). */
    realisedThisMonthUsd?: number
    top: BriefSaving[]
  } | null
  lastSynced: string | null
  ready: boolean
}

export type PortalConfig = {
  aiProvider?: string | null
  aiModel?: string | null
  aiConfigured: boolean
  aiDailyCallLimit?: number | null
  aiCallsToday?: number | null
  canEdit: boolean
  /** Which subscriptions the portal covers — set by Setup/Set-SubscriptionScope.ps1, read-only here. */
  subscriptionScope?: SubscriptionScope
  /** the tags that say who owns spend (normalised: 'owner', 'costcenter', …) */
  allocationTagKeys?: string[]
  /** Display names for them, from the names as configured ('servicelead' -> 'Service lead'). */
  allocationTagLabels?: Record<string, string>
}

export type SubscriptionScope = {
  /** true = every subscription the portal's identity can see */
  all: boolean
  /** Only those the portal's identity can read (seen at the last ingest). */
  included: { id: string; name: string }[]
  /** how many the identity can see; null before the first ingest */
  total: number | null
  /** the scope changed and the totals are rebuilt on the next nightly run */
  pending: boolean
}

/**
 * What a figure is worth, and therefore whether it is added up:
 * - `certain`      measured waste — an orphan's own cost, not an estimate of a change
 * - `likely`       a priced change with a known before and after (right-sizing, Advisor)
 * - `indicative`   shown but never totalled (no published price, or a reservation already
 *                  pays for it, so downsizing saves nothing until that is changed)
 * - `not-a-saving` a sustained cost increase: money now being spent, reported on Cost changes
 */
export type SavingsTier = 'certain' | 'likely' | 'indicative' | 'not-a-saving'

export type SavingsStatus = 'open' | 'in-progress' | 'done' | 'dismissed'

export type SavingsFinding = {
  id: string
  category: string
  tier: SavingsTier
  status: SavingsStatus
  statusReason?: string
  statusBy?: string
  statusAt?: string
  /** Set once the money actually stopped (the finding vanished or its figure halved). */
  realisedUsd?: number | null
  realisedAt?: string
  /** True = dismissed earlier, but the figure has since moved by more than half. */
  reopened?: boolean
  resourceId: string
  resourceName?: string | null
  subscriptionName?: string | null
  /** Owner / cost centre / environment / application / resource group, tags as they are now. */
  allocation?: Record<string, string> | null
  resourceType: string
  sku: string
  location: string
  title: string
  detail: string
  /** No longer written (AI rewording removed); older rows may still carry text. */
  narrative?: string
  grounded?: boolean
  estMonthlySavingsUsd: number
  confidence: Confidence
  evidence: Record<string, unknown>
}

export type SavingsResponse = {
  findings: SavingsFinding[]
  count: number
  /** Sustained cost increases — not savings; the Cost changes page shows these. */
  increases: SavingsFinding[]
  /** Certain + likely, open or in progress: what is genuinely still on the table. */
  totalMonthlySavingsUsd: number
  certainMonthlyUsd: number
  likelyMonthlyUsd: number
  /** Listed, deliberately not added to the total. */
  indicativeCount: number
  dismissedCount: number
  realisedThisMonthUsd: number
  canSetStatus: boolean
  lastRun: string | null
}

export type SetSavingsStatusResponse = {
  id: string
  status: SavingsStatus
  reason: string
  amountAtStatusUsd: number
  setBy: string
  setAt: string
  note: string
}


// ---- Monthly statement per owner / cost centre (GetStatement) ----
export type StatementIndexRow = {
  key: string
  label: string
  totalUsd: number
  previousUsd: number
  deltaUsd: number
  deltaPct: number | null
  /** Share of the billed total (of the resource-attributed total when the bill is unknown). */
  sharePct: number
  resources: number
  openSavingsUsd: number
  savingsCount: number
  /** Untagged, gone or unreadable — listed apart from the owners, never spread across them. */
  separate: boolean
  /** Azure budgets filtered to this value (current month only). */
  budgets?: StatementBudget[]
}
/** An Azure budget with a tag filter, as Azure reports it (its own currency and period). */
export type StatementBudget = {
  name: string
  scopeName: string
  currency: string
  timeGrain: string
  amount: number
  spent: number
  usedPct: number | null
  projectedToExceed: boolean
  /** The budget has further filters (other values, dimensions), so it covers more or less than this value alone. */
  extraFilters: boolean
}
export type StatementReconciliation = {
  billedUsd: number | null
  attributedUsd: number
  attributedPreviousUsd: number
  /** Billed minus resource-attributed: marketplace, support, reservation and savings-plan purchases. */
  sharedUsd: number | null
  sharedPct: number | null
}
export type Statement = StatementIndexRow & {
  byService: { name: string; usd: number; previousUsd: number }[]
  topResources: { resourceId: string; usd: number; previousUsd: number; deltaUsd: number }[]
  savings: { id: string; title: string; resourceId: string; resourceName: string; monthlyUsd: number; source: string; tier: string }[]
  /** On the untagged statement: the resource groups holding most of it (tagging a group tags its resources). */
  untaggedGroups?: { resourceGroupId: string; name: string; usd: number; resources: number }[]
  /** This value's total per trend month (null = no spend that month, or the current month). */
  trend?: (number | null)[]
  /** This value's spend from the 1st to `trend.throughDay` of each trend month (null = no daily data). */
  trendSameDays?: (number | null)[]
}
export type StatementResponse = {
  ready: boolean
  month?: string
  previousMonth?: string | null
  /** true = the current month so far, compared with the same days of the previous month. */
  partial?: boolean
  throughDate?: string | null
  months: { month: string; partial: boolean }[]
  /** Share of resource-attributed spend with a real value for this tag. */
  coveragePct?: number | null
  /**
   * Up to 12 complete months and the current month so far, oldest first. series = each value's
   * whole-month total (null for the current month); sameDays = the 1st to throughDay (the settled
   * day of the current month) in each month that has a daily series.
   */
  trend?: {
    months: string[]
    series: Record<string, (number | null)[]>
    sameDays?: Record<string, (number | null)[]>
    throughDay?: number | null
    partialMonth?: string | null
  }
  /** 'tag:owner', 'tag:costcenter', … */
  dimension?: string
  dimensions: string[]
  tagLabels?: Record<string, string>
  rows?: StatementIndexRow[]
  reconciliation?: StatementReconciliation | null
  complete?: boolean
  daysCovered?: number
  daysInMonth?: number
  lastSynced?: string | null
  scopePending?: boolean
  statement?: Statement | null
}

export type CommitmentItem = {
  kind: 'reservation' | 'savings plan'
  id: string
  name: string
  sku: string
  quantity: number | null
  commitment: { amount: number | null; currency: string; grain: string } | null
  term: string
  appliedScope: string
  renew: boolean
  expiryDate: string | null
  daysToExpiry: number | null
  expiringSoon: boolean
  utilisation7d: number | null
  utilisation30d: number | null
}
export type CommitmentRecommendation = {
  kind: 'reservation' | 'savings plan'
  subscriptionId: string
  subscriptionName: string
  description: string
  term: string
  quantity: number | null
  hourlyCommitment: number | null
  monthlySavingsUsd: number
  /** what the covered usage costs with the commitment, as % of pay-as-you-go */
  effectiveCostPct: number | null
  lookback: string
}
export type CommitmentsResponse = {
  ready: boolean
  inventory: CommitmentItem[]
  recommendations: CommitmentRecommendation[]
  notes: string[]
  lastSynced: string | null
}


/** One resource that used a commitment over the last 30 days (amortized cost, USD). */
export type CommitmentResource = {
  resourceId: string
  subscriptionId: string
  subscriptionName: string
  resourceGroup: string
  name: string
  cost30dUsd: number
  cost7dUsd: number
  quantity30d: number
  /** share of the commitment's used cost */
  sharePct: number
  lastUsed: string | null
  /** days with usage */
  days: number
}
export type ReservationItem = Omit<CommitmentItem, 'kind'> & {
  kind: 'reservation' | 'savings plan' | 'commitment'
  location: string
  /** false = seen in cost data only (no Reservations Reader role, or ended recently) */
  inInventory: boolean
  /** 'unknown' = seen in cost data only */
  status: 'active' | 'cancelled' | 'expired' | 'unknown'
  hasUsageData: boolean
  used30dUsd: number | null
  used7dUsd: number | null
  /** Usage hours / units covered over 30 and 7 days. Null on data synced before they were stored. */
  quantity30d?: number | null
  quantity7d?: number | null
  /** Azure reported 0 for the covered cost while the usage is real (seen on CSP tenants). */
  costHidden?: boolean
  /** null = not available at the scope the portal could query */
  unused30dUsd: number | null
  unused7dUsd: number | null
  lastUsed: string | null
  resourceCount: number
  resources: CommitmentResource[]
  /** resources in subscriptions outside the portal's scope, summed */
  otherSubscriptions: { count: number; cost30dUsd: number; sharePct: number } | null
}
export type ReservationsResponse = {
  ready: boolean
  items: ReservationItem[]
  /** cost data was asked per subscription (no management group), so unused hours may be missing */
  perSubscription: boolean
  days: number
  notes: string[]
  lastSynced: string | null
}

// One method per Function App endpoint (see src/function-app/*).
export const FinOpsApi = {
  getCostTrend: (days: number) => call<CostTrendResponse>(`/GetCostTrend?days=${days}`),
  getFxRates: () => call<FxRatesResponse>('/GetFxRates'),
  /** offset 0 = latest complete period of that grain, 1 = the one before it, … */
  /** `key` = one exact period (week: its last day yyyy-MM-dd, month: yyyy-MM); otherwise `offset` back from the newest. */
  getCostSpikes: (periodType: PeriodType = 'week', offset = 0, key?: string) =>
    call<CostSpikesResponse>(`/GetCostSpikes?periodType=${periodType}&offset=${offset}${key ? `&key=${encodeURIComponent(key)}` : ''}`),
  getRecommendations: () => call<RecommendationsResponse>('/GetRecommendations'),
  getSavings: (includeDismissed = false) =>
    call<SavingsResponse>(`/GetSavings${includeDismissed ? '?includeDismissed=true' : ''}`),
  setSavingsStatus: (id: string, status: SavingsStatus, reason = '') =>
    call<SetSavingsStatusResponse>('/SetSavingsStatus', { method: 'POST', body: JSON.stringify({ id, status, reason }) }),
  // periodType+period identify the partition — passing them turns a scan into a point read.
  explainSpike: (spikeId: string, periodType?: PeriodType, period?: string, refreshEvidence = false) =>
    call<ExplainSpikeResponse>('/ExplainSpike', {
      method: 'POST',
      body: JSON.stringify({ spikeId, periodType, period, refreshEvidence }),
    }),
  queryCosts: (question: string, history: AskHistoryTurn[] = [], context: AskContext | null = null) =>
    call<QueryCostsResponse>('/QueryCosts', { method: 'POST', body: JSON.stringify({ question, history, context }) }),
  getMonthOverview: () => call<MonthOverviewResponse>('/GetMonthOverview'),
  getCommitments: () => call<CommitmentsResponse>('/GetCommitments'),
  getReservations: () => call<ReservationsResponse>('/GetReservations'),
  getStatement: (q: { month?: string; dimension?: string; value?: string } = {}) => {
    const p = new URLSearchParams()
    if (q.month) p.set('month', q.month)
    if (q.dimension) p.set('dimension', q.dimension)
    if (q.value) p.set('value', q.value)
    const qs = p.toString()
    return call<StatementResponse>(`/GetStatement${qs ? `?${qs}` : ''}`)
  },
  getBrief: (grain: PeriodType) => call<BriefResponse>(`/GetBrief?grain=${grain}`),
  regenerateBrief: (grain: PeriodType) =>
    call<BriefResponse>('/RegenerateBrief', { method: 'POST', body: JSON.stringify({ grain }) }),
  getPortalConfig: () => call<PortalConfig>('/GetPortalConfig'),
  savePortalConfig: (cfg: unknown) =>
    call('/SavePortalConfig', { method: 'POST', body: JSON.stringify(cfg) }),
}
