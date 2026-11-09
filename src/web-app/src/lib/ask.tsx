import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'
import type { AskContext } from '../api/client'

// Ask lives in a panel that slides in over any page (components/AskPanel.tsx). "Ask about this"
// opens it with a question and the item the user was looking at, which stays on screen behind
// it. App owns navigation, so it supplies `navigate`; the Ask box consumes the seed once.

export type AskSeed = { question: string; context: AskContext | null; nonce: number }

export type PageKey = 'dashboard' | 'statements' | 'spikes' | 'savings' | 'reservations'

type AskContextValue = {
  /** Open the Ask panel with a pre-filled question about an item (it is asked right away). */
  askAbout: (question: string, context: AskContext | null) => void
  /** Open another page — e.g. the Overview's movers link into Subscriptions. */
  goTo: (page: PageKey) => void
  /** The pending seed, if any. The Ask page reads it and calls consumeSeed(). */
  seed: AskSeed | null
  consumeSeed: () => void
  /** Whether the Ask panel is open. */
  panelOpen: boolean
  setPanelOpen: (open: boolean) => void
}

const Ctx = createContext<AskContextValue>({
  askAbout: () => undefined,
  goTo: () => undefined,
  seed: null,
  consumeSeed: () => undefined,
  panelOpen: false,
  setPanelOpen: () => undefined,
})

export function AskProvider({ navigate, children }: { navigate: (page: PageKey) => void; children: ReactNode }) {
  const [seed, setSeed] = useState<AskSeed | null>(null)
  const [panelOpen, setPanelOpen] = useState(false)
  const askAbout = useCallback((question: string, context: AskContext | null) => {
    setSeed({ question, context, nonce: Date.now() })
    setPanelOpen(true)
  }, [])
  const consumeSeed = useCallback(() => setSeed(null), [])
  const value = useMemo(
    () => ({ askAbout, goTo: navigate, seed, consumeSeed, panelOpen, setPanelOpen }),
    [askAbout, navigate, seed, consumeSeed, panelOpen],
  )
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useAsk(): AskContextValue {
  return useContext(Ctx)
}

/** Subscription GUID from an ARM id or a bare GUID. */
export function subscriptionIdOf(value?: string | null): string | null {
  if (!value) return null
  if (/^[0-9a-f-]{36}$/i.test(value)) return value.toLowerCase()
  const m = /\/subscriptions\/([0-9a-f-]{36})/i.exec(value)
  return m ? m[1].toLowerCase() : null
}
