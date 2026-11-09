import { lazy, Suspense, useCallback, useEffect, useState } from 'react'
import { Spinner } from '@fluentui/react-components'
import { FinOpsApi, getCurrentUserName, productName, type SubscriptionScope } from './api/client'
import { useCurrency } from './lib/currency'
import { AskProvider, useAsk } from './lib/ask'
import { useRoute } from './lib/route'
import { setAllocationTags } from './lib/allocation'
import { HeaderTools } from './components/HeaderTools'
import { AskPanel } from './components/AskPanel'
import { useTheme } from './themes/context'
import type { ShellPage } from './themes/types'
import { t } from './i18n'

// Lazy-loaded so the initial paint doesn't pull every page (and Recharts) at once.
const Overview = lazy(() => import('./pages/Overview').then((m) => ({ default: m.Overview })))
const Statements = lazy(() => import('./pages/Statements').then((m) => ({ default: m.Statements })))
const Spikes = lazy(() => import('./pages/Spikes').then((m) => ({ default: m.Spikes })))
const Savings = lazy(() => import('./pages/Savings').then((m) => ({ default: m.Savings })))
const Reservations = lazy(() => import('./pages/Reservations').then((m) => ({ default: m.Reservations })))

// One page for the regular look (Overview); the others are where its links lead.
const PAGE_KEYS = ['dashboard', 'savings', 'reservations', 'statements', 'spikes'] as const
const PAGES: ShellPage[] = PAGE_KEYS.map((key) => ({ key, ...t.app.pages[key] }))

// The page itself, without chrome — the theme's Shell (src/themes/<id>/Shell.tsx) frames it.
function Page({ page, ready }: { page: string; ready: boolean }) {
  if (!ready) return <Spinner label={t.common.loading} />
  return (
    <Suspense fallback={<Spinner label={t.common.loading} />}>
      {page === 'dashboard' && <Overview />}
      {page === 'statements' && <Statements />}
      {page === 'spikes' && <Spikes />}
      {page === 'savings' && <Savings />}
      {page === 'reservations' && <Reservations />}
    </Suspense>
  )
}

function Framed({ page, goTo }: { page: (typeof PAGES)[number]['key']; goTo: (p: (typeof PAGES)[number]['key']) => void }) {
  const { theme } = useTheme()
  const { askAbout } = useAsk()
  const { basisLabel, basisDetail } = useCurrency()
  const name = productName()
  const [userName, setUserName] = useState<string | null>(null)
  useEffect(() => { getCurrentUserName().then(setUserName) }, [])

  // The subscription scope is shown, never edited here (Setup/Set-SubscriptionScope.ps1).
  const [scope, setScope] = useState<SubscriptionScope | null>(null)
  // undefined = the config could not be read (the API did not answer); null = no AI configured.
  const [aiModel, setAiModel] = useState<string | null | undefined>(undefined)
  // The config also names the allocation tags (the first is the owner); pages wait for it so a
  // finding never shows "Owner" on one render and "Service lead" on the next.
  const [configLoaded, setConfigLoaded] = useState(false)
  useEffect(() => {
    FinOpsApi.getPortalConfig()
      .then((c) => {
        setAllocationTags(c.allocationTagKeys, c.allocationTagLabels)
        setScope(c.subscriptionScope ?? null)
        setAiModel(c.aiConfigured ? c.aiModel ?? 'configured' : null)
      })
      .catch(() => setScope(null))
      .finally(() => setConfigLoaded(true))
  }, [])

  const active = PAGES.find((p) => p.key === page) ?? PAGES[0]
  useEffect(() => { document.title = `${active.label} · ${name}` }, [active.label, name])

  const ask = useCallback((q: string) => { if (q.trim()) askAbout(q.trim(), null) }, [askAbout])
  const aiStatus = aiModel === undefined ? t.app.aiNoAnswer : aiModel ? t.app.aiOn(aiModel) : t.app.aiOff

  const Shell = theme.Shell
  return (
    <>
      <Shell
        productName={name}
        pages={PAGES}
        page={page}
        goTo={goTo}
        ask={ask}
        tools={<HeaderTools scope={scope} userName={userName} />}
        basisLabel={basisLabel}
        basisDetail={basisDetail}
        aiStatus={aiStatus}
      >
        <Page page={page} ready={configLoaded} />
      </Shell>
      <AskPanel />
    </>
  )
}

export function App() {
  // The page lives in the URL (#/savings, #/changes?period=month), so every view can be
  // bookmarked, shared, and reached with Back/Forward.
  const [route, goTo] = useRoute()
  return (
    <AskProvider navigate={goTo}>
      <Framed page={route.page} goTo={goTo} />
    </AskProvider>
  )
}
