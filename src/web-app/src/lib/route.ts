import { useCallback, useEffect, useMemo, useState } from 'react'
import type { PageKey } from './ask'

// Hash routing, no dependency: `#/savings?subs=abc&sort=est-asc`.
//
// Hash rather than path routes because the portal is served as static files behind EasyAuth:
// a path like /savings would need every host to rewrite unknown paths to index.html, and a
// hash never reaches the server at all. Every page, and the period and filters on it, is in
// the URL, so a view can be bookmarked and sent to someone as a link.
//
// Filter changes REPLACE the current history entry (a filter is not a navigation step — Back
// should leave the page, not undo one checkbox); page changes push a new one.

const SLUGS: Record<PageKey, string> = {
  dashboard: 'overview',
  statements: 'statements',
  spikes: 'changes',
  savings: 'savings',
  reservations: 'reservations',
}
// Links to the pages folded into the Overview (Ask, Explore, Subscriptions) still open it.
const BY_SLUG: Record<string, PageKey> = {
  ...Object.fromEntries(Object.entries(SLUGS).map(([k, v]) => [v, k as PageKey])),
  ask: 'dashboard',
  explore: 'dashboard',
  subscriptions: 'dashboard',
}

export type Route = { page: PageKey; params: URLSearchParams }

export function parseHash(hash: string): Route {
  const raw = hash.replace(/^#\/?/, '')
  const [slug, query = ''] = raw.split('?')
  return { page: BY_SLUG[slug] ?? 'dashboard', params: new URLSearchParams(query) }
}

export function buildHash(page: PageKey, params?: URLSearchParams | null): string {
  const q = params && [...params.keys()].length ? `?${params.toString()}` : ''
  return `#/${SLUGS[page]}${q}`
}

const EVENT = 'finops-route'

function currentRoute(): Route {
  return parseHash(typeof window === 'undefined' ? '' : window.location.hash)
}

/** The current route; re-renders on back/forward and on in-app navigation. */
export function useRoute(): [Route, (page: PageKey) => void] {
  const [route, setRoute] = useState<Route>(currentRoute)
  useEffect(() => {
    const onChange = () => setRoute(currentRoute())
    window.addEventListener('hashchange', onChange)
    window.addEventListener(EVENT, onChange)
    return () => {
      window.removeEventListener('hashchange', onChange)
      window.removeEventListener(EVENT, onChange)
    }
  }, [])
  const navigate = useCallback((page: PageKey) => {
    // A new page starts with clean filters.
    const target = buildHash(page)
    if (window.location.hash !== target) window.location.hash = target
  }, [])
  return [route, navigate]
}

function writeParam(key: string, value: string | null) {
  const { page, params } = currentRoute()
  if (value === null || value === '') params.delete(key)
  else params.set(key, value)
  const next = buildHash(page, params)
  if (window.location.hash === next) return
  window.history.replaceState(null, '', next)
  window.dispatchEvent(new Event(EVENT))
}

/**
 * One URL query value as React state. `fallback` is used when the parameter is absent, and
 * setting the value back to the fallback removes it, so default views keep clean URLs.
 */
export function useHashParam(key: string, fallback: string): [string, (v: string) => void] {
  const read = () => currentRoute().params.get(key) ?? fallback
  const [value, setValue] = useState<string>(read)
  useEffect(() => {
    const onChange = () => setValue(read())
    window.addEventListener('hashchange', onChange)
    window.addEventListener(EVENT, onChange)
    return () => {
      window.removeEventListener('hashchange', onChange)
      window.removeEventListener(EVENT, onChange)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, fallback])
  const set = useCallback((v: string) => {
    setValue(v)
    writeParam(key, v === fallback ? null : v)
  }, [key, fallback])
  return [value, set]
}

/** A comma-separated list parameter (multiselect filters). */
export function useHashListParam(key: string): [string[], (v: string[]) => void] {
  const [raw, setRaw] = useHashParam(key, '')
  // Stable identity per value, so a list used as a memo dependency doesn't change every render.
  const list = useMemo(() => (raw ? raw.split(',').filter(Boolean) : []), [raw])
  const set = useCallback((v: string[]) => setRaw(v.join(',')), [setRaw])
  return [list, set]
}
