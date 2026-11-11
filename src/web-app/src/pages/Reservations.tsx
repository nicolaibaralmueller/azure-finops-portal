import { Fragment, useEffect, useMemo, useState } from 'react'
import {
  Badge,
  Dropdown,
  Option,
  SearchBox,
  Spinner,
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  makeStyles,
  mergeClasses,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import { ChevronDown16Regular, ChevronRight16Regular, Warning16Regular } from '@fluentui/react-icons'
import { FinOpsApi, type ReservationItem, type ReservationsResponse } from '../api/client'
import { useCurrency } from '../lib/currency'
import { useHashParam } from '../lib/route'
import { AskAboutButton } from '../components/AskAboutButton'
import { ErrorNote } from '../components/ErrorNote'
import { ExportButton } from '../components/ExportButton'
import { NumHeaderCell } from '../components/NumHeaderCell'
import { ResourceRef } from '../components/ResourceRef'
import type { CsvColumn } from '../lib/csv'
import { t, locale } from '../i18n'

// Every reservation and savings plan (GetReservations): Azure's utilisation and expiry, as on the
// Azure Reservations blade, plus what the blade doesn't show — which resources used each one over
// the last 30 days (amortized cost) and what went unused. Select a row to see its resources.

const useStyles = makeStyles({
  root: { display: 'flex', flexDirection: 'column', rowGap: tokens.spacingVerticalM, minWidth: 0 },
  tiles: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: tokens.spacingHorizontalM },
  tile: {
    display: 'flex', flexDirection: 'column', rowGap: '2px',
    ...shorthands.padding(tokens.spacingVerticalM, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1, ...shorthands.borderRadius(tokens.borderRadiusLarge), boxShadow: tokens.shadow2,
  },
  toolbar: {
    display: 'flex', flexWrap: 'wrap', alignItems: 'center', columnGap: tokens.spacingHorizontalS, rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorNeutralBackground2, ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke2),
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
  },
  search: { minWidth: '200px', maxWidth: '320px', flexGrow: 1, backgroundColor: tokens.colorNeutralBackground1, ...shorthands.borderRadius('16px') },
  pill: {
    minWidth: 'unset', maxWidth: '260px', backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.border('1px', 'solid', tokens.colorNeutralStroke1), ...shorthands.borderRadius('16px'),
  },
  spacer: { flexGrow: 1 },
  panel: { backgroundColor: tokens.colorNeutralBackground1, ...shorthands.borderRadius(tokens.borderRadiusLarge), boxShadow: tokens.shadow2, overflowX: 'auto' },
  row: { cursor: 'pointer' },
  // Cancelled / expired: still listed (their last days of use and unused cost are real), dimmed.
  ended: { '& td': { color: tokens.colorNeutralForeground3 } },
  muted: { color: tokens.colorNeutralForeground3 },
  numCol: { textAlign: 'right', whiteSpace: 'nowrap' },
  warn: { color: tokens.colorPaletteDarkOrangeForeground1, fontWeight: tokens.fontWeightSemibold },
  good: { color: tokens.colorPaletteGreenForeground1 },
  nameCell: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalXS, minWidth: 0 },
  detail: {
    display: 'flex', flexDirection: 'column', rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalM, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground2,
  },
  detailHead: { display: 'flex', alignItems: 'center', flexWrap: 'wrap', columnGap: tokens.spacingHorizontalM },
  alert: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalXS, color: tokens.colorPaletteDarkOrangeForeground1 },
})

const termLabel = (code: string) => t.commit.term(code)
const pct = (v: number | null | undefined) => (v == null ? '—' : `${v.toFixed(0)}%`)
const UNDER = 90

type Show = 'all' | 'under' | 'expiring' | 'idle'
type SortKey = 'unused' | 'util' | 'expiry' | 'name' | 'resources'
const SHOW_KEYS: Show[] = ['all', 'under', 'expiring', 'idle']
const showLabel = (k: Show) => (k === 'under' ? t.res.show.under(UNDER) : t.res.show[k])

// Cancelled or expired. One seen only in cost data counts as ended when the inventory can be read
// (it would be listed otherwise); without the Reservations Reader role nothing is listed, so it
// can't be told apart and stays.
const isEnded = (i: ReservationItem, inventoryRead: boolean) =>
  i.status === 'cancelled' || i.status === 'expired' || (i.status === 'unknown' && inventoryRead)
