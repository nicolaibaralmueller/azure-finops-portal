import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Palette, ThemeDefinition } from './types'

type ThemeState = { theme: ThemeDefinition; dark: boolean; palette: Palette }

const Ctx = createContext<ThemeState | null>(null)

const darkQuery = () => (typeof window !== 'undefined' ? window.matchMedia?.('(prefers-color-scheme: dark)') : undefined)

/** Follows the viewer's light/dark setting for themes that have a dark variant. */
export function useDarkMode(theme: ThemeDefinition): boolean {
  const [dark, setDark] = useState(() => theme.supportsDark && !!darkQuery()?.matches)
  useEffect(() => {
    const q = darkQuery()
    if (!theme.supportsDark || !q) { setDark(false); return }
    const on = () => setDark(q.matches)
    q.addEventListener('change', on)
    return () => q.removeEventListener('change', on)
  }, [theme])
  return dark
}

export function ThemeProvider({ theme, dark, children }: { theme: ThemeDefinition; dark: boolean; children: ReactNode }) {
  // The theme's CSS is scoped to html.theme-<id> (and .theme-dark), so only one theme applies.
  useEffect(() => {
    const el = document.documentElement
    el.classList.add(`theme-${theme.id}`)
    el.classList.toggle('theme-dark', dark)
    el.style.colorScheme = dark ? 'dark' : 'light'
    return () => { el.classList.remove(`theme-${theme.id}`); el.classList.remove('theme-dark') }
  }, [theme, dark])
  return <Ctx.Provider value={{ theme, dark, palette: theme.palette(dark) }}>{children}</Ctx.Provider>
}

export function useTheme(): ThemeState {
  const v = useContext(Ctx)
  if (!v) throw new Error('useTheme outside ThemeProvider')
  return v
}

export function usePalette(): Palette {
  return useTheme().palette
}
