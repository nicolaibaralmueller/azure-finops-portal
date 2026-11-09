import { webDarkTheme, webLightTheme, type Theme } from '@fluentui/react-components'
import './theme.css'
import { AzurePortalShell } from './Shell'
import type { Palette, ThemeDefinition } from '../types'

// Theme "azure-portal": the look of portal.azure.com — blue top bar, portal menu, breadcrumb,
// dashboard tiles on a grey canvas, Segoe UI. Light and dark, following the viewer's OS setting.
// Delete this folder to remove the theme.

const font = "'Segoe UI', 'Segoe UI Web (West European)', -apple-system, BlinkMacSystemFont, Roboto, 'Helvetica Neue', sans-serif"
const light: Theme = { ...webLightTheme, fontFamilyBase: font, borderRadiusMedium: '2px', borderRadiusLarge: '2px' }
const dark: Theme = { ...webDarkTheme, fontFamilyBase: font, borderRadiusMedium: '2px', borderRadiusLarge: '2px' }

const lightPalette: Palette = {
  priority: { 1: { bg: '#c50f1f', fg: '#ffffff' }, 2: { bg: '#ca5010', fg: '#ffffff' }, 3: { bg: '#8a8886', fg: '#ffffff' } },
  env: { 'non-production': '#ff8c00', production: '#0078d4', unknown: '#a19f9d' },
  positive: '#107c10',
  chartLine: '#0078d4',
  chartFill: 'rgba(0,120,212,.14)',
  chartGrid: '#edebe9',
  chartAxis: '#605e5c',
  changeArea: 'rgba(197,15,31,.10)',
  tooltip: { bg: '#ffffff', fg: '#323130', label: '#0078d4' },
}
const darkPalette: Palette = {
  priority: { 1: { bg: '#d13438', fg: '#ffffff' }, 2: { bg: '#e3712f', fg: '#1b1a19' }, 3: { bg: '#a19f9d', fg: '#1b1a19' } },
  env: { 'non-production': '#ffaa44', production: '#479ef5', unknown: '#8a8886' },
  positive: '#54b054',
  chartLine: '#479ef5',
  chartFill: 'rgba(71,158,245,.20)',
  chartGrid: '#3b3a39',
  chartAxis: '#c8c6c4',
  changeArea: 'rgba(220,98,109,.18)',
  tooltip: { bg: '#292827', fg: '#f3f2f1', label: '#479ef5' },
}

const theme: ThemeDefinition = {
  id: 'azure-portal',
  label: 'Azure Portal',
  supportsDark: true,
  fluent: (isDark) => (isDark ? dark : light),
  palette: (isDark) => (isDark ? darkPalette : lightPalette),
  Shell: AzurePortalShell,
}
export default theme
