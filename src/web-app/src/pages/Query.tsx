import { useEffect, useRef, useState } from 'react'
import {
  Text,
  Badge,
  Textarea,
  Button,
  Spinner,
  Table,
  TableHeader,
  TableHeaderCell,
  TableRow,
  TableBody,
  TableCell,
  Tag,
  makeStyles,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import { Send20Regular, Sparkle16Regular, Person16Regular, Add16Regular } from '@fluentui/react-icons'
import {
  ApiError,
  FinOpsApi,
  type AskContext,
  type AskHistoryTurn,
  type PortalConfig,
  type QueryCostsResponse,
} from '../api/client'
import { useAsk } from '../lib/ask'
import { NumHeaderCell } from '../components/NumHeaderCell'
import { ExportButton } from '../components/ExportButton'
import { useHashParam } from '../lib/route'
import { t, locale } from '../i18n'

const useStyles = makeStyles({
  root: { rowGap: tokens.spacingVerticalM, display: 'flex', flexDirection: 'column', maxWidth: '1040px' },
  askPanel: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalS,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
  },
  row: { display: 'flex', columnGap: tokens.spacingHorizontalM, alignItems: 'flex-end' },
  suggestions: { display: 'flex', columnGap: tokens.spacingHorizontalS, rowGap: tokens.spacingVerticalXS, flexWrap: 'wrap' },
  context: { display: 'flex', alignItems: 'center', columnGap: tokens.spacingHorizontalS, flexWrap: 'wrap' },
  turn: { display: 'flex', flexDirection: 'column', rowGap: tokens.spacingVerticalS },
  question: { display: 'flex', alignItems: 'flex-start', columnGap: tokens.spacingHorizontalS },
  qIcon: { color: tokens.colorNeutralForeground3, flexShrink: 0, marginTop: '3px' },
  answer: {
    display: 'flex',
    alignItems: 'flex-start',
    columnGap: tokens.spacingHorizontalS,
    ...shorthands.padding(tokens.spacingVerticalM, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorBrandBackground2,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    ...shorthands.border('1px', 'solid', tokens.colorBrandStroke2),
  },
  aiIcon: { color: tokens.colorBrandForeground1, flexShrink: 0, marginTop: '3px' },
  answerBody: { display: 'flex', flexDirection: 'column', alignItems: 'flex-start', rowGap: tokens.spacingVerticalXS, whiteSpace: 'pre-wrap' },
  tablePanel: {
    backgroundColor: tokens.colorNeutralBackground1,
    ...shorthands.borderRadius(tokens.borderRadiusLarge),
    boxShadow: tokens.shadow2,
    ...shorthands.overflow('auto'),
    maxHeight: '420px',
  },
  num: { textAlign: 'right', whiteSpace: 'nowrap' },
  up: { color: tokens.colorPaletteRedForeground1 },
  down: { color: tokens.colorPaletteGreenForeground1 },
  muted: { color: tokens.colorNeutralForeground3 },
  error: { color: tokens.colorPaletteRedForeground1 },
  pre: {
    margin: 0,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorNeutralBackground3,
    ...shorthands.borderRadius(tokens.borderRadiusMedium),
    fontSize: tokens.fontSizeBase200,
    overflowX: 'auto',
  },
})


type Turn = {
  id: number
  question: string
  context: AskContext | null
  result?: QueryCostsResponse
  error?: string
}

const AMOUNT_COLS = new Set(['cost', 'previouscost', 'change', 'costusd', 'pretaxcost'])

function formatAmount(value: unknown, currency: string): string {
  const n = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(n)) return String(value ?? '')
  try {
    return new Intl.NumberFormat(locale(), { style: 'currency', currency: currency || 'USD', maximumFractionDigits: 0 }).format(n)
  } catch {
    return `${Math.round(n).toLocaleString(locale())} ${currency}`
  }
}