const endedLabel = (i: ReservationItem) => (i.status === 'cancelled' ? t.res.cancelled : i.status === 'expired' ? t.res.expired : t.res.notListed)
// Nothing used it in the last 7 days. Judged on usage (hours / units), not on the covered cost:
// some tenants get 0 for that cost while the usage is real, which made every reservation "idle".
// Data synced before the quantities were stored falls back to the last day it was used.
const usedRecently = (i: ReservationItem, lastSynced: string | null | undefined) => {
  if (i.quantity7d != null) return i.quantity7d > 0 || (i.used7dUsd ?? 0) > 0
  if ((i.used7dUsd ?? 0) > 0) return true
  if (!i.lastUsed) return false
  const synced = lastSynced ? new Date(lastSynced) : new Date()
  // The window ends the day before the sync and spans 7 days.
  const from = new Date(Date.UTC(synced.getUTCFullYear(), synced.getUTCMonth(), synced.getUTCDate() - 7))
  return i.lastUsed >= from.toISOString().slice(0, 10)
}
const isIdle = (i: ReservationItem, lastSynced?: string | null) =>
  i.hasUsageData && !usedRecently(i, lastSynced) && (i.status === 'active' || i.status === 'unknown')
const what = (i: ReservationItem) =>
  i.commitment?.amount != null
    ? `${i.commitment.amount} ${i.commitment.currency}/${i.commitment.grain === 'Hourly' ? t.commit.perHour : i.commitment.grain}`
    : i.sku ? `${i.quantity ?? ''} × ${i.sku}` : '—'

