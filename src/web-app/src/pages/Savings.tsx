import { useEffect, useMemo, useState, type ReactNode } from 'react'
import {
  Text,
  Badge,
  Button,
  Spinner,
  SearchBox,
  Input,
  Dropdown,
  Option,
  type DropdownProps,
  Menu,
  MenuButton,
  MenuTrigger,
  MenuPopover,
  MenuList,
  MenuItem,
  Table,
  TableHeader,
  TableHeaderCell,
  TableRow,
  TableBody,
  TableCell,
  makeStyles,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import { DismissCircle16Regular } from '@fluentui/react-icons'
import { ResourceRef } from '../components/ResourceRef'
import { NumHeaderCell } from '../components/NumHeaderCell'
import { parseResourceId, shortGuid } from '../lib/resource'
import { ApiError, FinOpsApi, type SavingsStatus, type SavingsTier } from '../api/client'
import { useCurrency } from '../lib/currency'
import { AskAboutButton } from '../components/AskAboutButton'
import { ExportButton } from '../components/ExportButton'
import { ErrorNote } from '../components/ErrorNote'
import { CommitmentsPanel } from '../components/CommitmentsPanel'
import { useHashListParam, useHashParam } from '../lib/route'
import { allocationKeys, allocationSummary, ownerKey, ownerLabel, ownerOf, tagLabel, type Allocation } from '../lib/allocation'
import { t, locale } from '../i18n'

const useStyles = makeStyles({
  root: { rowGap: tokens.spacingVerticalM, display: 'flex', flexDirection: 'column' },
  summary: { display: 'flex', alignItems: 'baseline', columnGap: tokens.spacingHorizontalM, flexWrap: 'wrap' },
  total: { color: tokens.colorPaletteGreenForeground1 },
  // Azure-portal-style filter bar: a flat gray strip carrying white bordered pills,
  // like the Cost analysis toolbar. Labels are baked into the pills, two-tone.
  toolbar: {
    display: 'flex',
    flexDirection: 'row',
    columnGap: tokens.spacingHorizontalS,
    rowGap: tokens.spacingVerticalS,
    flexWrap: 'wrap',
    alignItems: 'center',
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorNeutralBackground2,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
  },
  search: {
    minWidth: '220px',
    maxWidth: '320px',
    flexGrow: 1,
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius('16px'),
  },
  pill: {
    minWidth: 'unset',
    maxWidth: '300px',
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke1),
    ...shorthands.borderRadius('16px'),
    ':hover': { ...shorthands.borderColor(tokens.colorBrandStroke1) },
    ':focus-within': { ...shorthands.borderColor(tokens.colorBrandStroke1) },
  },
  pillContent: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
  pillLabel: { color: tokens.colorNeutralForeground3 },
  pillValue: { fontWeight: tokens.fontWeightSemibold, color: tokens.colorNeutralForeground1 },
  optionCount: { color: tokens.colorNeutralForeground3 },
  minInput: {
    width: '196px',
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke1),
    ...shorthands.borderRadius('16px'),
    ':hover': { ...shorthands.borderColor(tokens.colorBrandStroke1) },
    ':focus-within': { ...shorthands.borderColor(tokens.colorBrandStroke1) },
    // The typed value reads like the pill value (semibold); hide the useless number
    // spinner arrows so the field is all room for the amount.
    '& input': { fontWeight: tokens.fontWeightSemibold, textAlign: 'right' },
    '& input::-webkit-outer-spin-button, & input::-webkit-inner-spin-button': { WebkitAppearance: 'none', margin: 0 },
    '& input[type=number]': { MozAppearance: 'textfield' },
  },
  // Long option lists (e.g. 40 subscriptions) scroll instead of growing unbounded.
  // !important because Fluent's positioning writes a viewport-based max-height INLINE.
  listbox: { maxHeight: '320px !important', overflowY: 'auto', minWidth: '260px' },
  tablePanel: {
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
    overflowX: 'auto',
  },
  titleCell: { display: 'flex', flexDirection: 'column', rowGap: '2px', ...shorthands.padding(tokens.spacingVerticalXS, 0), minWidth: 0, flexGrow: 1 },
  titleRow: { display: 'flex', alignItems: 'flex-start', columnGap: tokens.spacingHorizontalXS },
  titleLine: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalXS, flexWrap: 'wrap' },
  bodyText: {
    color: tokens.colorNeutralForeground3,
    display: '-webkit-box',
    WebkitLineClamp: 2,
    WebkitBoxOrient: 'vertical',
    overflow: 'hidden',
  },
  savings: { color: tokens.colorPaletteGreenForeground1, whiteSpace: 'nowrap' },
  badgeStack: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start', rowGap: '2px' },
  numCol: { textAlign: 'right' },
  muted: { color: tokens.colorNeutralForeground3 },
  empty: { color: tokens.colorNeutralForeground3, ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL) },
  error: { color: tokens.colorPaletteRedForeground1 },
})

