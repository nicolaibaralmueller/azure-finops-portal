import { useCallback, useEffect, useMemo, useState, type CSSProperties } from 'react'
import {
  ResponsiveContainer,
  BarChart,
  Bar,
  Cell,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  AreaChart,
  Area,
  ReferenceArea,
} from 'recharts'
import {
  FinOpsApi,
  ApiError,
  type BriefDocument,
  type BriefResponse,
  type Finding,
  type MonthOverviewResponse,
  type PeriodType,
  type SavingsStatus,
  type TrendPoint,
} from '../api/client'
import { native, useCurrency } from '../lib/currency'
import { buildHash } from '../lib/route'
import { ownerLabel, ownerTag } from '../lib/allocation'
import { useAsk } from '../lib/ask'
import { usePalette } from '../themes/context'
import { t, locale } from '../i18n'

// The one page: what is going on in the tenant cost-wise this week (or last month), who to chase
// about what, and for how much. Everything is read from storage (GetBrief, GetMonthOverview,
// GetCostTrend, GetSavings); the AI findings are built weekly and monthly by the findings agent
// (CostAgent.psm1). Without AI the same payload is shown ranked by amount.

// Colours come from the active theme (src/themes/<id>/index.ts palette); labels are the page's own.
function usePrio(): Record<1 | 2 | 3, { bg: string; fg: string; label: string }> {
  const p = usePalette().priority
  return { 1: { ...p[1], label: t.ov.prio[1] }, 2: { ...p[2], label: t.ov.prio[2] }, 3: { ...p[3], label: t.ov.prio[3] } }
}
function useEnvColor(): Record<string, string> {
  return usePalette().env
}
const STATUS_VALUES: SavingsStatus[] = ['open', 'in-progress', 'done', 'dismissed']

