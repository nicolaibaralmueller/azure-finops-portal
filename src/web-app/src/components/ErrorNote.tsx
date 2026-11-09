import { Button, Text, Tooltip, makeStyles, shorthands, tokens } from '@fluentui/react-components'
import { Copy16Regular, ErrorCircle16Regular } from '@fluentui/react-icons'
import { useState } from 'react'
import { ApiError } from '../api/client'
import { t } from '../i18n'

const useStyles = makeStyles({
  root: {
    display: 'flex',
    alignItems: 'flex-start',
    columnGap: tokens.spacingHorizontalS,
    ...shorthands.padding(tokens.spacingVerticalS, tokens.spacingHorizontalM),
    backgroundColor: tokens.colorStatusDangerBackground1,
    ...shorthands.border('1px', 'solid', tokens.colorStatusDangerBorder1),
    ...shorthands.borderRadius(tokens.borderRadiusMedium),
  },
  icon: { color: tokens.colorStatusDangerForeground1, flexShrink: 0, marginTop: '2px' },
  body: { display: 'flex', flexDirection: 'column', rowGap: '2px' },
  ref: { display: 'flex', alignItems: 'center', columnGap: '4px', color: tokens.colorNeutralForeground3 },
})

export type FriendlyError = { text: string; correlationId: string | null }

/**
 * Turn whatever a failed call threw into a sentence a user can act on, plus the server's
 * correlation id when there is one (the API logs the real detail against it — see
 * Write-ErrorBody). Never shows a raw stack or a URL.
 */
export function friendlyError(e: unknown, what: string = t.errors.this): FriendlyError {
  if (e instanceof ApiError) {
    const body = e.body as { correlationId?: unknown } | null
    const correlationId = typeof body?.correlationId === 'string' ? body.correlationId : null
    const text =
      e.status === 401 ? t.errors.expired
        : e.status === 403 ? t.errors.forbidden(what)
          : e.status === 404 ? t.errors.notFound(what)
            : e.status === 429 ? e.serverMessage ?? t.errors.throttled
              : e.status >= 500 ? t.errors.server(what)
                : e.serverMessage ?? t.errors.couldNotLoad(what)
    return { text, correlationId }
  }
  if (e instanceof TypeError) {
    return { text: t.errors.unreachable, correlationId: null }
  }
  return { text: t.errors.couldNotLoad(what), correlationId: null }
}

export function ErrorNote({ error, what }: { error: unknown; what?: string }) {
  const styles = useStyles()
  const { text, correlationId } = friendlyError(error, what)
  const [copied, setCopied] = useState(false)
  return (
    <div className={styles.root} role="alert">
      <ErrorCircle16Regular className={styles.icon} />
      <div className={styles.body}>
        <Text>{text}</Text>
        {correlationId && (
          <span className={styles.ref}>
            <Text size={200}>{t.errors.reference} <code>{correlationId}</code></Text>
            <Tooltip content={copied ? t.common.copied : t.errors.copyReference} relationship="label">
              <Button
                size="small"
                appearance="transparent"
                icon={<Copy16Regular />}
                onClick={() => {
                  void navigator.clipboard?.writeText(correlationId).then(() => setCopied(true))
                }}
              />
            </Tooltip>
          </span>
        )}
      </div>
    </div>
  )
}