type TagColor = 'success' | 'warning' | 'danger' | 'informative' | 'brand' | 'subtle'

// A unified row across the app's own analysis and Azure Advisor, with the attributes the
// filters cut by parsed out once up front.
type Row = {
  key: string
  /** Server-side finding id — only our own findings can carry a status. */
  findingId?: string
  tier: SavingsTier
  status: SavingsStatus
  statusReason?: string
  reopened?: boolean
  source: 'Analysis' | 'Advisor'
  category: string
  title: string
  body: string
  resourceId: string
  resourceName?: string | null
  /** Owner / cost centre / environment / application, as tagged (null = not a resource). */
  allocation?: Allocation | null
  /** Comparable USD figure. 0 when the source amount could not be converted to USD. */
  est: number
  /**
   * Advisor reports savings in the BILLING currency, not USD. When there is no FX rate for
   * it the amount is shown as-is in its own currency and left out of every USD total —
   * adding a EUR number to a USD one (and then converting the sum for display) is simply
   * a wrong figure.
   */
  converted: boolean
  nativeAmount: number
  nativeCurrency: string
  /** Upper bound when an Advisor rec was merged in (e.g. shutdown vs downsize estimate). */
  estHigh?: number
  /** Advisor impact tag carried over on a merged row. */
  advisorTag?: string
  tag?: string
  tagColor: TagColor
  // filter attributes
  subKey: string
  subLabel: string
  /** True when subLabel is a real name (stamped or derived), not a shortened guid. */
  subNameKnown: boolean
  rgKey: string
  rgLabel: string
  typeLabel: string
  ownerKey: string
}

// What each tier means, in the words shown on hover. The distinction is the whole point of the
// headline figure: only certain and likely are added up.
const tierColor = (tier: SavingsTier): TagColor =>
  tier === 'certain' ? 'success' : tier === 'likely' ? 'brand' : 'informative'
// Confidence / impact come from the server as high / medium / low (Advisor may say anything else).
const levelLabel = (v: string) => t.sav.level[(v || '').toLowerCase()] ?? v

const confColor = (c: string): TagColor =>
  c === 'high' ? 'success' : c === 'medium' ? 'warning' : 'informative'
const impactColor = (i: string): TagColor =>
  (i || '').toLowerCase() === 'high' ? 'danger' : (i || '').toLowerCase() === 'medium' ? 'warning' : 'informative'

// Our finding and an Advisor recommendation for the SAME resource describe the same money
// (an idle VM: our downsize ≈ the price difference, Advisor's shutdown ≈ its whole cost; an
// unattached disk; a Log Analytics tier). Listing both would double-count the total, so they
// merge into ONE row: the estimate shown as a range, the conservative (low) number used for
// sorting and totals, both source/impact tags kept. Only resource-level rows merge — billing-
// scope recommendations (reservation and savings-plan purchases) have no resource to match on.
function mergeOverlaps(rows: Row[]): Row[] {
  const twinByAnalysisKey = new Map<string, Row>()
  const consumed = new Set<string>()
  for (const r of rows) {
    if (r.source !== 'Analysis' || !r.resourceId.includes('/providers/') || r.tier === 'not-a-saving') continue
    const twin = rows.find(
      (o) => !consumed.has(o.key) && o.source === 'Advisor' && o.resourceId.toLowerCase() === r.resourceId.toLowerCase(),
    )
    if (twin) { twinByAnalysisKey.set(r.key, twin); consumed.add(twin.key) }
  }
  return rows
    .filter((r) => !consumed.has(r.key))
    .map((r) => {
      const twin = twinByAnalysisKey.get(r.key)
      // Only widen into a range when the Advisor twin has a comparable USD figure —
      // an unconverted twin would otherwise drag the low end to 0.
      return twin && twin.converted
        ? { ...r, est: Math.min(r.est, twin.est), estHigh: Math.max(r.est, twin.est), advisorTag: twin.tag }
        : twin
          ? { ...r, advisorTag: twin.tag }
          : r
    })
}

// Amounts we could not convert are shown in their own currency, never relabelled as USD.
function formatNative(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat(locale(), { style: 'currency', currency, maximumFractionDigits: 0 }).format(amount)
  } catch {
    return `${Math.round(amount).toLocaleString(locale())} ${currency}`
  }
}

// Billing-scope recommendations (savings plans / reservations) have no resource behind
// their GUID — label them by what the recommendation is about instead.
function guidFallbackLabel(row: Row): string {
  const text = `${row.title} ${row.category}`.toLowerCase()
  if (text.includes('savings plan')) return t.sav.planBilling
  if (text.includes('reserv')) return t.sav.reservationBilling
  return t.sav.billingScope
}

