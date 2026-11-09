import { t } from '../i18n'
import { en } from '../i18n/en'

// Who owns a finding: the allocation tags the backend stamps on every resource-level row
// (Allocation.psm1) — the tags configured for the deployment (e.g. ServiceLead,
// ProjectName, CostCenter, Environment; owner, cost centre, environment, application by default),
// plus the resource group. Tags as they are now, inherited from the resource group when missing.
//
// The FIRST configured tag is the owner: its value is what "owner" filters and labels show, under
// that tag's own name ("Service lead: jane"). setAllocationTags() is fed from the portal
// config before the pages render (App.tsx), and from responses that carry labels.

export type Allocation = Record<string, string>

let ownerTagKey = 'owner'
const configuredLabels: Record<string, string> = {}

/** Record the configured tag keys (normalised, in order) and their display names. */
export function setAllocationTags(keys?: string[] | null, labels?: Record<string, string> | null): void {
  if (keys?.length) ownerTagKey = keys[0]
  if (labels) Object.assign(configuredLabels, labels)
}

/** The normalised key of the tag that names the owner (the first configured one). */
export function ownerTag(): string {
  return ownerTagKey
}

/** Display name of the owner tag, e.g. "Service lead" (or "Owner"). */
export function ownerLabel(): string {
  return tagLabel(ownerTagKey)
}

/** The value used for owner filters and labels; '' when the row carries no allocation. */
export function ownerOf(a: Allocation | null | undefined): string {
  if (!a) return ''
  return a[ownerTagKey] ?? ''
}

/** Filter key for a row's owner: its value, or a marker for rows with no allocation at all. */
export const NO_ALLOCATION = '(not a resource)'
export function ownerKey(a: Allocation | null | undefined): string {
  return a ? ownerOf(a) || '(untagged)' : NO_ALLOCATION
}

// The default tags' names in the portal's language; a configured tag keeps the name it was given.
const DEFAULT_TAGS = ['owner', 'costcenter', 'environment', 'application', 'resourceGroup'] as const
export function tagLabel(key: string): string {
  const builtIn = (DEFAULT_TAGS as readonly string[]).includes(key) ? t.tags[key as (typeof DEFAULT_TAGS)[number]] : null
  // The server names the built-in tags in English ("Owner"); those follow the portal's language.
  // A tag the tenant configured itself keeps the name it was given.
  const configured = configuredLabels[key]
  if (builtIn && (!configured || configured.toLowerCase() === en.tags[key as (typeof DEFAULT_TAGS)[number]].toLowerCase())) return builtIn
  return configured ?? key.charAt(0).toUpperCase() + key.slice(1)
}

/** One line for a tooltip: "Owner: alice · Cost centre: CC-100 · Environment: prod". */
export function allocationSummary(a: Allocation | null | undefined): string {
  if (!a) return ''
  return Object.entries(a)
    .filter(([k, v]) => k !== 'resourceGroup' && v)
    .map(([k, v]) => `${tagLabel(k)}: ${v}`)
    .join(' · ')
}

/** Allocation tag keys present on a set of rows, in first-seen order (resourceGroup excluded). */
export function allocationKeys(rows: (Allocation | null | undefined)[]): string[] {
  const keys: string[] = []
  for (const a of rows) {
    if (!a) continue
    for (const k of Object.keys(a)) if (k !== 'resourceGroup' && !keys.includes(k)) keys.push(k)
  }
  return keys
}
