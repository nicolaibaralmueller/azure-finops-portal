import { useEffect, useMemo, useState } from 'react'
import {
  Text,
  Badge,
  Dropdown,
  Option,
  Button,
  Spinner,
  Switch,
  Tab,
  TabList,
  makeStyles,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import {
  Sparkle16Regular,
  Info16Regular,
  ArrowSync16Regular,
  ChevronLeft16Regular,
  ChevronRight16Regular,
  ChevronDown16Regular,
  ChevronUp16Regular,
  DocumentSearch16Regular,
} from '@fluentui/react-icons'
import { ResourceRef } from '../components/ResourceRef'
import { EvidencePanel, evidenceSummary } from '../components/EvidencePanel'
import { AskAboutButton } from '../components/AskAboutButton'
import { shortGuid } from '../lib/resource'
import { subscriptionIdOf } from '../lib/ask'
import {
  ApiError,
  FinOpsApi,
  type CostSpike,
  type CostSpikesResponse,
  type ExplainSpikeResponse,
  type FindingState,
  type PeriodType,
  type SavingsFinding,
} from '../api/client'
import { useCurrency } from '../lib/currency'
import { useHashParam } from '../lib/route'
import { allocationSummary, ownerKey, ownerLabel, ownerOf } from '../lib/allocation'
import { ErrorNote } from '../components/ErrorNote'
import { ExportButton } from '../components/ExportButton'
import { t, locale } from '../i18n'

// Monthly shows the calendar month ('July 2026'); weekly is a TRAILING 7 days, so it shows the
// actual range ('30 Jul – 5 Aug 2026') rather than a week number — the window doesn't align to
// calendar weeks and a number would imply it does. Falls back to the raw key so an unexpected
// shape can never blank the header.
function periodLabel(meta: CostSpikesResponse | null): string {
  if (!meta?.period) return '—'
  if (meta.periodType === 'week' && meta.periodStart && meta.periodEnd) {
    const start = new Date(`${meta.periodStart}T00:00:00Z`)
    const end = new Date(`${meta.periodEnd}T00:00:00Z`)
    if (!Number.isNaN(start.getTime()) && !Number.isNaN(end.getTime())) {
      const day = (d: Date, withYear: boolean) =>
        new Intl.DateTimeFormat(locale(), {
          day: 'numeric', month: 'short', timeZone: 'UTC',
          ...(withYear ? { year: 'numeric' } : {}),
        }).format(d)
      return `${day(start, false)} – ${day(end, true)}`
    }
  }
  const month = meta.period.match(/^(\d{4})-(\d{2})$/)
  if (month) {
    const d = new Date(Date.UTC(Number(month[1]), Number(month[2]) - 1, 1))
    if (!Number.isNaN(d.getTime())) {
      return new Intl.DateTimeFormat(locale(), { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(d)
    }
  }
  return meta.period
}

const useStyles = makeStyles({
  root: { rowGap: tokens.spacingVerticalM, display: 'flex', flexDirection: 'column', minWidth: 0 },
  card: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    ...shorthands.borderLeft('4px', 'solid', tokens.colorPaletteRedBorder2),
    boxShadow: tokens.shadow2,
    minWidth: 0,
  },
  head: { display: 'flex', alignItems: 'flex-start', columnGap: tokens.spacingHorizontalS },
  spacer: { flexGrow: 1 },
  headRight: { display: 'flex', flexDirection: 'column', alignItems: 'flex-end', rowGap: '4px', flexShrink: 0 },
  delta: { color: tokens.colorPaletteRedForeground1, whiteSpace: 'nowrap' },
  // An increase that already fell back within the period: still listed (the period did cost
  // more), but not presented as an open problem.
  deltaResolved: { color: tokens.colorNeutralForeground3, whiteSpace: 'nowrap' },
  // The deterministic "baseline → spike" figures — always shown, no AI required.
  figures: {
    display: 'flex',
    flexWrap: 'wrap',
    columnGap: tokens.spacingHorizontalXXL,
    rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorNeutralBackground2,
    ...shorthands.borderRadius(tokens.borderRadiusMedium),
  },
  figure: { display: 'flex', flexDirection: 'column', rowGap: '2px' },
  figLabel: { color: tokens.colorNeutralForeground3, textTransform: 'uppercase', letterSpacing: '0.4px', fontSize: '10px' },
  explanation: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalXS,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorBrandBackground2,
    ...shorthands.borderRadius(tokens.borderRadiusMedium),
    ...shorthands.border('1px', 'solid', tokens.colorBrandStroke2),
  },
  explanationOpen: {
    backgroundColor: tokens.colorNeutralBackground2,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
  },
  explanationHead: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalXS, flexWrap: 'wrap' },
  aiIcon: { color: tokens.colorBrandForeground1, flexShrink: 0 },
  evidenceBox: {
    minWidth: 0,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
    ...shorthands.borderRadius(tokens.borderRadiusMedium),
  },
  pending: {
    display: 'flex',
    alignItems: 'center',
    columnGap: tokens.spacingHorizontalXS,
    color: tokens.colorNeutralForeground3,
  },
  muted: { color: tokens.colorNeutralForeground3 },
  error: { color: tokens.colorPaletteRedForeground1 },
  // Rollup (meter / subscription) spikes have no single resource to link to.
  rollupHead: { display: 'flex', flexDirection: 'column', rowGap: '2px', minWidth: 0 },
  rollupName: { fontWeight: tokens.fontWeightSemibold },
  actions: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalS, minHeight: '24px', flexWrap: 'wrap' },
  increases: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalXS,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
  },
  increaseRow: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalS, paddingTop: '4px' },
  toolbar: {
    display: 'flex',
    alignItems: 'center',
    columnGap: tokens.spacingHorizontalS,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorNeutralBackground2,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
  },
  method: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalXS,
    ...shorthands.padding(tokens.spacingVerticalM, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
  },
  methodBar: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalS, flexWrap: 'wrap' },
})

