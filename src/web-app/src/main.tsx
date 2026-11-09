import React from 'react'
import { createRoot } from 'react-dom/client'
import { FluentProvider } from '@fluentui/react-components'
import { configuredLanguage, configuredTheme, loadConfig } from './api/client'
import { setLanguage } from './i18n'
import { CurrencyProvider } from './lib/currency'
import { resolveTheme } from './themes/registry'
import { ThemeProvider, useDarkMode } from './themes/context'
import type { ThemeDefinition } from './themes/types'
import './base.css'

function Root({ theme, App }: { theme: ThemeDefinition; App: () => React.ReactElement }) {
  const dark = useDarkMode(theme)
  return (
    <ThemeProvider theme={theme} dark={dark}>
      <FluentProvider theme={theme.fluent(dark)} style={{ minHeight: '100%', background: 'transparent' }}>
        <CurrencyProvider>
          <App />
        </CurrencyProvider>
      </FluentProvider>
    </ThemeProvider>
  )
}

// Load runtime config (API base URL, product name, theme, language) BEFORE the first render so the
// app is tenant-agnostic — the build never embeds a hostname, a look or a language. The app module
// is imported only once the language is set: its page labels are read when it loads.
async function bootstrap() {
  await loadConfig()
  setLanguage(configuredLanguage())
  const theme = resolveTheme(configuredTheme())
  const { App } = await import('./App')
  createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
      <Root theme={theme} App={App} />
    </React.StrictMode>,
  )
}

void bootstrap()