function formatCell(col: string, row: Record<string, unknown>): string {
  const v = row[col]
  const key = col.toLowerCase()
  if (AMOUNT_COLS.has(key)) {
    const s = formatAmount(v, String(row['Currency'] ?? row['currency'] ?? 'USD'))
    return key === 'change' && typeof v === 'number' && v > 0 ? `+${s}` : s
  }
  if (key === 'changepct') return v == null ? '—' : `${Number(v) > 0 ? '+' : ''}${Number(v).toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%`
  if (key === 'usagedate' && /^\d{8}$/.test(String(v))) {
    const s = String(v)
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6)}`
  }
  if (key === 'billingmonth' && typeof v === 'string') return v.slice(0, 7)
  return String(v ?? '')
}

function ResultTable({ result }: { result: QueryCostsResponse }) {
  const styles = useStyles()
  const columns = (result.columns?.length ? result.columns : Object.keys(result.rows[0] ?? {}))
    .filter((c) => c.toLowerCase() !== 'currency')
  const allColumns = result.columns?.length ? result.columns : Object.keys(result.rows[0] ?? {})
  if (!result.rows.length) return null
  return (
    <>
    <ExportButton
      fileBase="ask-results"
      rows={result.rows}
      // Raw values: the rows are already in the billing currency, with their own Currency column.
      columns={allColumns.map((c) => ({ header: c, value: (r: Record<string, unknown>) => r[c] as string | number | null }))}
    />
    <div className={styles.tablePanel}>
      <Table size="small" aria-label={t.query.results}>
        <TableHeader>
          <TableRow>
            {columns.map((c) => {
              const label = c === 'PreviousCost' ? t.query.previousPeriod : c === 'Cost' && result.comparison ? t.query.thisPeriod : c === 'ChangePct' ? t.query.changePct : c
              return AMOUNT_COLS.has(c.toLowerCase()) || c.toLowerCase() === 'changepct'
                ? <NumHeaderCell key={c}>{label}</NumHeaderCell>
                : <TableHeaderCell key={c}>{label}</TableHeaderCell>
            })}
          </TableRow>
        </TableHeader>
        <TableBody>
          {result.rows.map((r, i) => (
            <TableRow key={i}>
              {columns.map((c) => {
                const lc = c.toLowerCase()
                const isNum = AMOUNT_COLS.has(lc) || lc === 'changepct'
                const signed = (lc === 'change' || lc === 'changepct') && typeof r[c] === 'number'
                const cls = signed ? ((r[c] as number) > 0 ? styles.up : (r[c] as number) < 0 ? styles.down : undefined) : undefined
                return (
                  <TableCell key={c} className={isNum ? styles.num : undefined}>
                    <Text size={200} className={cls}>{formatCell(c, r)}</Text>
                  </TableCell>
                )
              })}
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
    </>
  )
}

export function Query() {
  const styles = useStyles()
  const { seed, consumeSeed } = useAsk()
  // #/ask?q=… pre-fills the box. It is deliberately NOT asked automatically: a link must never
  // spend someone's AI budget just by being opened.
  const [linkedQuestion] = useHashParam('q', '')
  const [question, setQuestion] = useState(linkedQuestion)
  const [busy, setBusy] = useState(false)
  const [turns, setTurns] = useState<Turn[]>([])
  const [context, setContext] = useState<AskContext | null>(null)
  const [config, setConfig] = useState<PortalConfig | null>(null)
  const nextId = useRef(1)
  const bottom = useRef<HTMLDivElement>(null)

  useEffect(() => {
    FinOpsApi.getPortalConfig().then(setConfig).catch(() => setConfig(null))
  }, [turns.length])

  useEffect(() => { bottom.current?.scrollIntoView({ behavior: 'smooth', block: 'end' }) }, [turns])

  const ask = async (text: string, ctx: AskContext | null, fresh: boolean) => {
    const q = text.trim()
    if (!q || busy) return
    const history: AskHistoryTurn[] = fresh
      ? []
      : turns
          .filter((turn) => turn.result)
          .slice(-3)
          .map((turn) => ({ question: turn.question, spec: turn.result!.spec, answer: turn.result!.answer }))
    const id = nextId.current++
    setTurns((prev) => [...(fresh ? [] : prev), { id, question: q, context: ctx }])
    setQuestion('')
    setBusy(true)
    try {
      const result = await FinOpsApi.queryCosts(q, history, ctx)
      setTurns((prev) => prev.map((turn) => (turn.id === id ? { ...turn, result } : turn)))
    } catch (e) {
      let msg = t.query.failed(String(e))
      if (e instanceof ApiError) {
        const body = e.body as { aiLimitReached?: boolean } | null
        if (e.status === 429) {
          msg = body?.aiLimitReached
            ? t.query.aiLimit(e.serverMessage ?? '')
            : t.query.throttled
        } else if (e.status === 409) msg = e.serverMessage ?? t.query.noAi
        else if (e.serverMessage) msg = e.serverMessage
      }
      setTurns((prev) => prev.map((turn) => (turn.id === id ? { ...turn, error: msg } : turn)))
    } finally {
      setBusy(false)
    }
  }

  // "Ask about this" from another page: start a new conversation about that item.
  useEffect(() => {
    if (!seed) return
    consumeSeed()
    setContext(seed.context)
    void ask(seed.question, seed.context, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seed])

  const newConversation = () => { setTurns([]); setContext(null); setQuestion('') }

  const limitText =
    config?.aiDailyCallLimit != null
      ? config.aiDailyCallLimit === 0
        ? t.query.aiOff
        : t.query.aiCalls(config.aiCallsToday ?? 0, config.aiDailyCallLimit)
      : null

  return (
    <div className={styles.root}>
      {turns.map((turn) => (
        <div key={turn.id} className={styles.turn}>
          <div className={styles.question}>
            <Person16Regular className={styles.qIcon} />
            <Text weight="semibold">{turn.question}</Text>
          </div>
          {!turn.result && !turn.error && <Spinner size="tiny" label={t.query.working} />}
          {turn.error && <Text className={styles.error}>{turn.error}</Text>}
          {turn.result && (
            <>
              <div className={styles.answer}>
                <Sparkle16Regular className={styles.aiIcon} />
                <div className={styles.answerBody}>
                  <Text>{turn.result.answer}</Text>
                  <Text size={200} className={styles.muted}>
                    {[
                      turn.result.scope ? t.query.scope(turn.result.scope) : null,
                      turn.result.comparison
                        ? t.query.compared(turn.result.comparison.currentFrom, turn.result.comparison.currentTo,
                            turn.result.comparison.previousFrom, turn.result.comparison.previousTo, !!turn.result.comparison.approximate)
                        : null,
                      t.query.rows(turn.result.rowCount),
                    ].filter(Boolean).join(' · ')}
                  </Text>
                  {turn.result.grounded === false && (
                    <Badge appearance="tint" color="warning">{t.query.unverified}</Badge>
                  )}
                </div>
              </div>
              <ResultTable result={turn.result} />
              <details>
                <summary className={styles.muted}>{t.query.showQuery}</summary>
                <pre className={styles.pre}>{JSON.stringify(turn.result.query, null, 2)}</pre>
              </details>
            </>
          )}
        </div>
      ))}

      <div className={styles.askPanel} ref={bottom}>
        {context && (
          <div className={styles.context}>
            <Text size={200} className={styles.muted}>{t.query.askingAbout}</Text>
            <Tag size="small" dismissible dismissIcon={{ 'aria-label': t.query.dropContext }} onClick={() => setContext(null)}>
              {context.title}
            </Tag>
          </div>
        )}
        <div className={styles.row}>
          <Textarea
            style={{ flexGrow: 1 }}
            resize="vertical"
            placeholder={turns.length ? t.query.followUp : t.query.firstQuestion}
            value={question}
            onChange={(_e, d) => setQuestion(d.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void ask(question, context, false) } }}
          />
          <Button appearance="primary" icon={<Send20Regular />} disabled={busy || !question.trim()} onClick={() => void ask(question, context, false)}>
            {t.query.ask}
          </Button>
        </div>
        <div className={styles.suggestions}>
          {turns.length === 0 ? (
            t.query.suggestions.map((s) => (
              <Button key={s} size="small" shape="circular" appearance="secondary" disabled={busy} onClick={() => void ask(s, null, true)}>
                {s}
              </Button>
            ))
          ) : (
            <Button size="small" appearance="subtle" icon={<Add16Regular />} disabled={busy} onClick={newConversation}>
              {t.query.newConversation}
            </Button>
          )}
        </div>
        {limitText && <Text size={200} className={styles.muted}>{limitText}</Text>}
      </div>
    </div>
  )
}
