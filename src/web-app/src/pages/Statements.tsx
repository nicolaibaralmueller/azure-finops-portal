import { useEffect, useState } from 'react'
import {
  Button,
  Link,
  Spinner,
  Tab,
  TabList,
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
import { ArrowLeft16Regular, Print16Regular } from '@fluentui/react-icons'
import { FinOpsApi, type StatementBudget, type StatementIndexRow, type StatementResponse } from '../api/client'
import { useCurrency } from '../lib/currency'
import { useHashParam } from '../lib/route'
import { setAllocationTags, tagLabel } from '../lib/allocation'
import { parseResourceId } from '../lib/resource'
import { NumHeaderCell } from '../components/NumHeaderCell'
import { ExportButton } from '../components/ExportButton'
import { ErrorNote } from '../components/ErrorNote'
import { ResourceRef } from '../components/ResourceRef'
import { t, locale } from '../i18n'

// MONTHLY STATEMENTS — one page per owner / cost centre for the last complete month, against the
// month before: what they spent, on what, their biggest resources and what they could save.
// The overview lists every value, and then — apart, never spread across owners — spend with no
// owner tag and spend tied to no resource at all, so the page adds up to the bill.

const useStyles = makeStyles({
  panel: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
    minWidth: 0,
    marginBottom: tokens.spacingVerticalL,
  },
  controls: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalM, rowGap: tokens.spacingVerticalS, flexWrap: 'wrap', marginBottom: tokens.spacingVerticalL },
  head: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalM, flexWrap: 'wrap' },
  spacer: { flexGrow: 1 },
  hint: { color: tokens.colorNeutralForeground3 },
  warn: { color: tokens.colorPaletteDarkOrangeForeground1 },
  numCol: { textAlign: 'right', whiteSpace: 'nowrap' },
  nameCol: { overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', maxWidth: '320px', display: 'block' },
  separate: { color: tokens.colorPaletteDarkOrangeForeground1, fontWeight: tokens.fontWeightSemibold },
  up: { color: tokens.colorPaletteRedForeground1, whiteSpace: 'nowrap' },
  down: { color: tokens.colorPaletteGreenForeground1, whiteSpace: 'nowrap' },
  saving: { color: tokens.colorPaletteGreenForeground1, whiteSpace: 'nowrap', fontWeight: tokens.fontWeightSemibold },
  totalRow: { fontWeight: tokens.fontWeightSemibold, ...shorthands.borderTop('2px', 'solid', tokens.colorNeutralStroke1) },
  figures: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))', columnGap: tokens.spacingHorizontalXL, rowGap: tokens.spacingVerticalM },
  figure: { display: 'flex', flexDirection: 'column', rowGap: '2px', minWidth: 0 },
  figLabel: { color: tokens.colorNeutralForeground3, fontSize: tokens.fontSizeBase200 },
  columns: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(360px, 1fr))', gap: tokens.spacingHorizontalM },
  spark: { display: 'block', color: tokens.colorBrandForeground1 },
  // Drawn at its own size (a few months must not stretch into giant bars), shrinking on a phone.
  bars: { display: 'block', maxWidth: '100%', height: 'auto', color: tokens.colorBrandBackground },
  legend: { display: 'flex', flexWrap: 'wrap', columnGap: tokens.spacingHorizontalL, rowGap: '2px', marginTop: tokens.spacingVerticalXS, color: tokens.colorNeutralForeground3, fontSize: tokens.fontSizeBase200 },
  swatch: { display: 'inline-block', width: '10px', height: '10px', marginRight: '6px', verticalAlign: 'middle', ...shorthands.borderRadius('2px'), backgroundColor: tokens.colorBrandBackground },
  swatchRest: { opacity: 0.3 },
  swatchWhole: { backgroundColor: 'transparent', ...shorthands.border('1px', 'dashed', tokens.colorBrandBackground) },
  barLabel: { fill: tokens.colorNeutralForeground3, fontSize: '10px' },
  chip: { display: 'inline-block', marginLeft: tokens.spacingHorizontalS, ...shorthands.padding('0', '6px'), ...shorthands.borderRadius(tokens.borderRadiusMedium), fontSize: tokens.fontSizeBase100, backgroundColor: tokens.colorNeutralBackground3, color: tokens.colorNeutralForeground2, whiteSpace: 'nowrap' },
  chipOver: { backgroundColor: tokens.colorPaletteRedBackground1, color: tokens.colorPaletteRedForeground1 },
  coverage: { color: tokens.colorNeutralForeground2 },
})