function toRow(
  base: Omit<Row, 'subKey' | 'subLabel' | 'subNameKnown' | 'rgKey' | 'rgLabel' | 'typeLabel' | 'ownerKey'>,
  subscriptionName?: string | null,
): Row {
  const p = parseResourceId(base.resourceId)
  // Best subscription name available: the stamped one, or — for subscription-scoped rows
  // (Advisor savings-plan recs) — the resolved resource name IS the subscription's name.
  const known =
    subscriptionName?.trim() ||
    (p.friendlyType === 'Subscription' ? base.resourceName?.trim() ?? '' : '')
  return {
    ...base,
    subKey: p.subscriptionId?.toLowerCase() ?? 'none',
    subLabel: known
      || (p.subscriptionId ? t.sav.subscriptionShort(shortGuid(p.subscriptionId)) : t.sav.billingTenant),
    subNameKnown: !!known || !p.subscriptionId,
    rgKey: p.resourceGroup?.toLowerCase() ?? 'none',
    rgLabel: p.resourceGroup ?? t.sav.noGroup,
    typeLabel: p.friendlyType,
    ownerKey: ownerKey(base.allocation),
  }
}

// One filter pill, Azure-portal style: muted label + semibold current value inside a
// white bordered pill. The Dropdown's button slot carries the two-tone content.
function FilterPill(props: {
  label: string
  display: string
  multiselect?: boolean
  selectedOptions: string[]
  onOptionSelect: NonNullable<DropdownProps['onOptionSelect']>
  listbox: DropdownProps['listbox']
  children: ReactNode
}) {
  const styles = useStyles()
  return (
    <Dropdown
      className={styles.pill}
      aria-label={t.sav.filterBy(props.label)}
      button={{
        children: (
          <span className={styles.pillContent}>
            <span className={styles.pillLabel}>{props.label}: </span>
            <span className={styles.pillValue}>{props.display}</span>
          </span>
        ),
      }}
      multiselect={props.multiselect}
      selectedOptions={props.selectedOptions}
      onOptionSelect={props.onOptionSelect}
      listbox={props.listbox}
    >
      {props.children}
    </Dropdown>
  )
}

type SortKey = 'est-desc' | 'est-asc' | 'name-asc'

