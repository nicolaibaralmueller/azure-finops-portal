import {
  Badge,
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  makeStyles,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import { History16Regular, Person16Regular, Warning16Regular } from '@fluentui/react-icons'
import type { CostChangeEvidence, EvidenceFact, PeriodType } from '../api/client'
import { useCurrency } from '../lib/currency'
import { parseResourceId } from '../lib/resource'
import { ResourceRef } from './ResourceRef'
import { NumHeaderCell } from './NumHeaderCell'
import { t, locale } from '../i18n'

const useStyles = makeStyles({
  root: { display: 'flex', flexDirection: 'column', rowGap: tokens.spacingVerticalS, minWidth: 0 },
  muted: { color: tokens.colorNeutralForeground3 },
  warn: { display: 'flex', alignItems: 'flex-start', columnGap: '6px', color: tokens.colorPaletteDarkOrangeForeground1 },
  tableWrap: { overflowX: 'auto', maxWidth: '100%' },
  numCol: { textAlign: 'right', whiteSpace: 'nowrap' },
  up: { color: tokens.colorPaletteRedForeground1 },
  down: { color: tokens.colorPaletteGreenForeground1 },
  chips: { display: 'flex', flexWrap: 'wrap', columnGap: '4px', rowGap: '2px' },
  sectionHead: { display: 'flex', alignItems: 'center', columnGap: '6px', marginTop: tokens.spacingVerticalXS },
  list: { display: 'flex', flexDirection: 'column', rowGap: '4px', margin: 0, ...shorthands.padding(0) },
  item: { display: 'flex', alignItems: 'baseline', columnGap: tokens.spacingHorizontalS, flexWrap: 'wrap', listStyleType: 'none' },
  when: { color: tokens.colorNeutralForeground3, whiteSpace: 'nowrap', minWidth: '84px' },
  code: { fontFamily: tokens.fontFamilyMonospace, fontSize: tokens.fontSizeBase200 },
  factId: { minWidth: '28px', justifyContent: 'center' },
})

const pct = (n: number) => {
  const d = Math.abs(n) < 10 ? 1 : 0
  return `${n > 0 ? '+' : ''}${n.toLocaleString(locale(), { minimumFractionDigits: d, maximumFractionDigits: d })}%`
}

function whenLabel(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime()) ? iso : new Intl.DateTimeFormat(locale(), { day: 'numeric', month: 'short' }).format(d)
}

function resourceLabel(f: { resourceId?: string | null; resourceName?: string | null; name?: string }): string {
  if (f.resourceName) return f.resourceName
  if (f.resourceId) return parseResourceId(f.resourceId).name
  return f.name ?? ''
}

/** A short one-line summary of the evidence, for a collapsed card. */
export function evidenceSummary(e: CostChangeEvidence | null | undefined): string | null {
  if (!e) return null
  const parts: string[] = []
  const top = e.facts.find((f) => f.kind === 'driver' && f.direction === 'increase') as Extract<EvidenceFact, { kind: 'driver' }> | undefined
  if (top) {
    const name = top.driverKind === 'resource' ? resourceLabel(top) : top.name
    const why = top.isNew ? t.evidence.isNew : top.unitPriceChangePct != null && Math.abs(top.unitPriceChangePct) >= 5 && Math.abs(top.unitPriceChangePct) > Math.abs(top.quantityChangePct ?? 0)
      ? t.evidence.unitPrice(pct(top.unitPriceChangePct))
      : top.quantityChangePct != null && Math.abs(top.quantityChangePct) >= 1 ? t.evidence.usage(pct(top.quantityChangePct)) : null
    parts.push(t.evidence.largestDriver(name, top.sharePct != null ? String(Math.round(top.sharePct)) : null, why))
  }
  const changes = e.facts.filter((f) => f.kind === 'change' || f.kind === 'property-change').length
  parts.push(t.evidence.recordedChanges(changes))
  const fresh = e.facts.filter((f) => f.kind === 'new-resource').length
  if (fresh) parts.push(t.evidence.newResources(fresh))
  return parts.join(' · ')
}

function FactId({ id, cited }: { id: string; cited: boolean }) {
  const styles = useStyles()
  return (
    <Badge
      className={styles.factId}
      size="small"
      appearance={cited ? 'filled' : 'outline'}
      color={cited ? 'brand' : 'informative'}
      title={cited ? t.evidence.cited : undefined}
    >
      {id}
    </Badge>
  )
}

type Props = {
  evidence: CostChangeEvidence
  periodType: PeriodType
  citedFacts?: string[]
}

