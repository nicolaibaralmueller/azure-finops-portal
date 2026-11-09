import { useEffect, useState } from 'react'
import {
  Badge,
  Button,
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
import { ChevronDown16Regular, ChevronUp16Regular } from '@fluentui/react-icons'
import { FinOpsApi, type CommitmentsResponse } from '../api/client'
import { useCurrency } from '../lib/currency'
import { NumHeaderCell } from './NumHeaderCell'
import { useAsk } from '../lib/ask'
import { t } from '../i18n'

// Reservations and savings plans: how well each is used, when each ends, and what Azure
// recommends buying (GetCommitments). The money unused commitments waste is a finding in the
// table below, counted in the total; this panel is the context around it.

const useStyles = makeStyles({
  panel: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalM, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
    minWidth: 0,
  },
  head: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalM, flexWrap: 'wrap' },
  spacer: { flexGrow: 1 },
  muted: { color: tokens.colorNeutralForeground3 },
  numCol: { textAlign: 'right', whiteSpace: 'nowrap' },
  warn: { color: tokens.colorPaletteDarkOrangeForeground1, fontWeight: tokens.fontWeightSemibold },
  good: { color: tokens.colorPaletteGreenForeground1 },
  scroll: { overflowX: 'auto' },
})

const termLabel = (code: string) => t.commit.term(code)

export function CommitmentsPanel() {
  const styles = useStyles()
  const { money } = useCurrency()
  const [data, setData] = useState<CommitmentsResponse | null>(null)
  const [open, setOpen] = useState(false)
  const { goTo } = useAsk()

  useEffect(() => { FinOpsApi.getCommitments().then(setData).catch(() => setData(null)) }, [])

  if (!data?.ready) return null
  const inv = data.inventory
  const recs = data.recommendations
  const underused = inv.filter((i) => i.utilisation30d != null && i.utilisation30d < 80).length
  const expiring = inv.filter((i) => i.expiringSoon).length
  const recTotal = recs.reduce((s, r) => s + r.monthlySavingsUsd, 0)
  if (!inv.length && !recs.length && !data.notes.length) return null

  return (
    <div className={styles.panel}>
      <div className={styles.head}>
        <Text size={400} weight="semibold">{t.commit.panelTitle}</Text>
        <Text size={200} className={styles.muted}>
          {inv.length ? t.commit.active(inv.length) : t.commit.noneVisible}
          {underused > 0 && t.commit.underUsed(underused)}
          {expiring > 0 && t.commit.ending(expiring)}
          {recs.length > 0 && t.commit.recommends(recs.length, money(recTotal))}
        </Text>
        <div className={styles.spacer} />
        <Button size="small" appearance="subtle" onClick={() => goTo('reservations')}>{t.commit.whichResources}</Button>
        <Button size="small" appearance="subtle" icon={open ? <ChevronUp16Regular /> : <ChevronDown16Regular />} iconPosition="after" onClick={() => setOpen((v) => !v)}>
          {open ? t.commit.hide : t.commit.details}
        </Button>
      </div>
      {open && (
        <>
          {inv.length > 0 && (
            <div className={styles.scroll}>
              <Table size="small" aria-label={t.commit.tableLabel} style={{ minWidth: '640px' }}>
                <TableHeader>
                  <TableRow>
                    <TableHeaderCell>{t.commit.name}</TableHeaderCell>
                    <TableHeaderCell style={{ width: '110px' }}>{t.commit.kindCol}</TableHeaderCell>
                    <TableHeaderCell style={{ width: '180px' }}>{t.commit.what}</TableHeaderCell>
                    <NumHeaderCell style={{ width: '120px' }}>{t.commit.used30}</NumHeaderCell>
                    <TableHeaderCell style={{ width: '170px' }}>{t.commit.ends}</TableHeaderCell>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {inv.map((i) => (
                    <TableRow key={i.id}>
                      <TableCell><Text size={200}>{i.name}</Text></TableCell>
                      <TableCell><Badge appearance="tint" color={i.kind === 'savings plan' ? 'brand' : 'informative'}>{t.commit.kind(i.kind)}</Badge></TableCell>
                      <TableCell>
                        <Text size={200} className={styles.muted}>
                          {i.commitment?.amount != null
                            ? `${i.commitment.amount} ${i.commitment.currency}/${i.commitment.grain === 'Hourly' ? t.commit.perHour : i.commitment.grain}`
                            : `${i.quantity ?? ''} × ${i.sku}`}
                          {' · '}{termLabel(i.term)}{i.appliedScope ? ` · ${i.appliedScope}` : ''}
                        </Text>
                      </TableCell>
                      <TableCell className={styles.numCol}>
                        {i.utilisation30d == null ? <Text size={200} className={styles.muted}>—</Text> : (
                          <Text size={200} className={i.utilisation30d < 80 ? styles.warn : styles.good} title={i.utilisation7d != null ? t.commit.last7(`${i.utilisation7d.toFixed(0)}%`) : undefined}>
                            {i.utilisation30d.toFixed(0)}%
                          </Text>
                        )}
                      </TableCell>
                      <TableCell>
                        <Text size={200} className={i.expiringSoon ? styles.warn : styles.muted}>
                          {i.expiryDate ?? '—'}{i.daysToExpiry != null && i.daysToExpiry >= 0 ? t.commit.days(i.daysToExpiry) : ''}
                          {i.expiringSoon && (i.renew ? t.commit.renews : t.commit.noRenew)}
                        </Text>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
          {recs.length > 0 && (
            <>
              <Text size={300} weight="semibold">{t.commit.recTitle}</Text>
              <Text size={200} className={styles.muted}>{t.commit.recHint}</Text>
              <div className={styles.scroll}>
                <Table size="small" aria-label={t.commit.recTable} style={{ minWidth: '640px' }}>
                  <TableHeader>
                    <TableRow>
                      <TableHeaderCell style={{ width: '170px' }}>{t.commit.subscription}</TableHeaderCell>
                      <TableHeaderCell>{t.commit.recommendation}</TableHeaderCell>
                      <TableHeaderCell style={{ width: '80px' }}>{t.commit.termCol}</TableHeaderCell>
                      <NumHeaderCell style={{ width: '90px' }}>{t.commit.costs}</NumHeaderCell>
                      <NumHeaderCell style={{ width: '120px' }}>{t.commit.saves}</NumHeaderCell>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {recs.map((r, k) => (
                      <TableRow key={`${r.subscriptionId}-${r.kind}-${r.term}-${k}`}>
                        <TableCell><Text size={200}>{r.subscriptionName}</Text></TableCell>
                        <TableCell>
                          <Text size={200}>
                            {r.kind === 'savings plan'
                              ? `${r.description}${r.hourlyCommitment != null ? t.commit.commit(String(r.hourlyCommitment)) : ''}`
                              : `${r.quantity ?? ''} × ${r.description}`}
                          </Text>
                        </TableCell>
                        <TableCell><Text size={200}>{termLabel(r.term)}</Text></TableCell>
                        <TableCell className={styles.numCol}><Text size={200}>{r.effectiveCostPct != null ? `${r.effectiveCostPct.toFixed(0)}%` : '—'}</Text></TableCell>
                        <TableCell className={styles.numCol}><Text size={200} weight="semibold">{t.commit.perMonth(money(r.monthlySavingsUsd))}</Text></TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </div>
            </>
          )}
          {data.notes.map((n, k) => <Text key={k} size={200} className={styles.muted}>{n}</Text>)}
        </>
      )}
    </div>
  )
}