// A 12-month line without axes: the shape is the point, the figures are in the table.
function Sparkline({ values, className }: { values: (number | null)[]; className?: string }) {
  const pts = values.map((v, i) => ({ v, i })).filter((p): p is { v: number; i: number } => p.v != null)
  if (pts.length < 2) return null
  const w = 80, h = 20, max = Math.max(...pts.map((p) => p.v), 1)
  const x = (i: number) => (values.length > 1 ? (i / (values.length - 1)) * (w - 2) + 1 : w / 2)
  const y = (v: number) => h - 2 - (v / max) * (h - 4)
  return (
    <svg width={w} height={h} className={className} aria-hidden="true">
      <polyline fill="none" stroke="currentColor" strokeWidth="1.5" points={pts.map((p) => `${x(p.i)},${y(p.v)}`).join(' ')} />
    </svg>
  )
}

// Monthly bars for one value, oldest on the left, ending with the current month so far. Where a
// month has a daily series, the solid part is its 1st to `throughDay` and the faint part the rest
// of the month — so this month so far compares like for like with the same days before it.
function TrendBars({ months, totals, sameDays, throughDay, partialMonth, format, className, labelClass }: {
  months: string[]; totals: (number | null)[]; sameDays: (number | null)[]; throughDay: number | null; partialMonth: string | null
  format: (n: number) => string; className?: string; labelClass?: string
}) {
  const full = months.map((m, i) => (m === partialMonth ? sameDays[i] : totals[i]) ?? sameDays[i] ?? 0)
  const max = Math.max(...full, 1)
  const bw = 40, gap = 12, h = 110, w = months.length * (bw + gap) - gap
  const short = (ym: string) => new Intl.DateTimeFormat(locale(), { month: 'short', timeZone: 'UTC' }).format(new Date(`${ym}-01T00:00:00Z`))
  const px = (v: number) => (v > 0 ? Math.max(2, (v / max) * h) : 0)
  return (
    <svg width={w} height={h + 16} viewBox={`0 0 ${w} ${h + 16}`} className={className} role="img" aria-label={t.stmt.spendPerMonth}>
      {months.map((m, i) => {
        const x = i * (bw + gap)
        const same = sameDays[i]
        const isPartial = m === partialMonth
        const tip = [
          `${short(m)}${isPartial ? t.stmt.soFar : ''}`,
          same != null && throughDay ? t.stmt.daysTip(throughDay, format(same)) : null,
          !isPartial && totals[i] != null ? t.stmt.wholeMonthTip(format(totals[i] as number)) : null,
          same == null && throughDay ? t.stmt.noDailyTip : null,
        ].filter(Boolean).join(' · ')
        return (
          <g key={m}>
            <title>{tip}</title>
            {/* Faint: the rest of the month. A month with no daily series (stored before them) is a
                dashed outline — its whole-month total, with no split to show. */}
            {!isPartial && same != null && <rect x={x} y={h - px(full[i])} width={bw} height={px(full[i])} rx="3" fill="currentColor" opacity={0.3} />}
            {!isPartial && same == null && throughDay != null && (
              <rect x={x + 0.5} y={h - px(full[i]) + 0.5} width={bw - 1} height={Math.max(0, px(full[i]) - 1)} rx="3" fill="currentColor" fillOpacity={0.08} stroke="currentColor" strokeDasharray="3 2" />
            )}
            {!isPartial && same == null && throughDay == null && <rect x={x} y={h - px(full[i])} width={bw} height={px(full[i])} rx="3" fill="currentColor" />}
            {same != null && <rect x={x} y={h - px(same)} width={bw} height={px(same)} rx="3" fill="currentColor" />}
            <text x={x + bw / 2} y={h + 12} textAnchor="middle" className={labelClass}>{short(m)}</text>
          </g>
        )
      })}
    </svg>
  )
}