export function Savings() {
  const styles = useStyles()
  const { money, toUsd, code, convert } = useCurrency()
  const usd = (n: number) => money(n)
  const [loading, setLoading] = useState(true)
  const [rows, setRows] = useState<Row[]>([])
  const [error, setError] = useState<unknown>(null)
  const [canSetStatus, setCanSetStatus] = useState(false)
  const [realised, setRealised] = useState(0)
  const [dismissedCount, setDismissedCount] = useState(0)
  const [dismissedParam, setDismissedParam] = useHashParam('dismissed', '0')
  const showDismissed = dismissedParam === '1'
  const setShowDismissed = (fn: (v: boolean) => boolean) => setDismissedParam(fn(showDismissed) ? '1' : '0')
  const [busyId, setBusyId] = useState<string | null>(null)
  const [statusMsg, setStatusMsg] = useState<string | null>(null)

  // Filter state
  // Every filter lives in the URL (#/savings?subs=…&sort=…), so a filtered view can be linked.
  const [search, setSearch] = useHashParam('q', '')
  const [selSubs, setSelSubs] = useHashListParam('subs')
  const [selRgs, setSelRgs] = useHashListParam('rgs')
  const [selTypes, setSelTypes] = useHashListParam('types')
  const [selOwners, setSelOwners] = useHashListParam('owners')
  const [sourceParam, setSourceParam] = useHashParam('source', 'all')
  const source = (['all', 'Analysis', 'Advisor'].includes(sourceParam) ? sourceParam : 'all') as 'all' | 'Analysis' | 'Advisor'
  const setSource = (v: 'all' | 'Analysis' | 'Advisor') => setSourceParam(v)
  // Min saving is entered in the DISPLAY currency; converted to USD at filter time.
  const [minInput, setMinInput] = useHashParam('min', '')
  const [sortParam, setSortParam] = useHashParam('sort', 'est-desc')
  const sort = (['est-desc', 'est-asc', 'name-asc'].includes(sortParam) ? sortParam : 'est-desc') as SortKey
  const setSort = (v: SortKey) => setSortParam(v)

  const minValue = Number(minInput)
  const hasMin = minInput.trim() !== '' && Number.isFinite(minValue) && minValue > 0

  const filtersActive =
    search.trim() !== '' || selSubs.length > 0 || selRgs.length > 0 || selTypes.length > 0 ||
    selOwners.length > 0 || source !== 'all' || hasMin
  const clearFilters = () => {
    setSearch(''); setSelSubs([]); setSelRgs([]); setSelTypes([]); setSelOwners([]); setSource('all'); setMinInput('')
  }

  const load = (includeDismissed: boolean) => {
    // The app's own findings are the differentiator; Advisor is complementary. Pull both,
    // tolerate either failing, and merge into one list.
    return Promise.allSettled([FinOpsApi.getSavings(includeDismissed), FinOpsApi.getRecommendations()])
      .then(([savingsRes, advisorRes]) => {
        const merged: Row[] = []

        if (savingsRes.status === 'fulfilled') {
          setCanSetStatus(savingsRes.value.canSetStatus)
          setRealised(savingsRes.value.realisedThisMonthUsd ?? 0)
          setDismissedCount(savingsRes.value.dismissedCount ?? 0)
          for (const f of savingsRes.value.findings) {
            merged.push(toRow({
              key: `a-${f.id}`, findingId: f.id, tier: f.tier, status: f.status,
              statusReason: f.statusReason, reopened: f.reopened,
              source: 'Analysis', category: f.category || t.sav.other,
              title: f.title, body: f.detail,
              resourceId: f.resourceId, resourceName: f.resourceName, est: f.estMonthlySavingsUsd,
              allocation: f.allocation ?? null,
              // Our own detectors compute in USD from USD-normalized cost data.
              converted: true, nativeAmount: f.estMonthlySavingsUsd, nativeCurrency: 'USD',
              tag: f.confidence, tagColor: confColor(f.confidence),
            }, f.subscriptionName))
          }
        }
        if (advisorRes.status === 'fulfilled') {
          for (const r of advisorRes.value.recommendations) {
            merged.push(toRow({
              // Advisor rows carry no status of their own: Advisor decides when they go away.
              key: `v-${r.id}`, tier: r.converted ? 'likely' : 'indicative', status: 'open',
              source: 'Advisor', category: r.recommendationType || 'Advisor',
              title: r.solution || r.problem || t.sav.advisorRec, body: r.problem,
              resourceId: r.resourceId, resourceName: r.resourceName,
              allocation: r.allocation ?? null,
              est: r.converted ? r.estMonthlySavingsUsd : 0,
              converted: r.converted,
              nativeAmount: r.savingsAmount ?? r.estMonthlySavingsUsd,
              nativeCurrency: r.currency || 'USD',
              tag: r.impact, tagColor: impactColor(r.impact),
            }, r.subscriptionName))
          }
        }
        if (savingsRes.status === 'rejected' && advisorRes.status === 'rejected') {
          setError(savingsRes.reason)
          return
        }
        setRows(mergeOverlaps(merged))
      })
      .finally(() => setLoading(false))
  }

  useEffect(() => { void load(showDismissed) }, [showDismissed])

  // Record what is happening with a finding. Only our own findings can carry a status —
  // an Advisor recommendation disappears when Advisor stops returning it.
  const setStatus = async (r: Row, status: SavingsStatus) => {
    if (!r.findingId) return
    let reason = ''
    if (status === 'dismissed') {
      reason = window.prompt(t.sav.dismissWhy) ?? ''
    }
    setBusyId(r.key); setStatusMsg(null)
    try {
      const res = await FinOpsApi.setSavingsStatus(r.findingId, status, reason)
      setRows((prev) =>
        prev
          .map((x) => (x.key === r.key ? { ...x, status, statusReason: reason, reopened: false } : x))
          // A dismissal drops out of the list unless dismissed rows are being shown.
          .filter((x) => showDismissed || x.status !== 'dismissed'),
      )
      if (res.note) setStatusMsg(res.note)
      if (status === 'dismissed') setDismissedCount((n) => n + 1)
    } catch (e) {
      setStatusMsg(
        e instanceof ApiError && e.status === 403
          ? t.sav.adminOnly
          : e instanceof ApiError && e.serverMessage
            ? e.serverMessage
            : t.sav.couldNotSave,
      )
    } finally {
      setBusyId(null)
    }
  }

  // Canonical label per subscription: prefer a known name from ANY row of that
  // subscription, so one named row fixes the label everywhere.
  const subLabelByKey = useMemo(() => {
    const m = new Map<string, { label: string; known: boolean }>()
    for (const r of rows) {
      const cur = m.get(r.subKey)
      if (!cur || (!cur.known && r.subNameKnown)) m.set(r.subKey, { label: r.subLabel, known: r.subNameKnown })
    }
    return m
  }, [rows])
  const subLabel = (k: string) => subLabelByKey.get(k)?.label ?? k

  // Cascading option lists: Resource group narrows to the selected subscriptions,
  // Resource type narrows to both. Options always come from data that actually exists —
  // an option's count is how many opportunities it would match (portal-facet style).
  const subOptions = useMemo(() => {
    const counts = new Map<string, number>()
    for (const r of rows) counts.set(r.subKey, (counts.get(r.subKey) ?? 0) + 1)
    return [...subLabelByKey.entries()]
      .map(([k, v]) => [k, v.label, counts.get(k) ?? 0] as const)
      .sort((a, b) => a[1].localeCompare(b[1], locale()))
  }, [rows, subLabelByKey])
  const rowsForRg = useMemo(
    () => (selSubs.length ? rows.filter((r) => selSubs.includes(r.subKey)) : rows),
    [rows, selSubs],
  )
  const rgOptions = useMemo(() => {
    const labels = new Map<string, string>()
    const counts = new Map<string, number>()
    for (const r of rowsForRg) {
      if (r.rgKey === 'none') continue
      if (!labels.has(r.rgKey)) labels.set(r.rgKey, r.rgLabel)
      counts.set(r.rgKey, (counts.get(r.rgKey) ?? 0) + 1)
    }
    return [...labels.entries()]
      .map(([k, label]) => [k, label, counts.get(k) ?? 0] as const)
      .sort((a, b) => a[1].localeCompare(b[1], locale()))
  }, [rowsForRg])
  const rowsForType = useMemo(
    () => (selRgs.length ? rowsForRg.filter((r) => selRgs.includes(r.rgKey)) : rowsForRg),
    [rowsForRg, selRgs],
  )
  const typeOptions = useMemo(() => {
    const counts = new Map<string, number>()
    for (const r of rowsForType) counts.set(r.typeLabel, (counts.get(r.typeLabel) ?? 0) + 1)
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], locale()))
  }, [rowsForType])

  // When a broader filter changes, drop narrower selections that no longer apply.
  const onSubsChange = (next: string[]) => {
    setSelSubs(next)
    const rowsIn = next.length ? rows.filter((r) => next.includes(r.subKey)) : rows
    const validRgs = new Set(rowsIn.map((r) => r.rgKey))
    const nextRgs = selRgs.filter((k) => validRgs.has(k))
    setSelRgs(nextRgs)
    const rowsIn2 = nextRgs.length ? rowsIn.filter((r) => nextRgs.includes(r.rgKey)) : rowsIn
    const validTypes = new Set(rowsIn2.map((r) => r.typeLabel))
    setSelTypes(selTypes.filter((ty) => validTypes.has(ty)))
  }
  const onRgsChange = (next: string[]) => {
    setSelRgs(next)
    const base = selSubs.length ? rows.filter((r) => selSubs.includes(r.subKey)) : rows
    const rowsIn = next.length ? base.filter((r) => next.includes(r.rgKey)) : base
    const validTypes = new Set(rowsIn.map((r) => r.typeLabel))
    setSelTypes(selTypes.filter((ty) => validTypes.has(ty)))
  }

  const rowName = (r: Row) => r.resourceName || parseResourceId(r.resourceId).name

  // Owners present, with how many opportunities each would match.
  const ownerOptions = useMemo(() => {
    const counts = new Map<string, number>()
    for (const r of rows) counts.set(r.ownerKey, (counts.get(r.ownerKey) ?? 0) + 1)
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], locale()))
  }, [rows])
  const tagKeys = useMemo(() => allocationKeys(rows.map((r) => r.allocation)), [rows])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    const minUsd = hasMin ? toUsd(minValue) : 0
    const out = rows.filter((r) => {
      if (source !== 'all' && r.source !== source) return false
      if (selSubs.length && !selSubs.includes(r.subKey)) return false
      if (selRgs.length && !selRgs.includes(r.rgKey)) return false
      if (selTypes.length && !selTypes.includes(r.typeLabel)) return false
      if (selOwners.length && !selOwners.includes(r.ownerKey)) return false
      if (r.est < minUsd) return false
      if (q) {
        const hay = `${r.title} ${r.body} ${r.resourceName ?? ''} ${subLabel(r.subKey)} ${r.rgLabel} ${r.typeLabel} ${r.resourceId} ${allocationSummary(r.allocation)}`.toLowerCase()
        if (!hay.includes(q)) return false
      }
      return true
    })
    out.sort((a, b) =>
      sort === 'est-asc' ? a.est - b.est
        : sort === 'name-asc' ? rowName(a).localeCompare(rowName(b), locale())
          : b.est - a.est,
    )
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows, search, selSubs, selRgs, selTypes, selOwners, source, hasMin, minValue, sort, subLabelByKey])

  // What gets added up: converted amounts, in the two solid tiers, still on the table.
  // An indicative figure (no published price, or a reservation already pays for it) is shown
  // but never summed — a total that includes guesses is not a number anyone can act on.
  const countable = useMemo(
    () => filtered.filter((r) => r.converted && (r.tier === 'certain' || r.tier === 'likely') && (r.status === 'open' || r.status === 'in-progress')),
    [filtered],
  )
  const filteredTotal = useMemo(() => countable.reduce((s, r) => s + r.est, 0), [countable])
  const certainTotal = useMemo(
    () => countable.reduce((s, r) => (r.tier === 'certain' ? s + r.est : s), 0),
    [countable],
  )
  const likelyTotal = filteredTotal - certainTotal
  const indicativeCount = useMemo(() => filtered.filter((r) => r.tier === 'indicative').length, [filtered])
  const filteredUnconverted = useMemo(() => filtered.filter((r) => !r.converted).length, [filtered])

  // Current-value text shown inside a multiselect pill.
  const multiDisplay = (sel: string[], labelOf: (k: string) => string) =>
    sel.length === 0 ? t.sav.all : sel.length === 1 ? labelOf(sel[0]) : t.sav.selected(sel.length)

  const listboxSlot = { className: styles.listbox }

  if (loading) return <Spinner label={t.sav.loading} />
  if (error) return <ErrorNote error={error} what={t.errors.what.savings} />
  if (rows.length === 0)
    return <Text className={styles.muted}>{t.sav.none}</Text>

  return (
    <div className={styles.root}>
      <CommitmentsPanel />
      <div className={styles.summary}>
        <Text size={500} weight="semibold" className={styles.total}>{t.sav.available(usd(filteredTotal))}</Text>
        <Text size={300} className={styles.muted}>
          {t.sav.certainLikely(usd(certainTotal), usd(likelyTotal))}
          {indicativeCount > 0 && t.sav.indicativeCount(indicativeCount)}
          {realised > 0 && t.sav.realised(usd(realised))}
        </Text>
        <Text size={300} className={styles.muted}>
          {t.sav.showing(filtered.length, rows.length)}
          {rows.some((r) => r.estHigh != null) && t.sav.merged}
          {filteredUnconverted > 0 && t.sav.unconverted(filteredUnconverted)}
        </Text>
      </div>

      <div className={styles.toolbar}>
        <SearchBox
          className={styles.search}
          placeholder={t.sav.search}
          value={search}
          onChange={(_e, d) => setSearch(d.value)}
        />
        <FilterPill
          label={t.sav.subscription}
          display={multiDisplay(selSubs, subLabel)}
          multiselect
          selectedOptions={selSubs}
          onOptionSelect={(_e, d) => onSubsChange(d.selectedOptions)}
          listbox={listboxSlot}
        >
          {subOptions.map(([key, label, count]) => (
            <Option key={key} value={key} text={label}>
              {label} <span className={styles.optionCount}>({count})</span>
            </Option>
          ))}
        </FilterPill>
        <FilterPill
          label={t.sav.resourceGroup}
          display={multiDisplay(selRgs, (k) => rgOptions.find(([key]) => key === k)?.[1] ?? k)}
          multiselect
          selectedOptions={selRgs}
          onOptionSelect={(_e, d) => onRgsChange(d.selectedOptions)}
          listbox={listboxSlot}
        >
          {rgOptions.map(([key, label, count]) => (
            <Option key={key} value={key} text={label}>
              {label} <span className={styles.optionCount}>({count})</span>
            </Option>
          ))}
        </FilterPill>
        <FilterPill
          label={t.sav.type}
          display={multiDisplay(selTypes, (k) => k)}
          multiselect
          selectedOptions={selTypes}
          onOptionSelect={(_e, d) => setSelTypes(d.selectedOptions)}
          listbox={listboxSlot}
        >
          {typeOptions.map(([ty, count]) => (
            <Option key={ty} value={ty} text={ty}>
              {ty} <span className={styles.optionCount}>({count})</span>
            </Option>
          ))}
        </FilterPill>
        {ownerOptions.length > 1 && (
          <FilterPill
            label={ownerLabel()}
            display={multiDisplay(selOwners, (k) => k)}
            multiselect
            selectedOptions={selOwners}
            onOptionSelect={(_e, d) => setSelOwners(d.selectedOptions)}
            listbox={listboxSlot}
          >
            {ownerOptions.map(([o, count]) => (
              <Option key={o} value={o} text={o}>
                {o} <span className={styles.optionCount}>({count})</span>
              </Option>
            ))}
          </FilterPill>
        )}
        <FilterPill
          label={t.sav.sourceLabel}
          display={source === 'all' ? t.sav.all : t.sav.source[source]}
          selectedOptions={[source]}
          onOptionSelect={(_e, d) => setSource((d.optionValue as typeof source) ?? 'all')}
          listbox={listboxSlot}
        >
          <Option value="all">{t.sav.allSources}</Option>
          <Option value="Analysis">{t.sav.source.Analysis}</Option>
          <Option value="Advisor">{t.sav.source.Advisor}</Option>
        </FilterPill>
        <Input
          className={styles.minInput}
          type="number"
          min={0}
          size="small"
          appearance="filled-lighter"
          placeholder={t.sav.any}
          value={minInput}
          onChange={(_e, d) => setMinInput(d.value)}
          aria-label={t.sav.minLabel(code)}
          contentBefore={<Text size={200} className={styles.pillLabel}>{t.sav.min}</Text>}
          contentAfter={<Text size={200} className={styles.pillLabel}>{t.sav.perMonthCode(code)}</Text>}
        />
        <FilterPill
          label={t.sav.sort}
          display={sort === 'est-asc' ? t.sav.sortLowHigh : sort === 'name-asc' ? t.sav.sortName : t.sav.sortHighLow}
          selectedOptions={[sort]}
          onOptionSelect={(_e, d) => setSort((d.optionValue as SortKey) ?? 'est-desc')}
          listbox={listboxSlot}
        >
          <Option value="est-desc">{t.sav.sortHighLow}</Option>
          <Option value="est-asc">{t.sav.sortLowHigh}</Option>
          <Option value="name-asc">{t.sav.sortName}</Option>
        </FilterPill>
        <ExportButton
          fileBase="savings"
          rows={filtered}
          columns={[
            { header: t.sav.csv.recommendation, value: (r) => r.title },
            { header: t.sav.csv.detail, value: (r) => r.body },
            { header: t.sav.csv.tier, value: (r) => t.sav.tier[r.tier] ?? r.tier },
            { header: t.sav.csv.counted, value: (r) => r.converted && (r.tier === 'certain' || r.tier === 'likely') && (r.status === 'open' || r.status === 'in-progress') },
            { header: t.sav.csv.status, value: (r) => (r.findingId ? t.sav.status[r.status] : '') },
            { header: t.sav.csv.reason, value: (r) => r.statusReason ?? '' },
            { header: t.sav.csv.source, value: (r) => t.sav.source[r.source] },
            { header: t.sav.csv.resource, value: (r) => rowName(r) },
            { header: t.sav.csv.resourceId, value: (r) => r.resourceId },
            { header: t.sav.csv.resourceGroup, value: (r) => r.rgLabel },
            { header: t.sav.csv.subscription, value: (r) => subLabel(r.subKey) },
            { header: t.sav.csv.type, value: (r) => r.typeLabel },
            ...tagKeys.map((k) => ({ header: tagLabel(k), value: (r: Row) => r.allocation?.[k] ?? '' })),
            { header: t.sav.csv.confidence, value: (r) => (r.tag ? levelLabel(r.tag) : '') },
            { header: t.sav.csv.saving(code), value: (r) => (r.converted ? convert(r.est) : null) },
            { header: t.sav.csv.upper(code), value: (r) => (r.estHigh != null ? convert(r.estHigh) : null) },
            { header: t.sav.csv.advisorAmount, value: (r) => (r.source === 'Advisor' ? r.nativeAmount : null) },
            { header: t.sav.csv.advisorCurrency, value: (r) => (r.source === 'Advisor' ? r.nativeCurrency : '') },
          ]}
        />
        {dismissedCount > 0 && (
          <Button
            appearance={showDismissed ? 'outline' : 'subtle'}
            shape="circular"
            onClick={() => { setLoading(true); setShowDismissed((v) => !v) }}
          >
            {showDismissed ? t.sav.hideDismissed : t.sav.showDismissed(dismissedCount)}
          </Button>
        )}
        {filtersActive && (
          <Button appearance="subtle" shape="circular" icon={<DismissCircle16Regular />} onClick={clearFilters}>
            {t.sav.clear}
          </Button>
        )}
      </div>

      {statusMsg && <Text size={200} className={styles.muted}>{statusMsg}</Text>}

      <div className={styles.tablePanel}>
        {filtered.length === 0 ? (
          <Text className={styles.empty}>{t.sav.noMatch}</Text>
        ) : (
          <Table aria-label={t.sav.table} style={{ minWidth: '1340px' }}>
            <TableHeader>
              <TableRow>
                <TableHeaderCell style={{ minWidth: '340px' }}>{t.sav.recommendation}</TableHeaderCell>
                <TableHeaderCell style={{ width: '230px' }}>{t.sav.resource}</TableHeaderCell>
                <TableHeaderCell style={{ width: '170px' }}>{t.sav.subscription}</TableHeaderCell>
                <TableHeaderCell style={{ width: '100px' }}>{t.sav.sourceLabel}</TableHeaderCell>
                <TableHeaderCell style={{ width: '120px' }}>{t.sav.confidence}</TableHeaderCell>
                <NumHeaderCell style={{ width: '120px' }}>{t.sav.estSaving}</NumHeaderCell>
                <TableHeaderCell style={{ width: '150px' }}>{t.sav.statusCol}</TableHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((r) => (
                <TableRow key={r.key}>
                  <TableCell>
                    <div className={styles.titleRow}>
                      <div className={styles.titleCell}>
                        <div className={styles.titleLine}>
                          <Text size={300} weight="semibold">{r.title}</Text>
                          <Badge appearance="tint" color={tierColor(r.tier)} title={t.sav.tierHelp[r.tier]}>{t.sav.tier[r.tier] ?? r.tier}</Badge>
                          {r.reopened && (
                            <Badge appearance="tint" color="warning" title={t.sav.reopenedTip}>
                              {t.sav.reopened}
                            </Badge>
                          )}
                        </div>
                        {r.body && <Text size={200} className={styles.bodyText} title={r.body}>{r.body}</Text>}
                        {r.statusReason && <Text size={200} className={styles.muted}>{t.sav.dismissed(r.statusReason)}</Text>}
                      </div>
                      <AskAboutButton
                        compact
                        question={t.sav.askWorth(rowName(r) || t.sav.thisResource)}
                        context={{
                          kind: 'saving',
                          title: `${r.title}${rowName(r) ? ` — ${rowName(r)}` : ''}`,
                          subscriptionId: r.subKey !== 'none' ? r.subKey : null,
                          subscriptionName: subLabelByKey.get(r.subKey)?.known ? subLabel(r.subKey) : null,
                          resourceId: r.resourceId.includes('/providers/') ? r.resourceId : null,
                          resourceName: rowName(r) || null,
                          summary: `${r.title}. ${r.body ?? ''} Estimated saving about ${Math.round(r.est)} USD per month (source: ${r.source}).`,
                        }}
                      />
                    </div>
                  </TableCell>
                  <TableCell style={{ width: '230px' }}>
                    <ResourceRef
                      resourceId={r.resourceId}
                      displayName={r.resourceName}
                      fallbackName={guidFallbackLabel(r)}
                    />
                  </TableCell>
                  <TableCell style={{ width: '170px' }}>
                    <div className={styles.badgeStack}>
                      <Text size={200} className={styles.muted}>{subLabel(r.subKey)}</Text>
                      {r.allocation && (
                        <Text size={200} title={allocationSummary(r.allocation) || t.sav.noAllocation}>
                          {ownerLabel()}: {ownerOf(r.allocation) || t.sav.untagged}
                        </Text>
                      )}
                    </div>
                  </TableCell>
                  <TableCell>
                    <div className={styles.badgeStack}>
                      <Badge appearance="tint" color={r.source === 'Analysis' ? 'brand' : 'informative'}>{t.sav.source[r.source]}</Badge>
                      {r.estHigh != null && <Badge appearance="tint" color="informative">Advisor</Badge>}
                    </div>
                  </TableCell>
                  <TableCell>
                    <div className={styles.badgeStack}>
                      {r.tag && <Badge appearance="tint" color={r.tagColor}>{levelLabel(r.tag)}</Badge>}
                      {r.advisorTag && <Badge appearance="tint" color={impactColor(r.advisorTag)}>{levelLabel(r.advisorTag)}</Badge>}
                    </div>
                  </TableCell>
                  <TableCell className={styles.numCol}>
                    {!r.converted ? (
                      // Advisor reported this in a currency we have no rate for. Show its
                      // own figure, unconverted, and say it is out of the total.
                      <Text
                        weight="semibold"
                        className={styles.muted}
                        title={t.sav.unconvertedTip(r.nativeCurrency, code)}
                      >
                        {t.sav.perMonth(formatNative(r.nativeAmount, r.nativeCurrency))} *
                      </Text>
                    ) : r.est > 0 ? (
                      <Text
                        weight="semibold"
                        className={styles.savings}
                        title={
                          r.estHigh != null && r.estHigh > r.est
                            ? t.sav.rangeTip
                            : undefined
                        }
                      >
                        {r.estHigh != null && r.estHigh > r.est
                          ? t.sav.perMonth(`${usd(r.est)}–${usd(r.estHigh)}`)
                          : t.sav.perMonth(usd(r.est))}
                      </Text>
                    ) : null}
                  </TableCell>
                  <TableCell style={{ width: '150px' }}>
                    {r.findingId ? (
                      <Menu>
                        <MenuTrigger disableButtonEnhancement>
                          <MenuButton
                            size="small"
                            appearance={r.status === 'open' ? 'subtle' : 'outline'}
                            disabled={!canSetStatus || busyId === r.key}
                            title={canSetStatus ? t.sav.recordTip : t.sav.adminsOnly}
                          >
                            {t.sav.status[r.status]}
                          </MenuButton>
                        </MenuTrigger>
                        <MenuPopover>
                          <MenuList>
                            {(['open', 'in-progress', 'done', 'dismissed'] as SavingsStatus[])
                              .filter((s) => s !== r.status)
                              .map((s) => (
                                <MenuItem key={s} onClick={() => void setStatus(r, s)}>{t.sav.statusAction[s]}</MenuItem>
                              ))}
                          </MenuList>
                        </MenuPopover>
                      </Menu>
                    ) : (
                      <Text size={200} className={styles.muted} title={t.sav.advisorDecides}>—</Text>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </div>
    </div>
  )
}