function Figure({ label, children }: { label: string; children: React.ReactNode }) {
  const styles = useStyles()
  return (
    <div className={styles.figure}>
      <Text className={styles.figLabel}>{label}</Text>
      <Text size={300} weight="semibold">{children}</Text>
    </div>
  )
}

// '2026-10-13' -> '13. okt.' / 'Oct 13' in the viewer's language.
function dayLabel(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(d.getTime())) return iso
  return new Intl.DateTimeFormat(locale(), { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(d)
}

// '2026-10-01' -> 'October 2026' / 'oktober 2026'.
function monthLabel(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(d.getTime())) return iso
  return new Intl.DateTimeFormat(locale(), { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(d)
}

// Where a finding stands now. Rows written before `state` existed only carry `resolved`.
function stateOf(s: CostSpike): FindingState {
  return s.state ?? (s.resolved ? 'resolved' : 'open')
}

// The "how is this calculated" text, filled in from the response so every date is the real one.
function MethodPanel({ meta, money }: { meta: CostSpikesResponse; money: (n: number) => string }) {
  const styles = useStyles()
  const week = meta.periodType === 'week'
  const ranges = (meta.baselineRanges ?? [])
    .map((r) => (week ? `${dayLabel(r.start)}–${dayLabel(r.end)}` : monthLabel(r.start)))
    .join(', ')
  const settled = meta.settledThrough ?? meta.periodEnd ?? ''
  const lines: string[] = [
    week
      ? t.spikes.how.periodWeek(periodLabel(meta), settled ? dayLabel(settled) : '—', meta.settlingDays ?? 2)
      : t.spikes.how.periodMonth(periodLabel(meta)),
    t.spikes.how.compared(meta.baselineCount ?? (week ? 4 : 3), week, ranges),
  ]
  if (meta.minDeltaUsd != null && meta.minDeltaPct != null) lines.push(t.spikes.how.bar(money(meta.minDeltaUsd), week, meta.minDeltaPct))
  if (meta.settledThrough) lines.push(t.spikes.how.current(3, dayLabel(meta.settledThrough)))
  lines.push(t.spikes.how.resolves, t.spikes.how.baseline(week), t.spikes.how.removed(week))
  if (meta.analyzedAt) {
    const at = new Date(meta.analyzedAt)
    if (!Number.isNaN(at.getTime())) {
      lines.push(t.spikes.how.analysedAt(new Intl.DateTimeFormat(locale(), { dateStyle: 'medium', timeStyle: 'short' }).format(at)))
    }
  }
  return (
    <div className={styles.method}>
      {lines.map((l, i) => {
        // Each line is "Label: text" — bold the label.
        const idx = l.indexOf(': ')
        return (
          <Text key={i} size={200}>
            {idx > 0 && idx < 40 ? <><b>{l.slice(0, idx)}:</b>{l.slice(idx + 1)}</> : l}
          </Text>
        )
      })}
    </div>
  )
}

// -42.3 -> '−42 %' / '-42%' in the viewer's language.
function pctLabel(pct: number): string {
  return new Intl.NumberFormat(locale(), { style: 'percent', maximumFractionDigits: 0, signDisplay: 'always' }).format(pct / 100)
}

// Days in a finding's period, so a daily level can be put on the same footing as the totals.
function periodDays(s: CostSpike): number {
  const a = new Date(`${s.periodStart}T00:00:00Z`).getTime()
  const b = new Date(`${s.periodEnd}T00:00:00Z`).getTime()
  if (Number.isNaN(a) || Number.isNaN(b) || b < a) return s.periodType === 'week' ? 7 : 30
  return Math.round((b - a) / 86_400_000) + 1
}

// Why a card has no written explanation, in words.
function noExplanationText(s: CostSpike): string {
  switch (s.explanationStatus) {
    case 'not-configured': return t.spikes.noAi
    case 'budget-exceeded':
    case 'skipped': return t.spikes.aiLimitBefore
    case 'failed': return t.spikes.aiFailed
    default:
      if (s.evidenceStatus === 'skipped') return t.spikes.evidenceSkipped
      return t.spikes.noEvidence
  }
}

export function Spikes() {
  const styles = useStyles()
  const { money, convert, code } = useCurrency()
  const usd = (n: number) => money(n)
  const [loading, setLoading] = useState(true)
  const [spikes, setSpikes] = useState<CostSpike[]>([])
  const [meta, setMeta] = useState<CostSpikesResponse | null>(null)
  const [error, setError] = useState<unknown>(null)
  // Which complete period is on screen. Week is the default: it surfaces a change within days
  // of it happening, where monthly can take until the month closes. offset 0 = the latest
  // period that has finished.
  // Both live in the URL (#/changes?period=month&offset=2), so a period can be linked to.
  const [periodParam, setPeriodParam] = useHashParam('period', 'week')
  const [offsetParam, setOffsetParam] = useHashParam('offset', '0')
  const periodType: PeriodType = periodParam === 'month' ? 'month' : 'week'
  const offset = Math.max(0, Math.min(24, Number(offsetParam) || 0))
  // A link from the Overview names the exact period (#/changes?period=week&key=2026-11-08&focus=<id>):
  // the brief may be days old and the weekly window has moved since. Stepping or switching grain
  // leaves that period and goes back to "newest / earlier".
  const [keyParam, setKeyParam] = useHashParam('key', '')
  const [focusParam, setFocusParam] = useHashParam('focus', '')
  const [flash, setFlash] = useState('')
  const leaveLinked = () => { if (keyParam) setKeyParam(''); if (focusParam) setFocusParam('') }
  const setPeriodType = (p: PeriodType) => { leaveLinked(); setPeriodParam(p) }
  const setOffset = (fn: (o: number) => number) => { leaveLinked(); setOffsetParam(String(fn(keyParam ? 0 : offset))) }
  // Owner filter (#/changes?owner=alice). Rollups (meter, subscription) have no single owner.
  const [ownerParam, setOwnerParam] = useHashParam('owner', '')
  // Per-finding UI state.
  const [explaining, setExplaining] = useState<Record<string, boolean>>({})
  const [explainMsg, setExplainMsg] = useState<Record<string, string>>({})
  const [open, setOpen] = useState<Record<string, boolean>>({})
  // Sustained increases come from the savings detectors but are NOT savings — they are money
  // now being spent. They belong on this page, not in a savings total.
  const [increases, setIncreases] = useState<SavingsFinding[]>([])

  useEffect(() => {
    FinOpsApi.getSavings()
      .then((r) => setIncreases(r.increases ?? []))
      .catch(() => setIncreases([]))
  }, [])

  useEffect(() => {
    setLoading(true)
    setError(null)
    FinOpsApi.getCostSpikes(periodType, offset, keyParam || undefined)
      .then((r) => { setSpikes(r.spikes); setMeta(r) })
      .catch((e) => setError(e))
      .finally(() => setLoading(false))
  }, [periodType, offset, keyParam])

  // Scroll to the linked finding and highlight it for a moment.
  useEffect(() => {
    if (loading || !focusParam) return
    const el = document.getElementById(`spike-${focusParam}`)
    if (!el) return
    el.scrollIntoView({ behavior: 'smooth', block: 'center' })
    setFlash(focusParam)
    const timer = setTimeout(() => setFlash(''), 4000)
    return () => clearTimeout(timer)
  }, [loading, focusParam, spikes])

  const applyResult = (id: string, r: Partial<ExplainSpikeResponse>) => {
    setSpikes((prev) =>
      prev.map((x) => {
        if (x.id !== id) return x
        const next: CostSpike = { ...x }
        if (r.evidence) { next.evidence = r.evidence; next.evidenceStatus = r.evidenceStatus }
        if (r.explanationStatus === 'explained') {
          next.headline = r.headline ?? null
          next.cause = r.cause ?? null
          next.recommendation = r.recommendation ?? null
          next.citedFacts = r.citedFacts ?? []
          next.explained = r.explained
          next.grounded = r.grounded ?? true
        }
        if (r.explanationStatus) next.explanationStatus = r.explanationStatus
        return next
      }),
    )
  }

  // Gather evidence (if missing) and explain one finding. Admin-only server-side.
  const explain = async (s: CostSpike, refreshEvidence: boolean) => {
    setExplaining((p) => ({ ...p, [s.id]: true }))
    setExplainMsg((p) => { const n = { ...p }; delete n[s.id]; return n })
    try {
      const r = await FinOpsApi.explainSpike(s.id, s.periodType, s.period, refreshEvidence)
      applyResult(s.id, r)
      if (r.message) setExplainMsg((p) => ({ ...p, [s.id]: r.message! }))
      if (r.evidence) setOpen((p) => ({ ...p, [s.id]: true }))
    } catch (e) {
      let msg = t.spikes.couldNotRefresh
      if (e instanceof ApiError) {
        const body = e.body as Partial<ExplainSpikeResponse> | null
        if (body?.evidence) { applyResult(s.id, body); setOpen((p) => ({ ...p, [s.id]: true })) }
        if (e.status === 403) msg = t.spikes.adminOnly
        else if (e.status === 429) msg = e.serverMessage ?? t.spikes.aiLimit
        else if (e.serverMessage) msg = e.serverMessage
      }
      setExplainMsg((p) => ({ ...p, [s.id]: msg }))
    } finally {
      setExplaining((p) => { const n = { ...p }; delete n[s.id]; return n })
    }
  }

  const ownerOptions = useMemo(() => {
    const counts = new Map<string, number>()
    for (const s of spikes) { const k = ownerKey(s.allocation); counts.set(k, (counts.get(k) ?? 0) + 1) }
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], locale()))
  }, [spikes])
  // #/changes?hideResolved=1 — increases that have already fallen back are kept by default
  // (the period did cost more), greyed and last.
  const [hideResolvedParam, setHideResolvedParam] = useHashParam('hideResolved', '')
  const hideResolved = hideResolvedParam === '1'
  const [methodOpen, setMethodOpen] = useState(false)
  const resolvedCount = useMemo(() => spikes.filter((s) => stateOf(s) === 'resolved').length, [spikes])
  const shown = useMemo(
    () => spikes
      .filter((s) => !ownerParam || ownerKey(s.allocation) === ownerParam)
      .filter((s) => !hideResolved || stateOf(s) !== 'resolved' || s.id === focusParam),
    [spikes, ownerParam, hideResolved, focusParam],
  )

  // A short list isn't evidence that detection is broken — it usually means one thing cleared
  // the bar and nothing else did. State the bar so that reads as a result, not a malfunction.
  const thresholdSuffix =
    meta?.minDeltaUsd != null && meta?.minDeltaPct != null
      ? t.spikes.threshold(money(meta.minDeltaUsd), periodType === 'week', meta.minDeltaPct)
      : ''

  // Period picker: grain on the left, step back/forward through complete periods on the
  // right. Only settled periods exist, so there is never a partial one to misread.
  const picker = (
    <div className={styles.toolbar}>
      <TabList
        size="small"
        selectedValue={periodType}
        onTabSelect={(_e, d) => { setPeriodType(d.value as PeriodType); setOffset(() => 0) }}
        aria-label={t.spikes.detectionPeriod}
      >
        <Tab value="week">{t.spikes.last7}</Tab>
        <Tab value="month">{t.spikes.monthly}</Tab>
      </TabList>
      <div className={styles.spacer} />
      {ownerOptions.length > 1 && (
        <Dropdown
          size="small"
          aria-label={t.spikes.filterOwner}
          value={ownerParam ? t.spikes.ownerValue(ownerLabel(), ownerParam) : t.spikes.ownerAll(ownerLabel())}
          selectedOptions={[ownerParam]}
          onOptionSelect={(_e, d) => setOwnerParam(d.optionValue ?? '')}
          style={{ minWidth: '160px' }}
        >
          <Option value="" text={t.spikes.ownerAll(ownerLabel())}>{t.spikes.allOwners(ownerLabel().toLowerCase())}</Option>
          {ownerOptions.map(([o, n]) => (
            <Option key={o} value={o} text={t.spikes.ownerValue(ownerLabel(), o)}>{`${o} (${n})`}</Option>
          ))}
        </Dropdown>
      )}
      <Button size="small" appearance="subtle" icon={<ChevronLeft16Regular />} onClick={() => setOffset((o) => o + 1)}>
        {t.spikes.earlier}
      </Button>
      <Text weight="semibold">{periodLabel(meta)}</Text>
      <ExportButton
        fileBase={`cost-changes-${periodType}-${meta?.period ?? 'latest'}`}
        rows={shown}
        columns={[
          { header: t.spikes.csv.periodStart, value: (s) => s.periodStart },
          { header: t.spikes.csv.periodEnd, value: (s) => s.periodEnd },
          { header: t.spikes.csv.grain, value: (s) => s.dimension ?? 'resource' },
          { header: t.spikes.csv.subscription, value: (s) => s.scopeName || s.scope },
          { header: t.spikes.csv.resource, value: (s) => s.resourceName || s.resourceId },
          { header: t.spikes.csv.resourceId, value: (s) => s.resourceId },
          { header: t.spikes.csv.meter, value: (s) => s.meter },
          { header: ownerLabel(), value: (s) => ownerOf(s.allocation) },
          { header: t.spikes.csv.allocation, value: (s) => allocationSummary(s.allocation) },
          { header: t.spikes.csv.typical(code), value: (s) => convert(s.baselineUsd) },
          { header: t.spikes.csv.thisPeriod(code), value: (s) => convert(s.spikeUsd) },
          { header: t.spikes.csv.increase(code), value: (s) => convert(s.deltaUsd) },
          { header: t.spikes.csv.increasePct, value: (s) => s.deltaPct },
          { header: t.spikes.csv.newSpend, value: (s) => s.isNew },
          { header: t.spikes.csv.alreadyFell, value: (s) => stateOf(s) === 'resolved' },
          { header: t.spikes.csv.state, value: (s) => stateOf(s) },
          { header: t.spikes.csv.currentLevel(code), value: (s) => (s.currentDailyUsd != null ? convert(s.currentDailyUsd * periodDays(s)) : '') },
          { header: t.spikes.csv.currentAsOf, value: (s) => s.currentAsOf ?? '' },
          { header: t.spikes.csv.fallPct, value: (s) => s.fallPct ?? '' },
          { header: t.spikes.csv.fallSince, value: (s) => s.fallSince ?? '' },
          { header: t.spikes.csv.endLevel(code), value: (s) => (s.exitRunRateUsd != null ? convert(s.exitRunRateUsd) : '') },
          { header: t.spikes.csv.drove, value: (s) => evidenceSummary(s.evidence) ?? '' },
          { header: t.spikes.csv.explanation, value: (s) => (s.headline ? `${s.headline}. ${s.cause ?? ''}` : '') },
          { header: t.spikes.csv.explained, value: (s) => !!s.explained },
          { header: t.spikes.csv.nextStep, value: (s) => s.recommendation ?? '' },
        ]}
      />
      <Button
        size="small"
        appearance="subtle"
        icon={<ChevronRight16Regular />}
        disabled={offset === 0}
        onClick={() => setOffset((o) => Math.max(0, o - 1))}
      >
        {t.spikes.later}
      </Button>
    </div>
  )

  const body = loading ? (
    <Spinner label={t.spikes.loading} />
  ) : error ? (
    <ErrorNote error={error} what={t.errors.what.changes} />
  ) : !meta?.period ? (
    <Text className={styles.muted}>
      {t.spikes.noPeriod(periodType === 'month')}
    </Text>
  ) : !meta.analyzed ? (
    // The API says why. Only 'pending' means "wait for tonight" — the other reasons are
    // waiting on history that no nightly run can conjure.
    <Text className={styles.muted}>
      {meta.detail
        ? t.spikes.notAnalysed(periodLabel(meta), meta.detail)
        : t.spikes.notAnalysedYet(periodLabel(meta))}
    </Text>
  ) : spikes.length === 0 ? (
    <Text className={styles.muted}>
      {t.spikes.noneLarge(periodLabel(meta), thresholdSuffix)}
    </Text>
  ) : null

  const focusMissing = !!focusParam && !spikes.some((s) => s.id === focusParam)
  const method = !loading && !error && meta?.period ? (
    <>
      {keyParam && (
        <div className={styles.methodBar}>
          <Text size={200} className={styles.muted}>
            {t.spikes.linkedPeriod(periodLabel(meta))}{focusMissing ? ` ${t.spikes.linkedMissing}` : ''}
          </Text>
          <Button size="small" appearance="transparent" onClick={() => { leaveLinked(); setOffsetParam('0') }}>
            {t.spikes.showNewest}
          </Button>
        </div>
      )}
      <div className={styles.methodBar}>
        <Button
          size="small"
          appearance="subtle"
          icon={<Info16Regular />}
          aria-expanded={methodOpen}
          onClick={() => setMethodOpen((o) => !o)}
        >
          {t.spikes.howTitle} {methodOpen ? <ChevronUp16Regular /> : <ChevronDown16Regular />}
        </Button>
        <div className={styles.spacer} />
        {resolvedCount > 0 && (
          <Switch
            checked={hideResolved}
            onChange={(_e, d) => setHideResolvedParam(d.checked ? '1' : '')}
            label={`${t.spikes.hideResolved} (${resolvedCount})`}
          />
        )}
      </div>
      {methodOpen && <MethodPanel meta={meta} money={money} />}
    </>
  ) : null

  return (
    <div className={styles.root}>
      {picker}
      {method}
      {body}
      {!loading && !error && ownerParam && shown.length === 0 && spikes.length > 0 && (
        <Text className={styles.muted}>{t.spikes.noneForOwner(periodLabel(meta), ownerParam)}</Text>
      )}
      {!loading && !error && shown.map((s) => {
        // A meter/subscription rollup: the increase is spread across many resources, so
        // there is no single resource to link to or blame.
        const isRollup = s.dimension === 'meter' || s.dimension === 'subscription'
        const scopeLabel = s.scopeName || (s.scope ? t.spikes.subscriptionShort(shortGuid(s.scope)) : t.spikes.tenant)
        const per = s.periodType === 'week' ? t.spikes.perWeek : t.spikes.perMonth
        const title = isRollup
          ? (s.dimension === 'meter' ? t.spikes.meterIn(s.meter || t.spikes.unlabelledMeter, scopeLabel) : scopeLabel)
          : (s.resourceName || s.resourceId.split('/').pop() || t.spikes.thisResource)
        const hasEvidence = !!s.evidence
        // Rows written before the evidence rework may carry text that was never grounded in
        // evidence — say so rather than present it as an explanation.
        const legacyText = !!s.headline && !hasEvidence
        const isOpen = open[s.id] ?? false
        const summary = evidenceSummary(s.evidence)
        const state = stateOf(s)
        const resolved = state === 'resolved'
        // Resolved and decreasing findings are both "not getting worse": muted, not red.
        const settling = state !== 'open'
        const days = periodDays(s)
        // "−42 % since 3 Nov" — how far the daily cost has fallen, from the step down (or the
        // period's average day when there was no clear step) to the latest settled days.
        const fallPct = s.fallPct != null && s.fallPct < 0 ? pctLabel(s.fallPct) : null
        const fallText = fallPct
          ? (s.fallSince ? t.spikes.fallSince(fallPct, dayLabel(s.fallSince)) : t.spikes.fallVsAverage(fallPct))
          : null
        const thinBaseline = s.baselinePeriods != null && s.baselinePeriodsOf != null && s.baselinePeriods < s.baselinePeriodsOf
        return (
          <div
            key={s.id}
            id={`spike-${s.id}`}
            className={styles.card}
            style={{
              ...(resolved
                ? { borderLeftColor: tokens.colorPaletteGreenBorder2, opacity: 0.85 }
                : state === 'decreasing' ? { borderLeftColor: tokens.colorNeutralStroke1 }
                : isRollup ? { borderLeftColor: tokens.colorPaletteDarkOrangeBorderActive } : {}),
              // The finding a link from the Overview pointed at.
              ...(s.id === focusParam ? { outline: `2px solid ${tokens.colorBrandStroke1}`, outlineOffset: '2px' } : {}),
              ...(s.id === flash ? { boxShadow: tokens.shadow16, transition: 'box-shadow 0.4s' } : {}),
            }}
          >
            <div className={styles.head}>
              {isRollup ? (
                <div className={styles.rollupHead}>
                  <Text className={styles.rollupName}>
                    {s.dimension === 'meter' ? s.meter || t.spikes.unlabelledMeter : scopeLabel}
                  </Text>
                  <Text size={200} className={styles.muted}>
                    {s.dimension === 'meter' ? t.spikes.allUsageIn(s.meter || t.spikes.usage, scopeLabel) : t.spikes.wholeSubscription}
                  </Text>
                </div>
              ) : (
                <div>
                  <ResourceRef resourceId={s.resourceId} displayName={s.resourceName} meter={s.meter} />
                  {s.allocation && (
                    <Text size={200} className={styles.muted} title={allocationSummary(s.allocation) || t.spikes.noAllocation}>
                      {ownerLabel()}: {ownerOf(s.allocation) || t.spikes.untagged}
                    </Text>
                  )}
                </div>
              )}
              <div className={styles.spacer} />
              <div className={styles.headRight}>
                <Text size={400} className={settling ? styles.deltaResolved : styles.delta} weight="semibold">
                  +{usd(s.deltaUsd)}{per}
                </Text>
                {resolved && (
                  <Badge appearance="filled" color="success" title={t.spikes.resolvedHint}>
                    {fallText
                      ? `${t.spikes.stateResolved} · ${fallText}`
                      : s.steppedDownOn ? t.spikes.stateResolvedSince(dayLabel(s.steppedDownOn)) : t.spikes.stateResolved}
                  </Badge>
                )}
                {state === 'decreasing' && (
                  <Badge appearance="tint" color="informative" title={t.spikes.decreasingHint}>
                    {t.spikes.stateDecreasing}
                    {fallText ? ` · ${fallText}` : s.steppedDownOn ? ` · ${t.spikes.fellOn(dayLabel(s.steppedDownOn))}` : ''}
                  </Badge>
                )}
                {s.isNew ? (
                  <Badge appearance="tint" color="brand">{t.spikes.newSpend}</Badge>
                ) : s.deltaPct != null ? (
                  <Badge appearance="tint" color="danger">+{s.deltaPct.toFixed(0)}%</Badge>
                ) : null}
                {isRollup && <Badge appearance="tint" color="warning">{t.spikes.spread}</Badge>}
              </div>
            </div>

            {/* Deterministic figures — always shown. */}
            <div className={styles.figures}>
              <Figure label={(s.periodType === 'week' ? t.spikes.typicalWeek : t.spikes.typicalMonth) +
                (thinBaseline ? t.spikes.typicalOf(s.baselinePeriods!, s.baselinePeriodsOf!) : '')}>{usd(s.baselineUsd)}</Figure>
              <Figure label={s.periodType === 'week' ? t.spikes.thisWindow : periodLabel(meta)}>{usd(s.spikeUsd)}</Figure>
              <Figure label={t.spikes.increase}>+{usd(s.deltaUsd)}{per}</Figure>
              {isRollup && s.unexplainedUsd != null && (
                <Figure label={t.spikes.notFlagged}>+{usd(s.unexplainedUsd)}{per}</Figure>
              )}
              {s.exitRunRateUsd != null && (
                <Figure label={t.spikes.endLevel}>
                  {usd(s.exitRunRateUsd)}{per}{s.steppedDownOn ? ` (${t.spikes.fellOn(dayLabel(s.steppedDownOn))})` : ''}
                </Figure>
              )}
              {s.currentDailyUsd != null && s.currentAsOf && (
                <div title={t.spikes.currentLevelHint(3, dayLabel(s.currentAsOf))}>
                  <Figure label={`${t.spikes.currentLevel} · ${dayLabel(s.currentAsOf)}`}>
                    {usd(s.currentDailyUsd * days)}{per}
                  </Figure>
                </div>
              )}
              {fallPct && s.fallFromDailyUsd != null && s.currentDailyUsd != null && (
                <div title={t.spikes.fallHint(usd(s.fallFromDailyUsd), usd(s.currentDailyUsd), s.fallSince ? dayLabel(s.fallSince) : null)}>
                  <Figure label={t.spikes.fallLabel(s.fallSince ? dayLabel(s.fallSince) : null)}>{fallPct}</Figure>
                </div>
              )}
              <Figure label={t.spikes.period}>{s.periodStart} → {s.periodEnd}</Figure>
            </div>

            {/* Written explanation — only ever from evidence, with its citations. */}
            {s.headline && !legacyText ? (
              <div className={`${styles.explanation} ${s.explained ? '' : styles.explanationOpen}`}>
                <div className={styles.explanationHead}>
                  <Sparkle16Regular className={styles.aiIcon} />
                  <Text weight="semibold">{s.headline}</Text>
                  {s.explained
                    ? <Badge appearance="tint" color="success">{t.spikes.explained}</Badge>
                    : <Badge appearance="tint" color="warning">{t.spikes.notRecorded}</Badge>}
                  {!s.grounded && <Badge appearance="tint" color="warning">{t.spikes.unverified}</Badge>}
                </div>
                {s.cause && <Text size={200}><b>{s.explained ? t.spikes.cause : t.spikes.known}:</b> {s.cause}</Text>}
                {s.recommendation && <Text size={200}><b>{t.spikes.nextStep}</b> {s.recommendation}</Text>}
                {!!s.citedFacts?.length && (
                  <Text size={100} className={styles.muted}>{t.spikes.basedOn(s.citedFacts.join(', '))}</Text>
                )}
              </div>
            ) : legacyText ? (
              <div className={styles.pending}>
                <Info16Regular />
                <Text size={200}>
                  {t.spikes.legacy}
                  {' '}{noExplanationText(s)}
                </Text>
              </div>
            ) : (
              <div className={styles.pending}>
                <Info16Regular />
                <Text size={200}>{noExplanationText(s)}</Text>
              </div>
            )}

            {hasEvidence && (
              <div className={styles.evidenceBox}>
                <Button
                  appearance="transparent"
                  size="small"
                  icon={isOpen ? <ChevronUp16Regular /> : <ChevronDown16Regular />}
                  iconPosition="after"
                  onClick={() => setOpen((p) => ({ ...p, [s.id]: !isOpen }))}
                  aria-expanded={isOpen}
                >
                  {t.spikes.whatChanged}{summary && !isOpen ? ` — ${summary}` : ''}
                </Button>
                {isOpen && s.evidence && (
                  <EvidencePanel evidence={s.evidence} periodType={s.periodType} citedFacts={s.citedFacts ?? []} />
                )}
              </div>
            )}

            <div className={styles.actions}>
              {!hasEvidence ? (
                <Button
                  appearance="subtle"
                  size="small"
                  icon={<DocumentSearch16Regular />}
                  disabled={!!explaining[s.id]}
                  onClick={() => void explain(s, false)}
                >
                  {t.spikes.findOut}
                </Button>
              ) : (
                <Button
                  appearance="subtle"
                  size="small"
                  icon={<ArrowSync16Regular />}
                  disabled={!!explaining[s.id]}
                  onClick={() => void explain(s, s.evidenceStatus !== 'complete')}
                  title={s.evidenceStatus !== 'complete' ? t.spikes.gatherAgain : t.spikes.explainAgain}
                >
                  {s.headline && !legacyText ? t.spikes.reExplain : t.spikes.explainThis}
                </Button>
              )}
              <AskAboutButton
                question={t.spikes.askWhy(title)}
                context={{
                  kind: 'cost-change',
                  title,
                  subscriptionId: subscriptionIdOf(s.scope) ?? subscriptionIdOf(s.resourceId),
                  subscriptionName: s.scopeName ?? null,
                  resourceId: isRollup ? null : s.resourceId,
                  resourceName: isRollup ? null : s.resourceName ?? null,
                  meter: s.meter || null,
                  periodStart: s.periodStart,
                  periodEnd: s.periodEnd,
                  summary: `Cost rose from ${s.baselineUsd.toFixed(0)} USD (typical) to ${s.spikeUsd.toFixed(0)} USD in ${s.periodStart}..${s.periodEnd}.` +
                    (s.exitRunRateUsd != null ? ` At the end of the period it ran at ${s.exitRunRateUsd.toFixed(0)} USD per period${s.steppedDownOn ? `, after falling on ${s.steppedDownOn}` : ''}.` : '') +
                    (s.currentDailyUsd != null && s.currentAsOf ? ` Over the 3 settled days to ${s.currentAsOf} it ran at ${(s.currentDailyUsd * days).toFixed(0)} USD per period (state: ${state}).` : ` State: ${state}.`) +
                    (summary ? ` Evidence: ${summary}.` : '') + (s.explained && s.cause ? ` Explanation: ${s.cause}` : ''),
                }}
              />
              {explaining[s.id] && <Spinner size="tiny" label={t.spikes.working} />}
              {explainMsg[s.id] && <Text size={200} className={styles.muted}>{explainMsg[s.id]}</Text>}
            </div>
          </div>
        )
      })}
      {increases.length > 0 && (
        <div className={styles.increases}>
          <Text size={400} weight="semibold">{t.spikes.sustained}</Text>
          <Text size={200} className={styles.muted}>{t.spikes.sustainedHint}</Text>
          {increases.slice(0, 8).map((i) => (
            <div key={i.id} className={styles.increaseRow}>
              <ResourceRef resourceId={i.resourceId} displayName={i.resourceName} />
              <div className={styles.spacer} />
              <Text weight="semibold" className={styles.delta}>+{usd(i.estMonthlySavingsUsd)}{t.spikes.perMonth}</Text>
              <AskAboutButton
                compact
                question={t.spikes.askStep(i.resourceName || t.spikes.thisResource)}
                context={{
                  kind: 'cost-change',
                  title: i.resourceName || t.spikes.sustainedIncrease,
                  subscriptionId: subscriptionIdOf(i.resourceId),
                  subscriptionName: i.subscriptionName ?? null,
                  resourceId: i.resourceId,
                  resourceName: i.resourceName ?? null,
                  summary: i.detail,
                }}
              />
            </div>
          ))}
        </div>
      )}
      {!loading && !error && spikes.length > 0 && thresholdSuffix && (
        <Text size={200} className={styles.muted}>
          {t.spikes.showing(spikes.length, thresholdSuffix.replace(/^ — /, ': '))}
        </Text>
      )}
    </div>
  )
}
