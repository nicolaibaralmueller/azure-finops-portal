import { useEffect, useRef, useState, type ReactElement } from 'react'
import {
  Navigation20Regular,
  Dismiss20Regular,
  Home20Regular,
  Savings20Regular,
  Receipt20Regular,
  DocumentText20Regular,
  ArrowTrendingLines20Regular,
  Search16Regular,
} from '@fluentui/react-icons'
import type { PageKey } from '../../lib/ask'
import type { ShellProps } from '../types'
import { t } from '../../i18n'

// Azure Portal layout: the blue top bar (menu button, product name, search box, account
// controls), a portal menu that flies out from the left, a breadcrumb, and the page on the grey
// dashboard canvas. The search box sends its question to Ask.

const ICONS: Record<PageKey, ReactElement> = {
  dashboard: <Home20Regular />,
  savings: <Savings20Regular />,
  reservations: <Receipt20Regular />,
  statements: <DocumentText20Regular />,
  spikes: <ArrowTrendingLines20Regular />,
}

// Wide screens dock the menu open beside the page (collapsible, remembered per browser); narrow
// ones keep it as a fly-out that starts closed.
const WIDE = '(min-width: 1024px)'
const DOCK_KEY = 'az-menu-docked'
function readDocked(): boolean {
  try { return window.localStorage.getItem(DOCK_KEY) !== '0' } catch { return true }
}
function useWide(): boolean {
  const [wide, setWide] = useState(() => window.matchMedia(WIDE).matches)
  useEffect(() => {
    const mq = window.matchMedia(WIDE)
    const onChange = () => setWide(mq.matches)
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [])
  return wide
}

export function AzurePortalShell({ productName, pages, page, goTo, ask, tools, basisLabel, basisDetail, aiStatus, children }: ShellProps) {
  const wide = useWide()
  const [docked, setDocked] = useState(readDocked)
  const [flyoutOpen, setFlyoutOpen] = useState(false)
  const [query, setQuery] = useState('')
  const menuRef = useRef<HTMLElement>(null)
  const active = pages.find((p) => p.key === page) ?? pages[0]
  const isDocked = wide && docked
  const menuOpen = isDocked || (!wide && flyoutOpen)
  const setMenuOpen = (v: boolean) => {
    if (wide) {
      setDocked(v)
      try { window.localStorage.setItem(DOCK_KEY, v ? '1' : '0') } catch { /* private mode: not remembered */ }
    } else setFlyoutOpen(v)
  }

  useEffect(() => {
    if (!flyoutOpen || wide) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setMenuOpen(false) }
    window.addEventListener('keydown', onKey)
    menuRef.current?.querySelector<HTMLButtonElement>('button[aria-current="page"], .az-menu-item')?.focus()
    return () => window.removeEventListener('keydown', onKey)
  }, [flyoutOpen, wide])

  const open = (p: PageKey) => { setFlyoutOpen(false); goTo(p) }

  return (
    <div className={`fo az-shell${isDocked ? ' az-docked' : ''}`}>
      <header className="az-topbar" data-print-hide>
        <button
          type="button"
          className="az-icon-btn"
          aria-label={menuOpen ? t.shell.hideMenu : t.shell.showMenu}
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen(!menuOpen)}
        >
          <Navigation20Regular />
        </button>
        <button type="button" className="az-product" onClick={() => open('dashboard')}>{productName}</button>
        <form
          className="az-search"
          role="search"
          onSubmit={(e) => { e.preventDefault(); if (query.trim()) { ask(query); setQuery('') } }}
        >
          <Search16Regular aria-hidden="true" />
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t.shell.searchPlaceholder}
            aria-label={t.ask.title}
          />
        </form>
        <div className="az-topbar-tools">{tools}</div>
      </header>

      {menuOpen && !wide && <div className="az-scrim" onClick={() => setMenuOpen(false)} aria-hidden="true" />}
      <nav ref={menuRef} className={`az-menu${menuOpen ? ' az-menu-open' : ''}`} aria-label={t.shell.menu} aria-hidden={!menuOpen}>
        <div className="az-menu-head">
          <button type="button" className="az-icon-btn az-icon-btn-dark" aria-label={t.shell.hideMenu} onClick={() => setMenuOpen(false)} tabIndex={menuOpen ? 0 : -1}>
            <Dismiss20Regular />
          </button>
          <span>{productName}</span>
        </div>
        {pages.map((p) => (
          <button
            key={p.key}
            type="button"
            className="az-menu-item"
            aria-current={page === p.key ? 'page' : undefined}
            onClick={() => open(p.key)}
            tabIndex={menuOpen ? 0 : -1}
          >
            <span className="az-menu-icon">{ICONS[p.key]}</span>
            {p.label}
          </button>
        ))}
      </nav>

      <main className="az-main">
        <nav className="az-breadcrumb" aria-label={t.shell.breadcrumb} data-print-hide>
          <button type="button" onClick={() => open('dashboard')}>{t.shell.home}</button>
          {page !== 'dashboard' && <><span aria-hidden="true">›</span><span aria-current="page">{active.label}</span></>}
          {page === 'dashboard' && <><span aria-hidden="true">›</span><span aria-current="page">{t.shell.costOverview}</span></>}
        </nav>
        {page === 'dashboard' ? children : (
          <div className="az-blade">
            <div className="az-blade-head">
              <span className="az-blade-icon" aria-hidden="true">{ICONS[page]}</span>
              <div>
                <h1>{active.label}</h1>
                <p>{active.subtitle}</p>
              </div>
            </div>
            <p className="az-basis" title={basisDetail}>{basisLabel}</p>
            <div className="az-blade-body">{children}</div>
          </div>
        )}
      </main>

      <footer className="az-statusbar" data-print-hide>
        <span>{t.shell.footer} {basisLabel}</span>
        <span>{aiStatus}</span>
      </footer>
    </div>
  )
}
