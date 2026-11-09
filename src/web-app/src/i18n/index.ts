import type { Language } from '../api/client'
import { en, type Messages } from './en'
import { da } from './da'

// The portal's language, set once at start-up from config.json (deploy.ps1 -Language) before
// anything renders. `t` is a live binding: import it and read `t.section.key` when rendering —
// never copy a message into a module-level constant, which would keep the language it was read in.
//
//   en.ts  the source of truth: every message, English
//   da.ts  the same keys in Danish, typed as `Messages`, so a missing key fails the build
//
// Messages with values are functions: t.statements.daysRange(26). Dates and numbers are
// formatted with locale(), so they follow the language rather than the browser.

export let t: Messages = en
let current: Language = 'en'

export function setLanguage(language: Language): void {
  current = language
  t = language === 'da' ? da : en
  if (typeof document !== 'undefined') document.documentElement.lang = language
}

export function language(): Language {
  return current
}

/** BCP 47 locale for Intl formatting and sorting. */
export function locale(): string {
  return current === 'da' ? 'da-DK' : 'en-US'
}