const monthName = (ym?: string | null) => {
  if (!ym) return ''
  const d = new Date(`${ym}-01T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? ym : new Intl.DateTimeFormat(locale(), { month: 'long', year: 'numeric', timeZone: 'UTC' }).format(d)
}
const dimLabel = (d?: string) => (d ? tagLabel(d.replace(/^tag:/, '')) : '')
const labelOf = (r: { key: string; label: string }) => t.stmt.separate[r.key] ?? r.label
const shortDate = (iso?: string | null) =>
  iso ? new Intl.DateTimeFormat(locale(), { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(new Date(`${iso}T00:00:00Z`)) : ''

export function Statements() {
  const styles = useStyles()
  const { money, code, convert } = useCurrency()
  const [dimParam, setDimParam] = useHashParam('dim', '')
  const [value, setValue] = useHashParam('value', '')
  const [data, setData] = useState<StatementResponse | null>(null)
  const [error, setError] = useState<unknown>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    setLoading(true)
    setError(null)
    // Always the current month so far (the server's default); earlier months are in the trend.
    FinOpsApi.getStatement({ dimension: dimParam || undefined, value: value || undefined })
      .then((d) => { setAllocationTags(null, d.tagLabels); setData(d) })
      .catch(setError)
      .finally(() => setLoading(false))
  }, [dimParam, value])

  const pct = (n: number | null | undefined) => (n == null ? '—' : `${n > 0 ? '+' : ''}${n.toFixed(0)}%`)
  const change = (delta: number, deltaPct: number | null, previous: number) =>
    previous > 0 ? (
      <span className={delta > 0 ? styles.up : styles.down}>{delta >= 0 ? '+' : '−'}{money(Math.abs(delta))} ({pct(deltaPct)})</span>
    ) : (
      <span className={styles.hint}>{t.stmt.isNew}</span>
    )

  const budgetMoney = (amount: number, currency: string) => {
    try { return new Intl.NumberFormat(locale(), { style: 'currency', currency: currency || 'USD', maximumFractionDigits: 0 }).format(amount) }
    catch { return `${Math.round(amount).toLocaleString(locale())} ${currency}` }
  }
  const budgetTitle = (b: StatementBudget) =>
    t.stmt.budgetTitle(b.name, b.scopeName, budgetMoney(b.spent, b.currency), budgetMoney(b.amount, b.currency),
      b.timeGrain?.toLowerCase() === 'monthly', !!b.projectedToExceed, !!b.extraFilters)
  // One chip per value: several budgets (e.g. a project on three resource groups) are added up
  // when they share a currency and period; otherwise the chip just counts them. The tooltip lists each.
  const budgetChip = (list?: StatementBudget[]) => {
    if (!list?.length) return null
    const same = list.every((b) => b.currency === list[0].currency && b.timeGrain === list[0].timeGrain)
    const amount = list.reduce((sum, b) => sum + b.amount, 0)
    const spent = list.reduce((sum, b) => sum + b.spent, 0)
    const over = list.some((b) => b.projectedToExceed)
    const text = list.length === 1
      ? (list[0].usedPct != null ? t.stmt.ofBudget(list[0].usedPct.toFixed(0)) : t.stmt.budget)
      : same && amount > 0 ? t.stmt.ofBudgets(((spent / amount) * 100).toFixed(0), list.length) : t.stmt.budgets(list.length)
    return (
      <span className={`${styles.chip} ${over ? styles.chipOver : ''}`} title={list.map(budgetTitle).join('\n')}>{text}</span>
    )
  }

  if (loading && !data) return <Spinner label={t.stmt.loading} />
  if (error && !data) return <ErrorNote error={error} what={t.errors.what.statements} />
  if (!data?.ready) {
    return (
      <Text className={styles.hint}>{t.stmt.notReady}</Text>
    )
  }

  const dim = data.dimension ?? ''
  const rows = data.rows ?? []
  const owners = rows.filter((r) => !r.separate)
  const apart = rows.filter((r) => r.separate)
  const rec = data.reconciliation
  const st = data.statement
  const partial = !!data.partial
  // A part-month is compared with the same days of the month before, and says so everywhere.
  const curLabel = partial ? t.stmt.curLabelPartial(monthName(data.month), shortDate(data.throughDate)) : monthName(data.month)
  const prevLabel = partial ? t.stmt.prevLabelPartial(monthName(data.previousMonth)) : monthName(data.previousMonth)
  const trendMonths = data.trend?.months ?? []
  // Column headings, short enough for a narrow column: "1–26 Oct" / "1–26 Sep", or "Sep 2026".
  const monthShort = (ym?: string | null, year = false) =>
    ym ? new Intl.DateTimeFormat(locale(), { month: 'short', ...(year ? { year: 'numeric' } : {}), timeZone: 'UTC' }).format(new Date(`${ym}-01T00:00:00Z`)) : ''
  const throughDay = data.throughDate ? Number(data.throughDate.slice(8, 10)) : null
  const curCol = partial && throughDay ? `1–${throughDay} ${monthShort(data.month)}` : monthShort(data.month, true)
  const prevCol = partial && throughDay ? `1–${throughDay} ${monthShort(data.previousMonth)}` : monthShort(data.previousMonth, true)
  const coverageLine = data.coveragePct != null && (
    <Text size={200} className={styles.coverage}>
      {t.stmt.coverage(data.coveragePct.toFixed(0), dimLabel(dim).toLowerCase())}
    </Text>
  )

  const controls = (
    <div className={styles.controls} data-print-hide>
      {value ? (
        <Button size="small" appearance="subtle" icon={<ArrowLeft16Regular />} onClick={() => setValue('')}>
          {t.stmt.allStatements(dimLabel(dim).toLowerCase())}
        </Button>
      ) : (
        data.dimensions.length > 1 && (
          <TabList size="small" selectedValue={dim} onTabSelect={(_e, d) => setDimParam(String(d.value))} aria-label={t.stmt.statementBy}>
            {data.dimensions.map((d) => <Tab key={d} value={d}>{dimLabel(d)}</Tab>)}
          </TabList>
        )
      )}
      <div className={styles.spacer} />
      <Button size="small" appearance="subtle" icon={<Print16Regular />} onClick={() => window.print()}>{t.stmt.print}</Button>
    </div>
  )

  const notes = (
    <>
      {data.complete === false && (
        <Text size={200} className={styles.warn}>
          {t.stmt.missingDays(monthName(data.month))}
        </Text>
      )}
      {data.scopePending && (
        <Text size={200} className={styles.warn}>{t.stmt.scopePending}</Text>
      )}
    </>
  )

  // ---- one owner's statement ----
  if (value) {
    if (error) return <>{controls}<ErrorNote error={error} what={t.stmt.statementFor(value)} /></>
    if (loading && !st) return <>{controls}<Spinner size="tiny" label={t.stmt.loadingOne} /></>
    if (!st) return <>{controls}<Text className={styles.hint}>{t.stmt.noStatement(value, monthName(data.month))}</Text></>
    return (
      <>
        {controls}
        <section className={styles.panel} aria-label={t.stmt.ariaStatement(labelOf(st))}>
          <Text size={500} weight="semibold">{dimLabel(dim)}: {labelOf(st)}</Text>
          <Text size={200} className={styles.hint}>
            {partial
              ? t.stmt.soFarIntro(monthName(data.month), shortDate(data.throughDate), monthName(data.previousMonth))
              : t.stmt.monthIntro(monthName(data.month), monthName(data.previousMonth))}
            {t.stmt.tagsToday}
          </Text>
          {notes}
          <div className={styles.figures}>
            <div className={styles.figure}>
              <Text className={styles.figLabel}>{partial ? t.stmt.spentSoFar(monthName(data.month)) : t.stmt.spentIn(monthName(data.month))}</Text>
              <Text size={500} weight="semibold">{money(st.totalUsd)}</Text>
              <Text size={200}>{change(st.deltaUsd, st.deltaPct, st.previousUsd)}</Text>
            </div>
            <div className={styles.figure}>
              <Text className={styles.figLabel}>{t.stmt.shareOfBill}</Text>
              <Text size={500} weight="semibold">{st.sharePct.toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%</Text>
              <Text size={200} className={styles.hint}>{t.stmt.withCost(st.resources)}</Text>
            </div>
            <div className={styles.figure}>
              <Text className={styles.figLabel}>{t.stmt.couldSave}</Text>
              <Text size={500} weight="semibold" className={styles.saving}>{t.stmt.perMonth(money(st.openSavingsUsd))}</Text>
              <Text size={200} className={styles.hint}>{t.stmt.openOpportunities(st.savingsCount)}</Text>
            </div>
          </div>
          {!!st.budgets?.length && (
            <div>
              {st.budgets.map((b) => (
                <Text size={200} block key={b.name} className={b.projectedToExceed ? styles.warn : undefined}>
                  {budgetTitle(b)}{b.usedPct != null ? ` (${b.usedPct.toFixed(0)}%)` : ''}.
                </Text>
              ))}
            </div>
          )}
          {(st.trend?.some((v) => v != null) || st.trendSameDays?.some((v) => v != null)) && trendMonths.length > 1 && (
            <div>
              <Text size={200} className={styles.hint} block>{t.stmt.lastMonths(trendMonths.length)}</Text>
              <TrendBars
                months={trendMonths} totals={st.trend ?? []} sameDays={st.trendSameDays ?? []}
                throughDay={data.trend?.throughDay ?? null} partialMonth={data.trend?.partialMonth ?? null}
                format={(n) => money(n)} className={styles.bars} labelClass={styles.barLabel}
              />
              {!!data.trend?.throughDay && st.trendSameDays?.some((v) => v != null) && (
                <div className={styles.legend}>
                  <span><span className={styles.swatch} />{t.stmt.daysOfEach(data.trend.throughDay)}</span>
                  <span><span className={mergeClasses(styles.swatch, styles.swatchRest)} />{t.stmt.restOfMonth}</span>
                  {st.trendSameDays?.some((v, i) => v == null && trendMonths[i] !== data.trend?.partialMonth && st.trend?.[i] != null) && (
                    <span><span className={mergeClasses(styles.swatch, styles.swatchWhole)} />{t.stmt.wholeOnly}</span>
                  )}
                </div>
              )}
            </div>
          )}
        </section>

        {!!st.untaggedGroups?.length && (
          <section className={styles.panel}>
            <Text size={400} weight="semibold">{t.stmt.tagFirst}</Text>
            <Text size={200} className={styles.hint}>{t.stmt.tagFirstHint}</Text>
            <Table size="small" aria-label={t.stmt.groupsToTag}>
              <TableHeader>
                <TableRow>
                  <TableHeaderCell>{t.stmt.resourceGroup}</TableHeaderCell>
                  <NumHeaderCell style={{ width: '120px' }}>{t.stmt.untaggedSpend}</NumHeaderCell>
                  <NumHeaderCell style={{ width: '100px' }}>{t.stmt.resources}</NumHeaderCell>
                </TableRow>
              </TableHeader>
              <TableBody>
                {st.untaggedGroups.map((g) => (
                  <TableRow key={g.resourceGroupId}>
                    <TableCell><ResourceRef resourceId={g.resourceGroupId} displayName={g.name} /></TableCell>
                    <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(g.usd)}</Text></TableCell>
                    <TableCell className={styles.numCol}><Text size={200}>{g.resources}</Text></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </section>
        )}

        <div className={styles.columns}>
          <section className={styles.panel}>
            <div className={styles.head}>
              <Text size={400} weight="semibold">{t.stmt.byService}</Text>
              <div className={styles.spacer} />
              <ExportButton
                fileBase={`statement-${labelOf(st)}-${data.month}-services`.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}
                rows={st.byService}
                columns={[
                  { header: t.stmt.service, value: (r) => r.name },
                  { header: partial ? t.stmt.soFarCol(data.month ?? '', code) : t.stmt.monthCol(data.month ?? '', code), value: (r) => convert(r.usd) },
                  { header: partial ? t.stmt.sameDaysCol(data.previousMonth ?? '', code) : t.stmt.monthCol(data.previousMonth ?? '', code), value: (r) => convert(r.previousUsd) },
                ]}
              />
            </div>
            <Table size="small" aria-label={t.stmt.spendByService}>
              <TableHeader>
                <TableRow>
                  <TableHeaderCell>{t.stmt.service}</TableHeaderCell>
                  <NumHeaderCell style={{ width: '110px' }}><span title={curLabel}>{curCol}</span></NumHeaderCell>
                  <NumHeaderCell style={{ width: '110px' }}><span title={prevLabel}>{prevCol}</span></NumHeaderCell>
                </TableRow>
              </TableHeader>
              <TableBody>
                {st.byService.map((s) => (
                  <TableRow key={s.name}>
                    <TableCell><Text size={200} className={styles.nameCol} title={s.name}>{s.name}</Text></TableCell>
                    <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(s.usd)}</Text></TableCell>
                    <TableCell className={styles.numCol}><Text size={200} className={styles.hint}>{s.previousUsd > 0 ? money(s.previousUsd) : '—'}</Text></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </section>

          <section className={styles.panel}>
            <div className={styles.head}>
              <Text size={400} weight="semibold">{t.stmt.couldBeSaved}</Text>
              <div className={styles.spacer} />
              <Link href={`#/savings?q=${encodeURIComponent(value)}`} data-print-hide>{t.stmt.allSavings}</Link>
            </div>
            {!st.savings.length ? (
              <Text size={200} className={styles.hint}>{t.stmt.noSavings}</Text>
            ) : (
              <Table size="small" aria-label={t.stmt.openSavings}>
                <TableBody>
                  {st.savings.map((s) => (
                    <TableRow key={s.id}>
                      <TableCell>
                        <Link href={`#/savings?q=${encodeURIComponent(s.resourceName || s.title)}`}>{s.title}</Link>
                        <Text size={200} className={styles.hint} block>
                          {s.resourceName || (s.resourceId.includes('/providers/') ? parseResourceId(s.resourceId).name : '')}
                          {s.source === 'advisor' ? t.stmt.advisor : ''}
                        </Text>
                      </TableCell>
                      <TableCell className={styles.numCol}><Text size={200} className={styles.saving}>{t.stmt.perMonth(money(s.monthlyUsd))}</Text></TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </section>
        </div>

        <section className={styles.panel}>
          <div className={styles.head}>
            <Text size={400} weight="semibold">{t.stmt.largest}</Text>
            <div className={styles.spacer} />
            <ExportButton
              fileBase={`statement-${labelOf(st)}-${data.month}-resources`.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}
              rows={st.topResources}
              columns={[
                { header: t.stmt.resource, value: (r) => r.resourceId },
                { header: partial ? t.stmt.soFarCol(data.month ?? '', code) : t.stmt.monthCol(data.month ?? '', code), value: (r) => convert(r.usd) },
                { header: partial ? t.stmt.sameDaysCol(data.previousMonth ?? '', code) : t.stmt.monthCol(data.previousMonth ?? '', code), value: (r) => convert(r.previousUsd) },
              ]}
            />
          </div>
          <Table size="small" aria-label={t.stmt.largest}>
            <TableHeader>
              <TableRow>
                <TableHeaderCell>{t.stmt.resource}</TableHeaderCell>
                <NumHeaderCell style={{ width: '110px' }}><span title={curLabel}>{curCol}</span></NumHeaderCell>
                <NumHeaderCell style={{ width: '140px' }}>{t.stmt.change}</NumHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {st.topResources.map((r) => (
                <TableRow key={r.resourceId}>
                  <TableCell><ResourceRef resourceId={r.resourceId} /></TableCell>
                  <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(r.usd)}</Text></TableCell>
                  <TableCell className={styles.numCol}>
                    <Text size={200}>
                      {r.previousUsd > 0
                        ? <span className={r.deltaUsd > 0 ? styles.up : styles.down}>{r.deltaUsd >= 0 ? '+' : '−'}{money(Math.abs(r.deltaUsd))}</span>
                        : <span className={styles.hint}>{t.stmt.isNew}</span>}
                    </Text>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </section>
      </>
    )
  }

  // ---- every value, then what belongs to nobody, adding up to the bill ----
  const hasTrend = trendMonths.length > 1
  const indexRow = (r: StatementIndexRow) => (
    <TableRow key={r.key}>
      <TableCell>
        <Link onClick={() => setValue(r.key)} className={r.separate ? styles.separate : undefined} title={t.stmt.openFor(labelOf(r))}>
          {labelOf(r)}
        </Link>
        {budgetChip(r.budgets)}
      </TableCell>
      {hasTrend && (
        <TableCell>
          <Sparkline values={data.trend?.series[r.key] ?? []} className={styles.spark} />
        </TableCell>
      )}
      <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(r.totalUsd)}</Text></TableCell>
      <TableCell className={styles.numCol}><Text size={200}>{change(r.deltaUsd, r.deltaPct, r.previousUsd)}</Text></TableCell>
      <TableCell className={styles.numCol}><Text size={200}>{r.sharePct.toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%</Text></TableCell>
      <TableCell className={styles.numCol}>
        <Text size={200} className={r.openSavingsUsd > 0 ? styles.saving : styles.hint}>{r.openSavingsUsd > 0 ? t.stmt.perMonth(money(r.openSavingsUsd)) : '—'}</Text>
      </TableCell>
    </TableRow>
  )

  return (
    <>
      {controls}
      <section className={styles.panel}>
        <div className={styles.head}>
          <Text size={400} weight="semibold">{partial ? t.stmt.soFarBy(monthName(data.month), dimLabel(dim).toLowerCase()) : t.stmt.monthBy(monthName(data.month), dimLabel(dim).toLowerCase())}</Text>
          <div className={styles.spacer} />
          <ExportButton
            fileBase={`statements-${data.month}-${dim.replace(/[^a-z0-9]+/gi, '-')}`.toLowerCase()}
            rows={rows}
            columns={[
              { header: dimLabel(dim), value: (r) => labelOf(r) },
              { header: partial ? t.stmt.soFarCol(data.month ?? '', code) : t.stmt.monthCol(data.month ?? '', code), value: (r) => convert(r.totalUsd) },
              { header: partial ? t.stmt.sameDaysCol(data.previousMonth ?? '', code) : t.stmt.monthCol(data.previousMonth ?? '', code), value: (r) => convert(r.previousUsd) },
              { header: t.stmt.changePct, value: (r) => r.deltaPct },
              { header: t.stmt.shareOfBillPct, value: (r) => r.sharePct },
              { header: t.stmt.openSavingsCol(code), value: (r) => convert(r.openSavingsUsd) },
            ]}
          />
        </div>
        <Text size={200} className={styles.hint}>
          {partial ? t.stmt.comparedSameDays(monthName(data.previousMonth), dimLabel(dim).toLowerCase()) : t.stmt.comparedMonth(monthName(data.previousMonth), dimLabel(dim).toLowerCase())}
        </Text>
        {coverageLine}
        {notes}
        {loading ? <Spinner size="tiny" /> : (
          <Table size="small" aria-label={t.stmt.statementsBy(dimLabel(dim))}>
            <TableHeader>
              <TableRow>
                <TableHeaderCell>{dimLabel(dim)}</TableHeaderCell>
                {hasTrend && <TableHeaderCell style={{ width: '96px' }}>{t.stmt.months(trendMonths.length)}</TableHeaderCell>}
                <NumHeaderCell style={{ width: '120px' }}>{t.stmt.spent}</NumHeaderCell>
                <NumHeaderCell style={{ width: '170px' }}>{t.stmt.change}</NumHeaderCell>
                <NumHeaderCell style={{ width: '90px' }}>{t.stmt.ofBill}</NumHeaderCell>
                <NumHeaderCell style={{ width: '120px' }}>{t.stmt.couldSave}</NumHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {owners.map(indexRow)}
              {apart.map(indexRow)}
              {rec?.sharedUsd != null && (
                <TableRow>
                  <TableCell>
                    <Text size={200} className={styles.separate} title={t.stmt.sharedTip}>
                      {t.stmt.notTied}
                    </Text>
                  </TableCell>
                  {hasTrend && <TableCell />}
                  <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(rec.sharedUsd)}</Text></TableCell>
                  <TableCell />
                  <TableCell className={styles.numCol}><Text size={200}>{rec.sharedPct != null ? `${rec.sharedPct.toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%` : '—'}</Text></TableCell>
                  <TableCell />
                </TableRow>
              )}
              {rec?.billedUsd != null && (
                <TableRow className={styles.totalRow}>
                  <TableCell><Text size={200} weight="semibold">{partial ? t.stmt.totalSoFar : t.stmt.total}</Text></TableCell>
                  {hasTrend && <TableCell />}
                  <TableCell className={styles.numCol}><Text size={200} weight="semibold">{money(rec.billedUsd)}</Text></TableCell>
                  <TableCell /><TableCell className={styles.numCol}><Text size={200}>100%</Text></TableCell><TableCell />
                </TableRow>
              )}
            </TableBody>
          </Table>
        )}
        {rec?.billedUsd == null && (
          <Text size={200} className={styles.hint}>{t.stmt.billIncomplete}</Text>
        )}
      </section>
    </>
  )
}
