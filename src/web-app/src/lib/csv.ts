// CSV export, generated in the browser from what the page already has — no extra API call, and
// the file contains exactly the rows on screen (filters applied).
//
// Numbers are written as plain numbers (dot decimal, no grouping, no currency symbol) so a
// spreadsheet reads them as numbers in any locale; the currency is its own column. A UTF-8 BOM
// makes Excel open non-ASCII names (æøå) correctly.

export type CsvColumn<T> = { header: string; value: (row: T) => string | number | boolean | null | undefined }

function cell(v: string | number | boolean | null | undefined): string {
  if (v === null || v === undefined) return ''
  if (typeof v === 'number') return Number.isFinite(v) ? String(Math.round(v * 100) / 100) : ''
  const s = String(v)
  // Quote anything that could split a cell or be read as a formula by a spreadsheet.
  const guarded = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s
  return /[",\r\n;]/.test(guarded) || guarded !== s ? `"${guarded.replace(/"/g, '""')}"` : guarded
}

export function toCsv<T>(rows: T[], columns: CsvColumn<T>[]): string {
  const lines = [columns.map((c) => cell(c.header)).join(',')]
  for (const r of rows) lines.push(columns.map((c) => cell(c.value(r))).join(','))
  return lines.join('\r\n')
}

export function downloadCsv(fileBase: string, csv: string): void {
  const date = new Date().toISOString().slice(0, 10)
  const blob = new Blob(['﻿', csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `${fileBase}-${date}.csv`
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