const monthName = (ym?: string | null) => {
  if (!ym) return ''
  const d = new Date(`${ym}-01T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? ym : new Intl.DateTimeFormat(locale(), { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(d)
}
const shortDate = (iso: string) => {
  const d = new Date(`${iso}T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? iso : new Intl.DateTimeFormat(locale(), { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(d)
}
const pct = (n: number | null | undefined) => (n == null ? null : `${n > 0 ? '▲' : n < 0 ? '▼' : ''} ${Math.abs(n).toFixed(0)}%`)
const nativeMoney = (amount: number, currency: string) => {
  try { return new Intl.NumberFormat(locale(), { style: 'currency', currency, maximumFractionDigits: 0 }).format(amount) }
  catch { return `${Math.round(amount).toLocaleString(locale())} ${currency}` }
}
// The same ranking as Get-RuleFindings (CostAgent.psm1), for an overview built before the
// server stored one: savings and the three largest changes, priority by amount against last
// month's spend (>= 2% → 1, >= 0.5% → 2, else 3).
function rankByAmount(p: BriefDocument['payload']): Finding[] {
  const base = p.spend.previousMonth?.usd || p.spend.current?.usd || 0
  const prio = (usd: number): 1 | 2 | 3 => (base <= 0 ? 2 : usd / base >= 0.02 ? 1 : usd / base >= 0.005 ? 2 : 3)
  const items = [
    ...p.savings.items.map((s) => ({ usd: s.monthlyUsd, f: {
      priority: prio(s.monthlyUsd), title: `${s.title}${s.resourceName ? `: ${s.resourceName}` : ''}`, why: s.detail, owner: s.owner ?? '',
      monthlyCost: null, estMonthlySavings: s.monthlyUsd, currency: 'USD', action: s.title, actionScript: '', refs: [s.id] } })),
    ...p.changes.items.slice(0, 3).map((c) => ({ usd: c.deltaUsd, f: {
      priority: prio(c.deltaUsd), title: t.ov.costUp(c.name), why: c.cause ?? t.ov.notExplained, owner: c.owner ?? '',
      monthlyCost: c.currentUsd, estMonthlySavings: null, currency: 'USD', action: t.ov.askOwner, actionScript: '', refs: [c.id] } })),
  ]
  items.sort((a, b) => a.f.priority - b.f.priority || b.usd - a.usd)
  return items.slice(0, 6).map((x, i) => ({ id: `R${i + 1}`, ...x.f }) as Finding)
}

const compactMoney = (amount: number, currency: string) => {
  try { return new Intl.NumberFormat(locale(), { style: 'currency', currency, notation: 'compact', maximumFractionDigits: 0 }).format(amount) }
  catch { return nativeMoney(amount, currency) }
}

export function Overview() {
  const PRIO = usePrio()
  const ENV_COLOR = useEnvColor()
  const palette = usePalette()
  const { money, convert, toUsd, code } = useCurrency()
  const { goTo } = useAsk()
  // One page for both periods. The findings and this month's figures come from the weekly brief
  // (its findings also cover last month's changes); the monthly brief supplies only last
  // month's closed total for its tile.
  const grain: PeriodType = 'week'

  const [brief, setBrief] = useState<BriefResponse | null>(null)
  const [lastMonth, setLastMonth] = useState<BriefDocument | null>(null)
  const [overview, setOverview] = useState<MonthOverviewResponse | null>(null)
  const [trend, setTrend] = useState<TrendPoint[]>([])
  const [statuses, setStatuses] = useState<Record<string, SavingsStatus>>({})
  const [canSetStatus, setCanSetStatus] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState<1 | 2 | 3 | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [refreshNote, setRefreshNote] = useState<string | null>(null)

  useEffect(() => {
    setBrief(null); setLoading(true); setError(null); setFilter(null); setRefreshNote(null)
    Promise.allSettled([FinOpsApi.getBrief(grain), FinOpsApi.getMonthOverview(), FinOpsApi.getCostTrend(70), FinOpsApi.getBrief('month')])
      .then(([b, o, tr, m]) => {
        setLastMonth(m.status === 'fulfilled' ? m.value.brief : null)
        if (b.status === 'fulfilled') setBrief(b.value)
        else if (b.reason instanceof ApiError && b.reason.status === 401) setError('signed-out')
        else setError(b.reason instanceof ApiError
          ? t.ov.loadFailedHttp(b.reason.status, b.reason.serverMessage ?? '')
          : t.ov.loadFailed(String(b.reason)))
        setOverview(o.status === 'fulfilled' ? o.value : null)
        setTrend(tr.status === 'fulfilled' ? tr.value.points : [])
      })
      .finally(() => setLoading(false))
  }, [grain])

  useEffect(() => {
    FinOpsApi.getSavings(true)
      .then((s) => {
        setCanSetStatus(s.canSetStatus)
        setStatuses(Object.fromEntries(s.findings.map((f) => [f.id, f.status])))
      })
      .catch(() => setCanSetStatus(false))
  }, [])


  const doc: BriefDocument | null = brief?.brief ?? null
  const p = doc?.payload
  // An overview built by the previous version has `ai` in the old shape (summary, changes,
  // actions) — no findings, no tool calls.
  const aiFindings = Array.isArray(doc?.ai?.findings) ? doc!.ai!.findings : []
  const usingAi = aiFindings.length > 0
  const findings: Finding[] = usingAi ? aiFindings : doc?.ruleFindings ?? (p ? rankByAmount(p) : [])
  const oldVersion = !!p && (p.version ?? 0) < 3

  // An amount as USD (for adding up and sorting), or null when it is in a third currency.
  const asUsd = useCallback((amount: number | null, currency: string) => {
    if (amount == null) return null
    if (currency === 'USD') return amount
    if (currency === code) return toUsd(amount)
    return null
  }, [code, toUsd])
  const fmt = useCallback((amount: number | null, currency: string) => {
    if (amount == null) return '–'
    if (currency === 'USD') return money(amount)
    return nativeMoney(amount, currency)
  }, [money])

  const byPrio = useMemo(() => {
    const out = { 1: { usd: 0, n: 0 }, 2: { usd: 0, n: 0 }, 3: { usd: 0, n: 0 } } as Record<1 | 2 | 3, { usd: number; n: number }>
    for (const f of findings) {
      out[f.priority].n++
      out[f.priority].usd += asUsd(f.estMonthlySavings, f.currency) ?? 0
    }
    return out
  }, [findings, asUsd])
  const prioTotal = byPrio[1].usd + byPrio[2].usd + byPrio[3].usd
  const shown = filter ? findings.filter((f) => f.priority === filter) : findings

  const owners = useMemo(() => {
    const rows = [...(p?.owners ?? [])]
    rows.sort((a, b) => (b.openSavingsUsd ?? -1) - (a.openSavingsUsd ?? -1) || b.currentUsd - a.currentUsd)
    return rows
  }, [p])
  const chaseCount = new Set(findings.filter((f) => f.priority <= 2 && f.owner).map((f) => f.owner)).size
  const chaseP1 = new Set(findings.filter((f) => f.priority === 1 && f.owner).map((f) => f.owner)).size

  const refresh = async () => {
    setRefreshing(true); setRefreshNote(null)
    try {
      const r = await FinOpsApi.regenerateBrief(grain)
      setBrief(r)
      setRefreshNote(r.brief?.ai?.findings?.length ? t.ov.rebuilt : t.ov.rebuiltNoAi)
    } catch (e) {
      setRefreshNote(e instanceof ApiError && e.serverMessage ? e.serverMessage : t.ov.rebuildFailed)
      if (e instanceof ApiError && e.status === 429) {
        const body = e.body as { brief?: BriefDocument } | null
        if (body?.brief) setBrief({ grain, available: true, canRegenerate: true, brief: body.brief })
      }
    } finally {
      setRefreshing(false)
    }
  }

  // ---- KPI tiles ----
  const spend = p?.spend
  const isMtd = spend?.kind === 'month-to-date'
  const spendLabel = spend ? t.ov.thisMonthSoFarOf(monthName(spend.month)) : t.ov.thisMonthSoFar
  // Last month, closed: the monthly brief (with the change on the month before), else the
  // weekly brief's own figure for last month (no comparison).
  const lastSpend = lastMonth?.payload?.spend?.kind === 'complete-month' ? lastMonth.payload.spend : null
  const lastMonthSpend = lastSpend ? lastSpend.current : spend?.previousMonth ?? null
  const lastMonthDelta = lastSpend ? pct(lastSpend.changeVsPreviousPct) : null
  const spendValue = spend ? money(spend.current.usd, { native: native(spend.current.billing, spend.current.currency) }) : '–'
  const spendDelta = spend ? pct(spend.changeVsPreviousPct) : null
  // A month-end forecast below what is already spent cannot be right (a management group whose
  // cost data covers only part of the subscriptions). Use the straight-line run-rate instead.
  const rawForecast = overview?.forecast
  const forecastTrusted = !!rawForecast && rawForecast.usd != null && (!spend || rawForecast.usd >= spend.current.usd)
  const forecast = forecastTrusted ? rawForecast : null
  const runRateUsd = isMtd && spend && spend.current.complete && spend.current.throughDay > 0
    ? (spend.current.usd / spend.current.throughDay) * (spend.current.daysInMonth ?? 30) : null
  const budget = overview?.budgets?.find((b) => b.coversPortal) ?? null
  const fcValue = forecast?.usd != null
    ? money(forecast.usd, { compact: true, native: native(forecast.billing, forecast.currency) })
    : runRateUsd != null ? money(runRateUsd, { compact: true }) : null
  const budgetComparable = budget && forecast?.billing != null && forecast.currency === budget.currency
  const budgetPct = budgetComparable ? (forecast!.billing! / budget!.amount) * 100 : null

  return (
    <div className="fo">
      <div className="fo-container fo-page">
        <div className="fo-head">
          <div>
            <h1>{t.ov.title}</h1>
            <div className="fo-sub">
              {t.ov.subtitle(spend ? shortDate(spend.throughDate) : null)}
              {doc && t.ov.findingsFrom(doc.generatedAt)}
            </div>
          </div>
          {brief?.canRegenerate && (
            <button type="button" className="fo-btn" onClick={() => void refresh()} disabled={refreshing}>
              {refreshing ? t.ov.rebuilding : t.ov.rebuild}
            </button>
          )}
        </div>
        {refreshNote && <div className="fo-notice" style={{ marginTop: 16 }}>{refreshNote}</div>}
        {error === 'signed-out' && (
          <div className="fo-notice" style={{ marginTop: 16, display: 'flex', gap: 16, alignItems: 'center', flexWrap: 'wrap' }}>
            <span>{t.ov.signedOut}</span>
            <button type="button" className="fo-btn" onClick={() => { window.location.href = '/.auth/login/aad?post_login_redirect_uri=' + encodeURIComponent(window.location.pathname + window.location.hash) }}>
              {t.ov.signIn}
            </button>
          </div>
        )}
        {error && error !== 'signed-out' && <div className="fo-notice" style={{ marginTop: 16 }}>{error}</div>}
        {loading && !doc && <div className="fo-empty" style={{ marginTop: 20 }}>{t.ov.loading}</div>}
        {!loading && !doc && !error && (
          <div className="fo-empty" style={{ marginTop: 20 }}>
            {t.ov.noOverview(!!brief?.canRegenerate)}
          </div>
        )}

        {doc && p && (
          <>
            {oldVersion && (
              <div className="fo-notice" style={{ marginTop: 16 }}>
                {t.ov.oldVersion(ownerLabel().toLowerCase(), !!brief?.canRegenerate)}
              </div>
            )}
            <div className="fo-hero">
              <div className="fo-hero-box">
                <div className="fo-eyebrow">
                  {t.ov.mostImportant(usingAi)}
                </div>
                {findings[0] ? (
                  <>
                    <h2>{findings[0].title}</h2>
                    <p>{findings[0].why}</p>
                    <button type="button" className="fo-more" onClick={() => document.getElementById(`f-${findings[0].id}`)?.scrollIntoView({ behavior: 'smooth' })}>
                      {t.ov.seeFinding}
                    </button>
                  </>
                ) : (
                  <>
                    <h2>{t.ov.nothing}</h2>
                    <p>{t.ov.nothingText}</p>
                  </>
                )}
              </div>
              <div className="fo-kpis" aria-label={t.ov.keyFigures}>
                <div className="fo-kpi">
                  <div className="fo-kpi-label">{spendLabel}</div>
                  <div className="fo-kpi-value fo-num">{spendValue}</div>
                  <div className="fo-kpi-sub">
                    {spendDelta ? t.ov.vsSameDays(spendDelta) : t.ov.noComparison}
                  </div>
                </div>
                {isMtd && (
                  <div className="fo-kpi">
                    <div className="fo-kpi-label">{budgetComparable ? t.ov.forecastVsBudget : t.ov.forecastEnd}</div>
                    <div className="fo-kpi-value fo-num">
                      {budgetComparable
                        ? <>{compactMoney(forecast!.billing!, budget!.currency)} <small>/ {compactMoney(budget!.amount, budget!.currency)}</small></>
                        : fcValue ?? '–'}
                    </div>
                    {budgetPct != null && (
                      <div className="fo-meter" aria-hidden="true">
                        <i style={{ width: `${Math.min(100, budgetPct)}%` }} />
                        <b style={{ left: `${Math.min(99, (100 / Math.max(100, budgetPct)) * 100)}%` }} />
                      </div>
                    )}
                    <div className="fo-kpi-sub">
                      {budgetPct != null
                        ? budgetPct > 100 ? t.ov.overBudget((budgetPct - 100).toFixed(0)) : t.ov.underBudget((100 - budgetPct).toFixed(0))
                        : forecast?.source === 'azure' ? t.ov.azureForecast
                          : runRateUsd != null ? t.ov.runRate(rawForecast?.usd != null && !forecastTrusted)
                            : t.ov.noForecast}
                    </div>
                  </div>
                )}
                <div className="fo-kpi">
                  <div className="fo-kpi-label">{t.ov.lastMonth(lastMonthSpend ? monthName(lastMonthSpend.month) : null)}</div>
                  <div className="fo-kpi-value fo-num">
                    {lastMonthSpend ? money(lastMonthSpend.usd, { native: native(lastMonthSpend.billing, lastMonthSpend.currency) }) : '–'}
                  </div>
                  <div className="fo-kpi-sub">
                    {lastMonthDelta ? t.ov.vsMonthBefore(lastMonthDelta) : lastMonthSpend && !lastMonthSpend.complete ? t.ov.someMissing : t.ov.closed}
                  </div>
                </div>
                <div className="fo-kpi">
                  <div className="fo-kpi-label">{t.ov.savingsOpen}</div>
                  <div className="fo-kpi-value fo-num">{money(p.savings.totalMonthlyUsd)}</div>
                  <div className="fo-kpi-sub">{t.ov.perMonthCount(p.savings.count)}</div>
                </div>
              </div>
            </div>

            <section className="fo-block" aria-labelledby="prio-h">
              <div className="fo-block-head">
                <h2 id="prio-h">{t.ov.byPriority}</h2>
                <span className="fo-hint">{filter ? t.ov.showingPrio(filter) : t.ov.selectPrio}</span>
              </div>
              <div className="fo-prio">
                {([1, 2, 3] as const).map((k) => {
                  // Width follows the savings, but a priority with findings and no savings (cost
                  // increases, e.g. P1) still gets a small segment showing its count — otherwise
                  // it vanishes from the bar while the legend lists it.
                  if (!byPrio[k].n && !byPrio[k].usd) return null
                  const showsMoney = prioTotal > 0 && byPrio[k].usd > 0
                  const weight = prioTotal > 0 ? Math.max(byPrio[k].usd, prioTotal * 0.12) : byPrio[k].n
                  return (
                    <button
                      key={k}
                      type="button"
                      className={filter && filter !== k ? 'fo-dim' : ''}
                      style={{ flex: weight, background: PRIO[k].bg, color: PRIO[k].fg }}
                      aria-pressed={filter === k}
                      onClick={() => setFilter(filter === k ? null : k)}
                    >
                      <span>P{k}</span>
                      <small className="fo-num">{showsMoney ? money(byPrio[k].usd) : t.ov.nFindings(byPrio[k].n)}</small>
                    </button>
                  )
                })}
                {findings.length === 0 && <div className="fo-empty" style={{ flex: 1 }}>{t.ov.noFindings}</div>}
              </div>
              <div className="fo-legend">
                {([1, 2, 3] as const).map((k) => (
                  <span key={k}>
                    <span className="fo-sw" style={{ background: PRIO[k].bg }} />
                    <b>P{k}</b>{t.ov.legend(PRIO[k].label, money(byPrio[k].usd), byPrio[k].n)}
                  </span>
                ))}
              </div>
            </section>

            <section className="fo-block" id="findings" aria-labelledby="find-h">
              <div className="fo-block-head">
                <h2 id="find-h">{t.ov.keyFindings}</h2>
                <span className="fo-hint">
                  {usingAi
                    ? t.ov.writtenByAi(doc.ai!.toolCalls?.length ?? 0)
                    : t.ov.rankedNoAi}
                </span>
              </div>
              {!usingAi && <AiNotice status={doc.aiStatus} />}
              {usingAi && doc.ai!.summary && <p className="fo-why fo-summary">{doc.ai!.summary}</p>}
              {usingAi && doc.ai!.dropped > 0 && (
                <div className="fo-notice">
                  {t.ov.dropped(doc.ai!.dropped)}
                </div>
              )}
              <div className="fo-findings">
                {shown.map((f) => (
                  <FindingCard
                    key={f.id}
                    finding={f}
                    doc={doc}
                    fmt={fmt}
                    statuses={statuses}
                    canSetStatus={canSetStatus}
                    onStatus={(id, s) => setStatuses((prev) => ({ ...prev, [id]: s }))}
                    goTo={goTo}
                  />
                ))}
              </div>
            </section>

            <section className="fo-block" id="owners" aria-labelledby="own-h">
              <div className="fo-block-head">
                <h2 id="own-h">{t.ov.chaseList}</h2>
                <span className="fo-hint">
                  {t.ov.toChase(chaseCount, ownerLabel().toLowerCase(), chaseP1)}
                </span>
              </div>
              {owners.length ? (
                <OwnerTable owners={owners} findings={findings} grainLabel={t.ov.vsSameDaysCol} />
              ) : (
                <div className="fo-empty">{t.ov.noOwners(ownerLabel().toLowerCase())}</div>
              )}
            </section>

            <section className="fo-block" id="spend">
              <div className="fo-charts">
                <div className="fo-chart-card">
                  <div className="fo-block-head" style={{ margin: 0 }}>
                    <h3>{t.ov.whereMoney}</h3>
                    <div className="fo-legend" style={{ margin: 0 }}>
                      <span><span className="fo-sw" style={{ background: ENV_COLOR['non-production'] }} />{t.ov.devTest}</span>
                      <span><span className="fo-sw" style={{ background: ENV_COLOR.production }} />{t.ov.production}</span>
                      <span><span className="fo-sw" style={{ background: ENV_COLOR.unknown }} />{t.ov.notNamed}</span>
                    </div>
                  </div>
                  <ResourceGroupChart rows={p.resourceGroups ?? []} convert={convert} money={money} />
                </div>
                <div className="fo-chart-card">
                  <div className="fo-block-head" style={{ margin: 0 }}>
                    <h3>{t.ov.dailySpend}</h3>
                    {p.changes.periodStart && (
                      <span className="fo-legend" style={{ margin: 0 }}>
                        <span><span className="fo-sw" style={{ background: palette.changeArea }} />{t.ov.periodChecked}</span>
                      </span>
                    )}
                  </div>
                  <TrendArea points={trend} convert={convert} money={money} changeFrom={p.changes.periodStart} changeTo={p.changes.periodEnd} />
                </div>
              </div>
            </section>
            {p.notes.length > 0 && (
              <div className="fo-hint" style={{ marginTop: 20 }}>{p.notes.join(' ')}</div>
            )}
          </>
        )}
      </div>
    </div>
  )
}

function AiNotice({ status }: { status: BriefDocument['aiStatus'] }) {
  const text =
    status === 'not-configured' ? t.ov.aiNotConfigured
      : status === 'budget-exceeded' ? t.ov.aiBudget
        : status === 'failed' ? t.ov.aiFailed
          : t.ov.ranked
  return <div className="fo-notice">{text}</div>
}

type Fmt = (amount: number | null, currency: string) => string

function FindingCard({ finding: f, doc, fmt, statuses, canSetStatus, onStatus, goTo }: {
  finding: Finding
  doc: BriefDocument
  fmt: Fmt
  statuses: Record<string, SavingsStatus>
  canSetStatus: boolean
  onStatus: (id: string, s: SavingsStatus) => void
  goTo: (page: 'dashboard' | 'statements' | 'spikes' | 'savings') => void
}) {
  const PRIO = usePrio()
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null)
  const p = doc.payload
  const savingId = f.refs.find((r) => r.startsWith('S-'))?.slice(2) ?? null
  const status = savingId ? statuses[savingId] : undefined
  const hasChange = f.refs.some((r) => r.startsWith('C-'))
  const hasSaving = f.refs.some((r) => r.startsWith('S-') || r.startsWith('A-'))
  const style = { '--p': PRIO[f.priority].bg, '--pc': PRIO[f.priority].fg } as CSSProperties

  const copy = () => {
    const text = f.actionScript || f.action
    navigator.clipboard.writeText(text).then(
      () => { setNote({ ok: true, text: t.ov.copied }); setTimeout(() => setNote(null), 1500) },
      () => setNote({ ok: false, text: t.ov.copyBlocked }),
    )
  }
  const setStatus = (s: SavingsStatus) => {
    if (!savingId) return
    FinOpsApi.setSavingsStatus(savingId, s)
      .then(() => { onStatus(savingId, s); setNote({ ok: true, text: t.ov.statusSaved }); setTimeout(() => setNote(null), 1500) })
      .catch((e) => setNote({ ok: false, text: e instanceof ApiError && e.serverMessage ? e.serverMessage : t.ov.statusFailed }))
  }

  // The cost changes this finding rests on — directly (C-…) or through an evidence lookup.
  const changeOf = (id: string | undefined) => (id ? p.changes.items.find((x) => x.id === id) : undefined)
  const toolArgId = (args: string): string | undefined => {
    try { const a = JSON.parse(args) as { id?: unknown }; return typeof a.id === 'string' ? a.id : undefined } catch { return undefined }
  }
  const linkedChanges = [...new Map(
    f.refs
      .map((r) => changeOf(r) ?? changeOf(toolArgId(doc.ai?.toolCalls?.find((c) => c.ref === r && c.tool === 'change_evidence')?.args ?? '')))
      .filter((c): c is NonNullable<typeof c> => !!c)
      .map((c) => [c.id, c]),
  ).values()]
  const changeLink = (c: (typeof p.changes.items)[number]) => (
    <a className="fo-link" href={changeHref(c)}>{c.name}</a>
  )

  const describeRef = (r: string) => {
    const tool = doc.ai?.toolCalls?.find((call) => call.ref === r)
    if (tool) {
      const name = tool.tool === 'cost_query' ? t.ov.costQuery : tool.tool === 'change_evidence' ? t.ov.changeEvidence : tool.tool === 'saving_detail' ? t.ov.savingDetail : tool.tool
      // An evidence lookup names the change it read, linked — not its internal id.
      if (tool.tool === 'change_evidence') {
        const c = changeOf(toolArgId(tool.args))
        if (c) return <>{name}: {changeLink(c)} ({tool.summary})</>
        return <>{name} ({tool.summary})</>
      }
      if (tool.tool === 'saving_detail') {
        const s = p.savings.items.find((x) => x.id === toolArgId(tool.args))
        return <>{name}{s ? `: ${s.title}${s.resourceName ? ` (${s.resourceName})` : ''}` : ''} ({tool.summary})</>
      }
      return <>{name} ({tool.summary})<br /><code>{tool.args}</code></>
    }
    const c = changeOf(r)
    if (c) return <>{t.ov.costChange(c.period ?? null, c.name, c.cause ?? null)} · {changeLink(c)}</>
    const s = p.savings.items.find((x) => x.id === r)
    if (s) return <>{s.source === 'advisor' ? t.ov.advisor : t.ov.savingsCheck}: {s.title}{s.resourceName ? ` (${s.resourceName})` : ''}</>
    const o = p.owners?.find((x) => x.id === r)
    if (o) return <>{t.ov.spendOf(o.owner)}</>
    const g = p.resourceGroups?.find((x) => x.id === r)
    if (g) return <>{t.ov.spendOfGroup(g.name, g.subscription || null)}</>
    return <>{r}</>
  }

  return (
    <article className="fo-finding" id={`f-${f.id}`} style={style}>
      <div className="fo-finding-in">
        <div className="fo-f-head">
          <h3>{f.title}</h3>
          <span className="fo-tag">P{f.priority}</span>
        </div>
        {f.why && <p className="fo-why">{f.why}</p>}
        <dl className="fo-figures">
          <div><dt>{t.ov.costMonth}</dt><dd className="fo-num">{fmt(f.monthlyCost, f.currency)}</dd></div>
          <div className="fo-save"><dt>{t.ov.saveMonth}</dt><dd className="fo-num">{f.estMonthlySavings != null ? `~${fmt(f.estMonthlySavings, f.currency)}` : '–'}</dd></div>
          <div><dt>{ownerLabel()}</dt><dd style={{ fontSize: 17 }}>{f.owner || (f.billingScope ? t.ov.billingAccount : t.ov.noOwnerTag)}</dd></div>
        </dl>
        {f.action && <p className="fo-action"><b>{t.ov.nextStep}</b> {f.action}</p>}
        {f.actionScript && (
          <>
            <pre className="fo-code">{f.actionScript}</pre>
            <div className="fo-code-note">{t.ov.proposal}</div>
          </>
        )}
        <div className="fo-f-foot">
          <button type="button" className="fo-btn fo-btn-go" onClick={copy}>{f.actionScript ? t.ov.copyCommand : t.ov.copyAction}</button>
          {savingId && status && canSetStatus && (
            <>
              <label className="fo-status-label" htmlFor={`st-${f.id}`}>{t.ov.status}</label>
              <select id={`st-${f.id}`} className="fo-select" value={status} onChange={(e) => setStatus(e.target.value as SavingsStatus)}>
                {STATUS_VALUES.map((s) => <option key={s} value={s}>{t.ov.statuses[s]}</option>)}
              </select>
            </>
          )}
          {savingId && status && !canSetStatus && <span className="fo-status-label">{t.ov.statusIs(t.ov.statuses[status] ?? status)}</span>}
          {/* Straight to the change(s) this finding is about, in the period it was found in. */}
          {linkedChanges.length === 1 && <a className="fo-link" href={changeHref(linkedChanges[0])}>{t.ov.costChanges}</a>}
          {linkedChanges.length > 1 && linkedChanges.map((c) => <a key={c.id} className="fo-link" href={changeHref(c)}>{c.name}</a>)}
          {hasChange && !linkedChanges.length && <button type="button" className="fo-link" onClick={() => goTo('spikes')}>{t.ov.costChanges}</button>}
          {hasSaving && <button type="button" className="fo-link" onClick={() => goTo('savings')}>{t.ov.savings}</button>}
          {note && <span className={note.ok ? 'fo-ok' : 'fo-err'} aria-live="polite">{note.text}</span>}
        </div>
        <details className="fo-ev">
          <summary>{t.ov.showEvidence(f.refs.length)}</summary>
          <ul>{f.refs.map((r) => <li key={r}>{describeRef(r)}</li>)}</ul>
        </details>
      </div>
    </article>
  )
}

// A link to one cost change on the Cost changes page: the exact period the brief read it from
// (periodKey 'week|2026-11-08' / 'month|2026-10'), scrolled to and highlighted.
function changeHref(c: { findingId: string; periodKey?: string; period?: string }): string {
  const params = new URLSearchParams()
  const [grain, key] = (c.periodKey ?? '').split('|')
  const type = grain === 'week' || grain === 'month' ? grain : c.period === 'last month' ? 'month' : 'week'
  params.set('period', type)
  if (key) params.set('key', key)
  params.set('focus', c.findingId)
  return buildHash('spikes', params)
}

function OwnerTable({ owners, findings, grainLabel }: {
  owners: NonNullable<BriefDocument['payload']['owners']>
  findings: Finding[]
  grainLabel: string
}) {
  const pal = usePalette()
  const { money } = useCurrency()
  const [open, setOpen] = useState<string | null>(null)
  const openStatement = (owner: string) => {
    const params = new URLSearchParams({ dim: `tag:${ownerTag()}`, value: owner })
    window.location.hash = buildHash('statements', params)
  }
  return (
    <div className="fo-tbl">
      <table>
        <thead>
          <tr>
            <th>{ownerLabel()}</th>
            <th className="fo-r">{t.ov.spendThisMonth}</th>
            <th className="fo-r">{t.ov.openSavings}</th>
            <th className="fo-r">{t.ov.findings}</th>
            <th className="fo-r">{grainLabel}</th>
          </tr>
        </thead>
        <tbody>
          {owners.map((o) => {
            const mine = findings.filter((f) => f.owner && f.owner === o.owner)
            const p1 = mine.filter((f) => f.priority === 1).length
            const delta = o.previousSameDaysUsd > 0 ? ((o.currentUsd - o.previousSameDaysUsd) / o.previousSameDaysUsd) * 100 : null
            const isOpen = open === o.id
            const label = o.owner.startsWith('(') ? (o.owner === '(untagged)' ? t.ov.noOwnerTag : o.owner === '(resource no longer exists)' ? t.tags.gone : o.owner) : o.owner
            const toggle = () => setOpen(isOpen ? null : o.id)
            return [
              <tr
                key={o.id}
                className="fo-owner-row"
                tabIndex={0}
                aria-expanded={isOpen}
                onClick={toggle}
                onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggle() } }}
              >
                <td>{label}</td>
                <td className="fo-r fo-num">{money(o.currentUsd)}</td>
                <td className="fo-r fo-num" style={{ color: pal.positive, fontWeight: 700 }}>{o.openSavingsUsd == null ? '–' : money(o.openSavingsUsd)}</td>
                <td className="fo-r">{p1 ? <span className="fo-p1tag">{p1} P1</span> : mine.length || '–'}</td>
                <td className={`fo-r fo-num ${delta != null && delta > 0 ? 'fo-up' : 'fo-down'}`}>{delta == null ? t.ov.isNew : pct(delta)}</td>
              </tr>,
              isOpen ? (
                <tr key={`${o.id}-stmt`} className="fo-stmt">
                  <td colSpan={5}>
                    <div className="fo-stmt-grid">
                      <div>
                        <h4>{t.ov.raise}</h4>
                        <ul>
                          {mine.length ? mine.map((f) => <li key={f.id}><b>P{f.priority}</b> {f.title}</li>) : <li>{t.ov.noKey}</li>}
                        </ul>
                      </div>
                      <div>
                        <h4>{t.ov.numbers}</h4>
                        <ul>
                          <li className="fo-num">{t.ov.thisMonthShare(money(o.currentUsd), o.sharePct.toFixed(0))}</li>
                          <li className="fo-num">{t.ov.lastMonthAmount(money(o.previousMonthUsd))}</li>
                          {o.openSavingsUsd != null && (
                            <li className="fo-num">{t.ov.openSavingsWorth(o.openSavingsCount ?? 0, money(o.openSavingsUsd))}</li>
                          )}
                          <li>{t.ov.resourcesWithCost(o.resources)}</li>
                        </ul>
                      </div>
                      <div>
                        <h4>{t.ov.statement}</h4>
                        <p style={{ margin: '0 0 10px', fontSize: 14 }}>
                          {o.owner === '(untagged)'
                            ? t.ov.stmtUntagged
                            : o.owner.startsWith('(')
                              ? t.ov.stmtGone
                              : t.ov.stmtOwner}
                        </p>
                        <button type="button" className="fo-btn" onClick={() => openStatement(o.owner)}>{t.ov.openStatement}</button>
                      </div>
                    </div>
                  </td>
                </tr>
              ) : null,
            ]
          })}
        </tbody>
      </table>
    </div>
  )
}

