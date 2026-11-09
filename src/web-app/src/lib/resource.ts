import { t } from '../i18n'

// Azure Resource ID (ARM) parsing + presentation helpers.
//
// The Function App stores and returns the FULL ARM resource id, e.g.
//   /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{name}
// but also TENANT-scoped ids with no subscription segment, e.g.
//   /providers/microsoft.capacity/reservationorders/{guid}
// The UI turns these into a human-readable name, resource group, friendly type, and a deep
// link into the Azure portal. Where the ARM name segment is itself a GUID (reservation
// orders, savings plans) the server resolves the real display name and sends it as
// `resourceName`; parsing here is the fallback. Bare recommendation GUIDs (no resource
// path at all) are reported as non-ARM and rendered as plain text with no link.

export type ParsedResource = {
  raw: string
  isArm: boolean
  name: string
  /** True when the best name we could parse is still an opaque GUID. */
  nameIsGuid: boolean
  resourceGroup: string | null
  subscriptionId: string | null
  /** Full type, e.g. "Microsoft.Compute/virtualMachines". */
  resourceType: string | null
  /** Human label, e.g. "Virtual machine". */
  friendlyType: string
  /** Deep link to the resource in the Azure portal, or null when not an ARM id. */
  portalUrl: string | null
}

// Friendly labels for common cost-bearing resource types: t.resource.types (i18n), keyed lower-case.

const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function isGuidLike(value: string): boolean {
  return GUID_RE.test(value.trim())
}

/** "fbf41ab0-3b51-…" — enough of a GUID to recognize it, short enough to scan. */
export function shortGuid(guid: string): string {
  return `${guid.slice(0, 13)}…`
}

// camelCase / PascalCase type token → spaced, sentence-case fallback label.
function prettifyTypeToken(token: string): string {
  const spaced = token
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/[_-]+/g, ' ')
    .trim()
  if (!spaced) return t.resource.resource
  return spaced.charAt(0).toUpperCase() + spaced.slice(1).toLowerCase()
}

function segAfter(segments: string[], key: string): string | null {
  const i = segments.findIndex((s) => s.toLowerCase() === key)
  return i >= 0 && i + 1 < segments.length ? segments[i + 1] : null
}

// The tenant-agnostic deep-link form; works for subscription- AND tenant-scoped ids.
const portalLink = (id: string) => `https://portal.azure.com/#resource${id}/overview`

export function parseResourceId(raw: string | null | undefined): ParsedResource {
  const value = (raw ?? '').trim()
  const notArm: ParsedResource = {
    raw: value,
    isArm: false,
    name: value || t.common.unknown,
    nameIsGuid: isGuidLike(value),
    resourceGroup: null,
    subscriptionId: null,
    resourceType: null,
    friendlyType: t.resource.resource,
    portalUrl: null,
  }

  const lower = value.toLowerCase()
  // ARM ids are subscription-scoped (/subscriptions/...) or tenant-scoped (/providers/...).
  if (!lower.startsWith('/subscriptions/') && !lower.startsWith('/providers/')) {
    return notArm
  }

  const segments = value.split('/').filter(Boolean)
  const subscriptionId = segAfter(segments, 'subscriptions')
  const resourceGroup = segAfter(segments, 'resourcegroups')

  const provIdx = segments.findIndex((s) => s.toLowerCase() === 'providers')
  if (provIdx < 0 || provIdx + 2 >= segments.length) {
    // Subscription- or resource-group-scoped id with no provider path — still linkable.
    return {
      ...notArm,
      isArm: true,
      name: resourceGroup ?? subscriptionId ?? value,
      nameIsGuid: isGuidLike(resourceGroup ?? subscriptionId ?? value),
      resourceGroup,
      subscriptionId,
      friendlyType: resourceGroup ? t.resource.resourceGroup : t.resource.subscription,
      portalUrl: portalLink(value),
    }
  }

  const namespace = segments[provIdx + 1]
  const rest = segments.slice(provIdx + 2) // alternating type, name, [type, name, ...]
  const name = rest[rest.length - 1]
  const typeTokens = rest.filter((_, i) => i % 2 === 0) // 0,2,4 → the type segments
  const resourceType = `${namespace}/${typeTokens.join('/')}`
  const friendly =
    t.resource.types[resourceType.toLowerCase()] ??
    prettifyTypeToken(typeTokens[typeTokens.length - 1] ?? namespace)

  return {
    raw: value,
    isArm: true,
    name,
    nameIsGuid: isGuidLike(name),
    resourceGroup,
    subscriptionId,
    resourceType,
    friendlyType: friendly,
    portalUrl: portalLink(value),
  }
}