// Renders the deterministic evidence for one cost change: what moved (drivers), whether it was
// usage or price, what was changed in Azure, new resources and owners. Works with or without an
// AI explanation; cited facts are highlighted when there is one.
export function EvidencePanel({ evidence, periodType, citedFacts = [] }: Props) {
  const styles = useStyles()
  const { money } = useCurrency()
  const cited = new Set(citedFacts.map((c) => c.toUpperCase()))
  const typical = periodType === 'week' ? t.evidence.typicalWeek : t.evidence.typicalMonth
  const current = periodType === 'week' ? t.evidence.thisWindow : t.evidence.thisMonth
  const signed = (n: number) => `${n >= 0 ? '+' : '−'}${money(Math.abs(n))}`

  const drivers = evidence.facts.filter((f): f is Extract<EvidenceFact, { kind: 'driver' }> => f.kind === 'driver')
  const split = evidence.facts.find((f): f is Extract<EvidenceFact, { kind: 'volume-rate' }> => f.kind === 'volume-rate')
  const fresh = evidence.facts.filter((f): f is Extract<EvidenceFact, { kind: 'new-resource' }> => f.kind === 'new-resource')
  const changes = evidence.facts
    .filter((f): f is Extract<EvidenceFact, { kind: 'change' | 'property-change' }> => f.kind === 'change' || f.kind === 'property-change')
    .sort((a, b) => a.time.localeCompare(b.time))
  const owner = evidence.facts.find((f): f is Extract<EvidenceFact, { kind: 'owner' }> => f.kind === 'owner')
  const shape = evidence.facts.find((f): f is Extract<EvidenceFact, { kind: 'daily-shape' }> => f.kind === 'daily-shape')
  const driverHeader = drivers[0]?.driverKind === 'resource' ? t.evidence.resource : drivers[0]?.driverKind === 'service' ? t.evidence.service : t.evidence.meter

  return (
    <div className={styles.root}>
      <Text size={200} className={styles.muted}>{evidence.basis}</Text>
      {!evidence.complete && (
        <Text size={200} className={styles.warn}>
          <Warning16Regular />
          <span>{t.evidence.incomplete(evidence.notes.join(' '))}</span>
        </Text>
      )}
      {evidence.complete && evidence.notes.length > 0 && (
        <Text size={200} className={styles.muted}>{evidence.notes.join(' ')}</Text>
      )}
      {shape && (
        <Text size={200}>
          <FactId id={shape.id} cited={cited.has(shape.id)} />{' '}
          {shape.steppedDownOn && shape.dailyBeforeUsd != null && shape.dailyAfterUsd != null
            ? t.evidence.shapeStep(shape.steppedDownOn, money(shape.dailyBeforeUsd), money(shape.dailyAfterUsd), money(shape.exitRunRateUsd))
            : t.evidence.shapeEnd(money(shape.exitRunRateUsd))}
          {shape.resolved ? ` ${t.evidence.shapeResolved}` : ''}
        </Text>
      )}

      {drivers.length > 0 && (
        <div className={styles.tableWrap}>
          <Table size="small" aria-label={t.evidence.drove} style={{ minWidth: '760px' }}>
            <TableHeader>
              <TableRow>
                <TableHeaderCell style={{ width: '48px' }} />
                <TableHeaderCell style={{ minWidth: '160px' }}>{driverHeader}</TableHeaderCell>
                <NumHeaderCell style={{ width: '104px' }}>{typical}</NumHeaderCell>
                <NumHeaderCell style={{ width: '96px' }}>{current}</NumHeaderCell>
                <NumHeaderCell style={{ width: '104px' }}>{t.evidence.change}</NumHeaderCell>
                <TableHeaderCell style={{ width: '150px' }}>{t.evidence.why}</TableHeaderCell>
              </TableRow>
            </TableHeader>
            <TableBody>
              {drivers.map((d) => (
                <TableRow key={d.id}>
                  <TableCell><FactId id={d.id} cited={cited.has(d.id)} /></TableCell>
                  <TableCell>
                    {d.driverKind === 'resource' && d.resourceId
                      ? <ResourceRef resourceId={d.resourceId} displayName={d.resourceName} />
                      : <Text size={200} weight="semibold">{d.name}</Text>}
                  </TableCell>
                  <TableCell className={styles.numCol}><Text size={200}>{d.baselineUsd > 0 ? money(d.baselineUsd) : '—'}</Text></TableCell>
                  <TableCell className={styles.numCol}><Text size={200}>{d.currentUsd > 0 ? money(d.currentUsd) : '—'}</Text></TableCell>
                  <TableCell className={styles.numCol}>
                    <Text size={200} weight="semibold" className={d.deltaUsd >= 0 ? styles.up : styles.down}>{signed(d.deltaUsd)}</Text>
                    {d.sharePct != null && <Text size={100} className={styles.muted} block>{t.evidence.ofRise(Math.round(d.sharePct))}</Text>}
                  </TableCell>
                  <TableCell>
                    <div className={styles.chips}>
                      {d.isNew && <Badge size="small" appearance="tint" color="brand">{t.evidence.isNew}</Badge>}
                      {d.stopped && <Badge size="small" appearance="tint" color="success">{t.evidence.stopped}</Badge>}
                      {d.quantityChangePct != null && Math.abs(d.quantityChangePct) >= 1 && (
                        <Badge size="small" appearance="tint" color="informative">{t.evidence.usage(pct(d.quantityChangePct))}</Badge>
                      )}
                      {d.unitPriceChangePct != null && Math.abs(d.unitPriceChangePct) >= 1 && (
                        <Badge size="small" appearance="tint" color="warning">{t.evidence.unitPrice(pct(d.unitPriceChangePct))}</Badge>
                      )}
                      {d.quantityChangePct != null && Math.abs(d.quantityChangePct) < 1 &&
                        d.unitPriceChangePct != null && Math.abs(d.unitPriceChangePct) < 1 && (
                          <Text size={100} className={styles.muted}>{t.evidence.steady}</Text>
                        )}
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {split && (() => {
        // Only name the parts that matter: rounding noise of a few units is not a finding.
        const floor = Math.max(1, Math.abs(split.netDeltaUsd) * 0.02)
        const parts = [
          Math.abs(split.volumeUsd) >= floor ? <><b>{signed(split.volumeUsd)}</b> {t.evidence.fromUsage}</> : null,
          Math.abs(split.rateUsd) >= floor ? <><b>{signed(split.rateUsd)}</b> {t.evidence.fromPrice}</> : null,
          Math.abs(split.newOrStoppedUsd) >= floor ? <><b>{signed(split.newOrStoppedUsd)}</b> {t.evidence.fromStartStop}</> : null,
        ].filter(Boolean)
        return (
          <Text size={200}>
            <FactId id={split.id} cited={cited.has(split.id)} />{' '}
            {parts.length === 0 ? (
              <>{t.evidence.tooThin(signed(split.netDeltaUsd))}</>
            ) : parts.length === 1 && Math.abs(split.volumeUsd) < floor && Math.abs(split.rateUsd) < floor ? (
              <>{t.evidence.allStartStop(signed(split.netDeltaUsd))}</>
            ) : (
              <>{t.evidence.ofChange(signed(split.netDeltaUsd))}{parts.map((p, i) => <span key={i}>{i > 0 && (i === parts.length - 1 ? t.evidence.and : ', ')}{p}</span>)}.</>
            )}
          </Text>
        )
      })()}

      {fresh.length > 0 && (
        <>
          <Text size={200} weight="semibold" className={styles.sectionHead}>{t.evidence.newHead}</Text>
          <ul className={styles.list}>
            {fresh.map((f) => (
              <li key={f.id} className={styles.item}>
                <FactId id={f.id} cited={cited.has(f.id)} />
                <ResourceRef resourceId={f.resourceId} displayName={f.resourceName ?? f.name} />
                <Text size={200} className={styles.up}>{money(f.currentUsd)}</Text>
              </li>
            ))}
          </ul>
        </>
      )}

      <Text size={200} weight="semibold" className={styles.sectionHead}><History16Regular /> {t.evidence.changesHead}</Text>
      {changes.length === 0 ? (
        <Text size={200} className={styles.muted}>
          {t.evidence.noChanges(drivers[0]?.driverKind === 'meter')}
        </Text>
      ) : (
        <ul className={styles.list}>
          {changes.map((c) => (
            <li key={c.id} className={styles.item}>
              <FactId id={c.id} cited={cited.has(c.id)} />
              <Text size={200} className={styles.when}>{whenLabel(c.time)}</Text>
              <Text size={200} weight="semibold">{resourceLabel(c)}</Text>
              {c.kind === 'property-change' ? (
                c.changeType === 'update' ? (
                  <Text size={200}>
                    <span className={styles.code}>{c.path}</span>: {c.from || t.evidence.empty} → <b>{c.to || t.evidence.empty}</b>
                  </Text>
                ) : (
                  <Text size={200}>{c.changeType === 'create' ? t.evidence.created : t.evidence.deleted}</Text>
                )
              ) : (
                <Text size={200}>
                  {c.action}{c.count > 1 ? ` ×${c.count}` : ''}{' '}
                  <span className={styles.muted}>{t.evidence.by(c.operation.split('/').slice(-2).join('/'), c.actor)}</span>
                </Text>
              )}
            </li>
          ))}
        </ul>
      )}

      {owner && Object.keys(owner.tags).length > 0 && (
        <Text size={200} className={styles.sectionHead}>
          <FactId id={owner.id} cited={cited.has(owner.id)} />
          <Person16Regular />
          {Object.entries(owner.tags).map(([k, v]) => `${k}: ${v}`).join(' · ')}
        </Text>
      )}
    </div>
  )
}
