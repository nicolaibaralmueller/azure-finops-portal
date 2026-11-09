import { Link, Text, makeStyles, tokens } from '@fluentui/react-components'
import { Open16Regular } from '@fluentui/react-icons'
import { parseResourceId, shortGuid } from '../lib/resource'
import { t } from '../i18n'

const useStyles = makeStyles({
  root: { display: 'flex', flexDirection: 'column', rowGap: '2px', minWidth: 0 },
  nameRow: { display: 'flex', alignItems: 'center', columnGap: '4px', minWidth: 0 },
  name: {
    fontWeight: tokens.fontWeightSemibold,
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  icon: { fontSize: '12px', flexShrink: 0, color: tokens.colorBrandForeground1 },
  meta: { color: tokens.colorNeutralForeground3 },
})

type Props = {
  resourceId: string
  /** Server-resolved display name (authoritative when present). */
  displayName?: string | null
  /** Label to use when the id is an unresolvable GUID (e.g. "Savings plan recommendation"). */
  fallbackName?: string | null
  /** Optional meter / service label appended to the metadata line (e.g. "Virtual Machines"). */
  meter?: string | null
}

// Renders one Azure resource as: a clickable name that deep-links into the Azure portal,
// with "{friendly type} · {resource group}[ · {meter}]" underneath.
// Name preference: server-resolved display name → parsed ARM name → for GUID names,
// "{friendly type} {short guid}" (never a raw 36-char GUID, never a full ARM path).
export function ResourceRef({ resourceId, displayName, fallbackName, meter }: Props) {
  const styles = useStyles()
  const r = parseResourceId(resourceId)

  let name = displayName?.trim() || ''
  if (!name) {
    if (!r.isArm && r.nameIsGuid) name = fallbackName?.trim() || t.resource.unnamed(shortGuid(r.raw))
    else if (r.nameIsGuid) name = `${r.friendlyType} ${shortGuid(r.name)}`
    else name = r.name
  }

  const metaParts = [
    r.isArm ? r.friendlyType : null,
    r.resourceGroup,
    meter || null,
  ].filter(Boolean)

  return (
    <div className={styles.root}>
      <div className={styles.nameRow}>
        {r.portalUrl ? (
          <Link
            href={r.portalUrl}
            target="_blank"
            rel="noreferrer"
            className={styles.name}
            title={t.resource.openInPortal(r.raw)}
          >
            {name}
          </Link>
        ) : (
          <Text className={styles.name} title={r.raw}>{name}</Text>
        )}
        {r.portalUrl && <Open16Regular className={styles.icon} />}
      </div>
      {metaParts.length > 0 && (
        <Text size={200} className={styles.meta} title={r.raw}>
          {metaParts.join('  ·  ')}
        </Text>
      )}
    </div>
  )
}
