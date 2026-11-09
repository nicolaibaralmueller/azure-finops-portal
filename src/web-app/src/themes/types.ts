import type { ComponentType, ReactNode } from 'react'
import type { Theme } from '@fluentui/react-components'
import type { PageKey } from '../lib/ask'

// A THEME is one folder under src/themes/<id>/ with an index.ts whose default export is a
// ThemeDefinition. The registry (registry.ts) finds every folder at build time, so a theme is
// added by adding its folder and removed by deleting it — nothing else refers to a theme by name.
// The deployment picks one with deploy.ps1 -Theme <id> (written to config.json).

/** Colours the pages draw with in code (charts, priority bars, colour codes) — CSS can't reach those. */
export type Palette = {
  priority: Record<1 | 2 | 3, { bg: string; fg: string }>
  env: Record<'non-production' | 'production' | 'unknown', string>
  /** money that can be saved, shown as text */
  positive: string
  chartLine: string
  chartFill: string
  chartGrid: string
  chartAxis: string
  /** the shaded "period checked for cost changes" band on the trend */
  changeArea: string
  tooltip: { bg: string; fg: string; label: string }
}

export type ShellPage = { key: PageKey; label: string; subtitle: string }

/** What the app hands every theme's shell; the shell decides the layout around the page. */
export type ShellProps = {
  productName: string
  pages: ShellPage[]
  page: PageKey
  goTo: (page: PageKey) => void
  /** Ask a question from anywhere (a theme may offer a search box for it). */
  ask: (question: string) => void
  /** Subscription scope, currency and user controls — shared, the shell only places them. */
  tools: ReactNode
  basisLabel: string
  basisDetail: string
  /** One line on the AI provider, for a footer or status area. */
  aiStatus: string
  /** The page. The Overview renders its own heading; other pages get theirs from the shell. */
  children: ReactNode
}

export type ThemeDefinition = {
  /** The folder name, and the value of deploy.ps1 -Theme. */
  id: string
  label: string
  /** True when the theme has a dark variant (it then follows the viewer's OS setting). */
  supportsDark: boolean
  fluent: (dark: boolean) => Theme
  palette: (dark: boolean) => Palette
  Shell: ComponentType<ShellProps>
}