export function Reservations() {
  const styles = useStyles()
  const { money, code, convert } = useCurrency()
  const [data, setData] = useState<ReservationsResponse | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [search, setSearch] = useHashParam('q', '')
  const [kind, setKind] = useHashParam('kind', 'all')
  const [show, setShow] = useHashParam('show', 'all')
  const [status, setStatus] = useHashParam('status', 'all')
  const [sort, setSort] = useHashParam('sort', 'unused')
  const [selected, setSelected] = useHashParam('sel', '')

  useEffect(() => { FinOpsApi.getReservations().then(setData).catch(setError) }, [])

  const items = data?.items ?? []
  const inventoryRead = items.some((i) => i.inInventory)
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    const out = items.filter((i) => {
      if (kind !== 'all' && i.kind !== kind) return false
      if (status === 'active' && isEnded(i, inventoryRead)) return false
      if (status === 'ended' && !isEnded(i, inventoryRead)) return false
      if (show === 'under' && !(i.utilisation30d != null && i.utilisation30d < UNDER)) return false
      if (show === 'expiring' && !i.expiringSoon) return false
      if (show === 'idle' && !isIdle(i, data?.lastSynced)) return false
      if (q && ![i.name, i.sku, i.location, i.id, ...i.resources.map((r) => r.name)].some((s) => (s ?? '').toLowerCase().includes(q))) return false
      return true
    })
    const by: Record<SortKey, (a: ReservationItem, b: ReservationItem) => number> = {
      unused: (a, b) => (b.unused30dUsd ?? -1) - (a.unused30dUsd ?? -1) || (a.utilisation30d ?? 101) - (b.utilisation30d ?? 101),
      util: (a, b) => (a.utilisation30d ?? 101) - (b.utilisation30d ?? 101),
      expiry: (a, b) => (a.daysToExpiry ?? 1e9) - (b.daysToExpiry ?? 1e9),
      name: (a, b) => a.name.localeCompare(b.name, locale()),
      resources: (a, b) => b.resourceCount - a.resourceCount,
    }
    return [...out].sort(by[(sort as SortKey) in by ? (sort as SortKey) : 'unused'])
  }, [items, inventoryRead, search, kind, status, show, sort])

  if (error) return <ErrorNote error={error} what={t.errors.what.reservations} />
  if (!data) return <Spinner label={t.res.loading} />
  if (!data.ready)
    return <Text className={styles.muted}>{t.res.notReady}</Text>

  const live = items.filter((i) => !isEnded(i, inventoryRead))
  const withUtil = live.filter((i) => i.utilisation30d != null)
  const avgUtil = withUtil.length ? withUtil.reduce((s, i) => s + (i.utilisation30d ?? 0), 0) / withUtil.length : null
  const unusedKnown = items.some((i) => i.unused30dUsd != null)
  const unusedTotal = items.reduce((s, i) => s + (i.unused30dUsd ?? 0), 0)
  const expiring = items.filter((i) => i.expiringSoon).length
  const idle = items.filter((i) => isIdle(i, data?.lastSynced)).length

  const csv: CsvColumn<ReservationItem>[] = [
    { header: t.res.csv.name, value: (i) => i.name },
    { header: t.res.csv.kind, value: (i) => t.commit.kind(i.kind) },
    { header: t.res.csv.status, value: (i) => (isEnded(i, inventoryRead) ? endedLabel(i) : t.res.active) },
    { header: t.res.csv.product, value: (i) => what(i) },
    { header: t.res.csv.region, value: (i) => i.location },
    { header: t.res.csv.scope, value: (i) => i.appliedScope },
    { header: t.res.csv.util7, value: (i) => i.utilisation7d },
    { header: t.res.csv.util30, value: (i) => i.utilisation30d },
    { header: t.res.csv.resources, value: (i) => i.resourceCount },
    { header: t.res.csv.used30(code), value: (i) => (i.used30dUsd == null ? null : convert(i.used30dUsd)) },
    { header: t.res.csv.unused30(code), value: (i) => (i.unused30dUsd == null ? null : convert(i.unused30dUsd)) },
    { header: t.res.csv.expires, value: (i) => i.expiryDate },
    { header: t.res.csv.renew, value: (i) => i.renew },
    { header: t.res.csv.id, value: (i) => i.id },
  ]
  const sortHeader = (key: SortKey, label: string, num = false, width?: string) => {
    const props = {
      sortable: true,
      sortDirection: sort === key ? (key === 'name' || key === 'util' || key === 'expiry' ? 'ascending' : 'descending') : undefined,
      onClick: () => setSort(key),
      style: { width, textAlign: num ? 'right' : undefined },
    } as const
    return <TableHeaderCell {...props}>{label}</TableHeaderCell>
  }

  return (
    <div className={styles.root}>
      <div className={styles.tiles}>
        <div className={styles.tile}><Text size={200} className={styles.muted}>{t.res.active}</Text><Text size={600} weight="semibold">{live.length}</Text></div>
        <div className={styles.tile}><Text size={200} className={styles.muted}>{t.res.avgUtil}</Text><Text size={600} weight="semibold" className={avgUtil != null && avgUtil < UNDER ? styles.warn : undefined}>{pct(avgUtil)}</Text></div>
        <div className={styles.tile}>
          <Text size={200} className={styles.muted}>{t.res.unusedLast(data.days)}</Text>
          <Text size={600} weight="semibold" className={unusedTotal > 0 ? styles.warn : undefined}>{unusedKnown ? money(unusedTotal) : '—'}</Text>
        </div>
        <div className={styles.tile}><Text size={200} className={styles.muted}>{t.res.ending60}</Text><Text size={600} weight="semibold" className={expiring ? styles.warn : undefined}>{expiring}</Text></div>
        <div className={styles.tile}><Text size={200} className={styles.muted}>{t.res.idle7}</Text><Text size={600} weight="semibold" className={idle ? styles.warn : undefined}>{idle}</Text></div>
      </div>

      <div className={styles.toolbar}>
        <SearchBox className={styles.search} placeholder={t.res.search} value={search} onChange={(_e, d) => setSearch(d.value)} />
        <Dropdown className={styles.pill} aria-label={t.res.filterKind} value={t.res.typePill(t.res.kinds[kind] ?? t.res.kinds.all)} selectedOptions={[kind]} onOptionSelect={(_e, d) => setKind(d.optionValue ?? 'all')}>
          {Object.entries(t.res.kinds).map(([k, l]) => <Option key={k} value={k}>{l}</Option>)}
        </Dropdown>
        <Dropdown className={styles.pill} aria-label={t.res.filterStatus} value={t.res.statusPill(t.res.statuses[status] ?? t.res.statuses.all)} selectedOptions={[status]} onOptionSelect={(_e, d) => setStatus(d.optionValue ?? 'all')}>
          {Object.entries(t.res.statuses).map(([k, l]) => <Option key={k} value={k}>{l}</Option>)}
        </Dropdown>
        <Dropdown className={styles.pill} aria-label={t.res.showLabel} value={t.res.showPill(SHOW_KEYS.includes(show as Show) ? showLabel(show as Show) : t.res.show.all)} selectedOptions={[show]} onOptionSelect={(_e, d) => setShow(d.optionValue ?? 'all')}>
          {SHOW_KEYS.map((k) => <Option key={k} value={k}>{showLabel(k)}</Option>)}
        </Dropdown>
        <div className={styles.spacer} />
        <Text size={200} className={styles.muted}>{t.res.countOf(filtered.length, items.length)}</Text>
        <ExportButton fileBase="reservations" rows={filtered} columns={csv} />
      </div>

      <div className={styles.panel}>
        <Table size="small" aria-label={t.res.table} style={{ minWidth: '1320px' }}>
          <TableHeader>
            <TableRow>
              {sortHeader('name', t.res.name, false, '320px')}
              <TableHeaderCell style={{ width: '110px' }}>{t.res.type}</TableHeaderCell>
              <TableHeaderCell style={{ width: '190px' }}>{t.res.product}</TableHeaderCell>
              <TableHeaderCell style={{ width: '110px' }}>{t.res.region}</TableHeaderCell>
              <TableHeaderCell style={{ width: '80px' }}>{t.res.scope}</TableHeaderCell>
              <NumHeaderCell style={{ width: '70px' }}>{t.res.day7}</NumHeaderCell>
              {sortHeader('util', t.res.day30, true, '80px')}
              {sortHeader('resources', t.res.usedBy, true, '90px')}
              {sortHeader('unused', t.res.unused30, true, '120px')}
              {sortHeader('expiry', t.res.expires, false, '150px')}
            </TableRow>
          </TableHeader>
          <TableBody>
            {filtered.map((i) => {
              const open = selected === i.id
              const ended = isEnded(i, inventoryRead)
              return (
                <Fragment key={i.id}>
                  <TableRow className={mergeClasses(styles.row, ended && styles.ended)} aria-expanded={open} onClick={() => setSelected(open ? '' : i.id)}>
                    <TableCell>
                      <span className={styles.nameCell}>
                        {open ? <ChevronDown16Regular /> : <ChevronRight16Regular />}
                        <Text size={200} weight="semibold" truncate wrap={false} title={i.name}>{i.name}</Text>
                        {ended && <Badge size="small" appearance="outline" color="subtle">{endedLabel(i)}</Badge>}
                      </span>
                    </TableCell>
                    <TableCell><Badge appearance="tint" color={i.kind === 'savings plan' ? 'brand' : 'informative'}>{t.commit.kind(i.kind)}</Badge></TableCell>
                    <TableCell><Text size={200} className={styles.muted}>{what(i)}{i.term ? ` · ${termLabel(i.term)}` : ''}</Text></TableCell>
                    <TableCell><Text size={200}>{i.location || '—'}</Text></TableCell>
                    <TableCell><Text size={200}>{i.appliedScope || '—'}</Text></TableCell>
                    <TableCell className={styles.numCol}><Text size={200}>{pct(i.utilisation7d)}</Text></TableCell>
                    <TableCell className={styles.numCol}>
                      <Text size={200} className={i.utilisation30d == null ? styles.muted : i.utilisation30d < UNDER ? styles.warn : styles.good}>{pct(i.utilisation30d)}</Text>
                    </TableCell>
                    <TableCell className={styles.numCol}>
                      <Text size={200} className={isIdle(i, data.lastSynced) ? styles.warn : undefined}>{i.hasUsageData ? i.resourceCount : '—'}</Text>
                    </TableCell>
                    <TableCell className={styles.numCol}>
                      <Text size={200} className={(i.unused30dUsd ?? 0) > 0 ? styles.warn : styles.muted}>{i.unused30dUsd == null ? '—' : money(i.unused30dUsd)}</Text>
                    </TableCell>
                    <TableCell>
                      <Text size={200} className={i.expiringSoon ? styles.warn : styles.muted}>
                        {i.expiryDate ?? '—'}{i.expiringSoon && (i.renew ? t.res.renews : t.res.noRenew)}
                      </Text>
                    </TableCell>
                  </TableRow>
                  {open && (
                    <TableRow>
                      <TableCell colSpan={10} style={{ padding: 0 }}>
                        <Detail item={i} days={data.days} lastSynced={data.lastSynced} />
                      </TableCell>
                    </TableRow>
                  )}
                </Fragment>
              )
            })}
            {filtered.length === 0 && (
              <TableRow><TableCell colSpan={10}><Text size={200} className={styles.muted}>{t.res.noMatch}</Text></TableCell></TableRow>
            )}
          </TableBody>
        </Table>
      </div>

      <Text size={200} className={styles.muted}>
        {t.res.footnote(data.days)}
        {data.perSubscription && t.res.perSubscription}
        {data.lastSynced && t.res.lastSynced(new Date(data.lastSynced).toLocaleString(locale()))}
      </Text>
      {data.notes.map((n, k) => <Text key={k} size={200} className={styles.muted}>{n}</Text>)}
    </div>
  )
}

