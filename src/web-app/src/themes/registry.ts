import type { ThemeDefinition } from './types'

// Every src/themes/<id>/index.ts, found at build time. Deleting a theme's folder removes it from
// the next build; nothing else in the app names a theme.
const modules = import.meta.glob<{ default: ThemeDefinition }>('./*/index.ts', { eager: true })

const themes: ThemeDefinition[] = Object.values(modules)
  .map((m) => m.default)
  .filter((t): t is ThemeDefinition => !!t && typeof t.id === 'string')
  .sort((a, b) => a.id.localeCompare(b.id))

/** Used when config.json names no theme. If its folder is gone, the first theme found is used. */
const DEFAULT_THEME = 'azure-portal'

export function listThemes(): ThemeDefinition[] {
  return themes
}

/** The configured theme, else the default, else the first one found. */
export function resolveTheme(id?: string | null): ThemeDefinition {
  if (!themes.length) throw new Error('No theme found under src/themes/. Each theme is a folder with an index.ts.')
  const wanted = (id ?? '').trim().toLowerCase()
  const hit = themes.find((t) => t.id === wanted)
  if (wanted && !hit) console.warn(`Theme '${wanted}' is not in this build; using a default. Available: ${themes.map((t) => t.id).join(', ')}`)
  return hit ?? themes.find((t) => t.id === DEFAULT_THEME) ?? themes[0]
}
