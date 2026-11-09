import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { FinOpsApi } from '../api/client'
import { language, locale, t } from '../i18n'

// Display currency — set by the portal's language (deploy.ps1 -Language), not chosen by users:
// English shows USD (Azure's own USD figures), Danish shows DKK.
//
// DKK figures come in two kinds when the tenant is billed in DKK:
//   - stored in BOTH currencies (daily totals, monthly totals, the forecast): shown as billed,
//     no conversion at all;
//   - stored in USD only (per-resource cost, findings, evidence): converted with the ratio
//     Azure itself used, derived from the daily totals (GetFxRates `billing.rate`).
// On any other bill DKK is converted from USD at the ECB reference rate, labelled approximate.
// Without a rate (the API did not answer) the portal stays in USD rather than guess.

export type Currency = string

/** How the selected currency's figures are produced. */
export type CurrencyBasis = 'billing' | 'usd' | 'ecb'

/** The currency each language shows. */
const CURRENCY_OF_LANGUAGE = { en: 'USD', da: 'DKK' } as const

/**
 * A figure as the billing currency actually reports it, straight from Cost Management with no
 * FX conversion applied. Pass it to `money()` alongside the USD value: when its currency is the
 * one on screen it is shown verbatim. Absent (null) for tenants that bill in more than one
 * currency, where a tenant-wide native total would mean adding kroner to euros.
 */
export type NativeAmount = { amount: number; currency: string }

/** Convenience: build the `native` argument, or null when the API didn't supply one. */
export function native(amount?: number | null, currency?: string | null): NativeAmount | null {
  return typeof amount === 'number' && currency ? { amount, currency } : null
}

type CurrencyContextValue = {
  currency: Currency
  /** The tenant's billing currency, when it bills in exactly one. */
  billingCurrency: Currency | null
  /** How figures in the selected currency are produced (for labels). */
  basis: CurrencyBasis
  /** ECB rate date (yyyy-MM-dd) when basis is 'ecb'. */
  ratesAsOf: string | null
  /**
   * Format a USD amount in the selected display currency. Pass `native` when the API supplied
   * the billing-currency figure — it is used verbatim when its currency is the one on screen.
   */
  money: (usd: number, opts?: { compact?: boolean; decimals?: number; native?: NativeAmount | null }) => string
  /** The same conversion as `money`, as a number (for CSV export). */
  convert: (usd: number, nativeAmount?: NativeAmount | null) => number
  /** Convert an amount ENTERED in the display currency back to USD (for filters). */
  toUsd: (displayAmount: number) => number
  /** Currency code of the effective display currency, e.g. "EUR". */
  code: Currency
  /** A few plain words on the basis, for page headers ("Amounts in EUR, as on your invoice."). */
  basisLabel: string
  /** The full explanation of the basis, for tooltips. */
  basisDetail: string
}

const usdFormat = (usd: number) =>
  new Intl.NumberFormat(locale(), { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(usd)

const CurrencyContext = createContext<CurrencyContextValue>({
  currency: 'USD',
  billingCurrency: null,
  basis: 'usd',
  ratesAsOf: null,
  money: (usd) => usdFormat(usd),
  convert: (usd) => usd,
  toUsd: (n) => n,
  code: 'USD',
  basisLabel: 'Amounts in USD.',
  basisDetail: 'Amounts in USD.',
})

export function CurrencyProvider({ children }: { children: ReactNode }) {
  const [rates, setRates] = useState<Record<string, number> | null>(null)
  const [ratesAsOf, setRatesAsOf] = useState<string | null>(null)
  const [billing, setBilling] = useState<{ currency: string; rate: number } | null>(null)

  useEffect(() => {
    FinOpsApi.getFxRates()
      .then((r) => {
        setRates(r.rates)
        setRatesAsOf(r.asOf)
        setBilling(r.billing && r.billing.rate > 0 ? { currency: r.billing.currency, rate: r.billing.rate } : null)
      })
      .catch(() => { setRates(null); setBilling(null) })
  }, [])

  const value = useMemo<CurrencyContextValue>(() => {
    const billingCode = billing?.currency ?? null
    const ecb = (c: string) => (rates && typeof rates[c] === 'number' ? rates[c] : null)
    const wanted: string = CURRENCY_OF_LANGUAGE[language()]
    // Never show converted-looking numbers without a rate.
    const effective = wanted === 'USD' || wanted === billingCode || ecb(wanted) != null ? wanted : 'USD'
    const basis: CurrencyBasis = effective === 'USD' ? 'usd' : effective === billingCode ? 'billing' : 'ecb'
    const rate = basis === 'usd' ? 1 : basis === 'billing' ? billing!.rate : ecb(effective)!

    const convert = (usd: number, nat?: NativeAmount | null) =>
      nat != null && typeof nat.amount === 'number' && nat.currency === effective ? nat.amount : usd * rate

    const money = (
      usd: number,
      opts?: { compact?: boolean; decimals?: number; native?: NativeAmount | null },
    ) =>
      new Intl.NumberFormat(locale(), {
        style: 'currency',
        currency: effective,
        maximumFractionDigits: opts?.decimals ?? (opts?.compact ? 1 : 0),
        ...(opts?.compact ? { notation: 'compact' as const } : {}),
      }).format(convert(usd, opts?.native))

    const basisLabel =
      basis === 'billing' ? t.currency.billingLabel(effective) : basis === 'usd' ? t.currency.usdLabel : t.currency.ecbLabel(effective)
    const basisDetail =
      basis === 'billing' ? t.currency.billingDetail(effective) : basis === 'usd' ? t.currency.usdDetail : t.currency.ecbDetail(effective, ratesAsOf)

    return {
      currency: effective,
      billingCurrency: billingCode,
      basis,
      ratesAsOf: basis === 'ecb' ? ratesAsOf : null,
      money,
      convert,
      toUsd: (displayAmount: number) => (rate ? displayAmount / rate : displayAmount),
      code: effective,
      basisLabel,
      basisDetail,
    }
  }, [rates, ratesAsOf, billing])

  return <CurrencyContext.Provider value={value}>{children}</CurrencyContext.Provider>
}

export function useCurrency(): CurrencyContextValue {
  return useContext(CurrencyContext)
}