function Detail({ item: i, days, lastSynced }: { item: ReservationItem; days: number; lastSynced?: string | null }) {
  const styles = useStyles()
  const { money } = useCurrency()
  const summary =
    `${i.kind} ${i.name}: ${what(i)}, utilisation ${pct(i.utilisation30d)} over 30 days, used by ${i.resourceCount} resource(s)` +
    (i.unused30dUsd != null ? `, unused cost USD ${i.unused30dUsd.toFixed(2)} over ${days} days` : '') +
    (i.expiryDate ? `, expires ${i.expiryDate}` : '')
  return (
    <div className={styles.detail}>
      <div className={styles.detailHead}>
        <Text size={300} weight="semibold">{t.res.usedLast(days)}</Text>
        <div className={styles.spacer} />
        <AskAboutButton
          question={t.res.askWhich(i.name)}
          context={{ kind: 'commitment', title: i.name, summary }}
        />
      </div>
      {!i.hasUsageData && <Text size={200} className={styles.muted}>{t.res.noUsage}</Text>}
      {i.costHidden && <Text size={200} className={styles.muted}>{t.res.costHidden}</Text>}
      {isIdle(i, lastSynced) && (
        <span className={styles.alert}><Warning16Regular /><Text size={200}>{t.res.idleWarn(i.lastUsed)}</Text></span>
      )}
      {i.hasUsageData && (
        <Table size="small" aria-label={t.res.resourcesUsing(i.name)}>
          <TableHeader>
            <TableRow>
              <TableHeaderCell>{t.res.resource}</TableHeaderCell>
              <TableHeaderCell style={{ width: '200px' }}>{t.res.subscription}</TableHeaderCell>
              <NumHeaderCell style={{ width: '90px' }}>{t.res.daysUsed}</NumHeaderCell>
              <NumHeaderCell style={{ width: '100px' }}>{t.res.quantity}</NumHeaderCell>
              <NumHeaderCell style={{ width: '120px' }}>{t.res.costCovered}</NumHeaderCell>
              <NumHeaderCell style={{ width: '80px' }}>{t.res.share}</NumHeaderCell>
              <TableHeaderCell style={{ width: '100px' }}>{t.res.lastUsedCol}</TableHeaderCell>
            </TableRow>
          </TableHeader>
          <TableBody>
            {i.resources.map((r) => (
              <TableRow key={r.resourceId}>
                <TableCell><ResourceRef resourceId={r.resourceId} /></TableCell>
                <TableCell><Text size={200}>{r.subscriptionName || r.subscriptionId}</Text></TableCell>
                <TableCell className={styles.numCol}><Text size={200}>{r.days}</Text></TableCell>
                <TableCell className={styles.numCol}><Text size={200}>{r.quantity30d.toLocaleString(locale())}</Text></TableCell>
                <TableCell className={styles.numCol}><Text size={200} className={i.costHidden ? styles.muted : undefined}>{i.costHidden ? '—' : money(r.cost30dUsd)}</Text></TableCell>
                <TableCell className={styles.numCol}><Text size={200}>{r.sharePct.toFixed(0)}%</Text></TableCell>
                <TableCell><Text size={200} className={styles.muted}>{r.lastUsed ?? '—'}</Text></TableCell>
              </TableRow>
            ))}
            {i.otherSubscriptions && (
              <TableRow>
                <TableCell><Text size={200} className={styles.muted}>{t.res.outsideScope(i.otherSubscriptions.count)}</Text></TableCell>
                <TableCell /><TableCell /><TableCell />
                <TableCell className={styles.numCol}><Text size={200}>{i.costHidden ? '—' : money(i.otherSubscriptions.cost30dUsd)}</Text></TableCell>
                <TableCell className={styles.numCol}><Text size={200}>{i.otherSubscriptions.sharePct.toFixed(0)}%</Text></TableCell>
                <TableCell />
              </TableRow>
            )}
            {i.unused30dUsd != null && i.unused30dUsd > 0 && (
              <TableRow>
                <TableCell><Text size={200} className={styles.warn}>{t.res.unusedRow}</Text></TableCell>
                <TableCell /><TableCell /><TableCell />
                <TableCell className={styles.numCol}><Text size={200} className={styles.warn}>{money(i.unused30dUsd)}</Text></TableCell>
                <TableCell /><TableCell />
              </TableRow>
            )}
            {i.resources.length === 0 && !i.otherSubscriptions && (
              <TableRow><TableCell colSpan={7}><Text size={200} className={styles.muted}>{t.res.noneUsed(days)}</Text></TableCell></TableRow>
            )}
          </TableBody>
        </Table>
      )}
    </div>
  )
}