type Money = ReturnType<typeof useCurrency>['money']
type Convert = ReturnType<typeof useCurrency>['convert']

function ResourceGroupChart({ rows, convert, money }: { rows: NonNullable<BriefDocument['payload']['resourceGroups']>; convert: Convert; money: Money }) {
  const pal = usePalette()
  const ENV_COLOR = useEnvColor()
  const data = rows.slice(0, 10).map((r) => ({ name: r.name, value: convert(r.currentUsd), usd: r.currentUsd, env: r.environment, sub: r.subscription }))
  if (!data.length) return <div className="fo-empty" style={{ marginTop: 14 }}>{t.ov.notYet}</div>
  return (
    <div style={{ height: Math.max(220, data.length * 32 + 40), marginTop: 14 }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} layout="vertical" margin={{ top: 0, right: 16, bottom: 0, left: 8 }}>
          <CartesianGrid horizontal={false} stroke={pal.chartGrid} />
          <XAxis type="number" tickFormatter={(v: number) => new Intl.NumberFormat(locale(), { notation: 'compact' }).format(v)} fontSize={12} stroke={pal.chartAxis} />
          <YAxis type="category" dataKey="name" width={150} fontSize={12} stroke={pal.chartAxis} tick={{ fontWeight: 700 }} />
          <Tooltip
            formatter={(_v: number, _n: string, item: { payload?: { usd: number; sub: string } }) => [t.ov.thisMonthTip(money(item.payload?.usd ?? 0)), item.payload?.sub || t.ov.spend]}
            contentStyle={{ background: pal.tooltip.bg, border: 0, color: pal.tooltip.fg, fontSize: 12 }}
            itemStyle={{ color: pal.tooltip.fg }}
            labelStyle={{ color: pal.tooltip.label, fontWeight: 700 }}
            cursor={{ fill: pal.chartGrid }}
          />
          <Bar dataKey="value" barSize={20} isAnimationActive={false}>
            {data.map((d) => <Cell key={d.name} fill={ENV_COLOR[d.env] ?? ENV_COLOR.unknown} />)}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}

function TrendArea({ points, convert, money, changeFrom, changeTo }: {
  points: TrendPoint[]; convert: Convert; money: Money; changeFrom: string | null; changeTo: string | null
}) {
  const pal = usePalette()
  const data = points.map((pt) => ({ date: pt.date, value: convert(pt.usd, native(pt.billing, pt.currency)), usd: pt.usd }))
  if (!data.length) return <div className="fo-empty" style={{ marginTop: 14 }}>{t.ov.noDaily}</div>
  const inRange = (d: string | null) => !!d && data.some((x) => x.date === d)
  return (
    <div style={{ height: 300, marginTop: 14 }}>
      <ResponsiveContainer width="100%" height="100%">
        <AreaChart data={data} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
          <CartesianGrid vertical={false} stroke={pal.chartGrid} />
          <XAxis dataKey="date" tickFormatter={shortDate} fontSize={12} stroke={pal.chartAxis} minTickGap={28} />
          <YAxis tickFormatter={(v: number) => new Intl.NumberFormat(locale(), { notation: 'compact' }).format(v)} fontSize={12} stroke={pal.chartAxis} width={48} />
          {inRange(changeFrom) && inRange(changeTo) && (
            <ReferenceArea x1={changeFrom!} x2={changeTo!} fill={pal.changeArea} fillOpacity={1} stroke="none" />
          )}
          <Tooltip
            formatter={(_v: number, _n: string, item: { payload?: { usd: number } }) => [money(item.payload?.usd ?? 0), t.ov.spend]}
            labelFormatter={(l: string) => shortDate(String(l))}
            contentStyle={{ background: pal.tooltip.bg, border: 0, color: pal.tooltip.fg, fontSize: 12 }}
            itemStyle={{ color: pal.tooltip.fg }}
            labelStyle={{ color: pal.tooltip.label, fontWeight: 700 }}
          />
          <Area type="monotone" dataKey="value" stroke={pal.chartLine} strokeWidth={3} fill={pal.chartFill} isAnimationActive={false}
            activeDot={{ r: 5, stroke: pal.tooltip.fg, strokeWidth: 2, fill: pal.chartLine }} />
        </AreaChart>
      </ResponsiveContainer>
    </div>
  )
}
