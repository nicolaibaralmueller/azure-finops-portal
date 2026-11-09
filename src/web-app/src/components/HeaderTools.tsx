import { useState } from 'react'
import { Button, Tooltip, Popover, PopoverTrigger, PopoverSurface } from '@fluentui/react-components'
import { SignOut20Regular } from '@fluentui/react-icons'
import { LOGOUT_URL, type SubscriptionScope } from '../api/client'
import { locale, t } from '../i18n'

// The controls every theme shows in its header: the subscription scope and the signed-in user.
// (The display currency follows the portal's language; there is no picker.) Themes place and style them (classes fo-scope*, fo-tools, fo-user); the
// behaviour lives here once.

// The subscriptions the portal covers: a click opens a readable list, scrollable when long, with
// a filter once there are more than a dozen.
function ScopeList({ scope }: { scope: SubscriptionScope }) {
  const [filter, setFilter] = useState('')
  const count = scope.included.length
  const label = scope.total != null && scope.total >= count ? t.header.subscriptionsOf(count, scope.total) : t.header.subscriptions(count)
  const rows = [...scope.included]
    .sort((a, b) => a.name.localeCompare(b.name, locale(), { numeric: true, sensitivity: 'base' }))
    .filter((s) => !filter || `${s.name} ${s.id}`.toLowerCase().includes(filter.toLowerCase()))
  return (
    <Popover positioning="below-end" withArrow onOpenChange={(_e, d) => { if (!d.open) setFilter('') }}>
      <PopoverTrigger disableButtonEnhancement>
        <button type="button" className="fo-scope fo-scope-btn" aria-haspopup="dialog">{label}</button>
      </PopoverTrigger>
      <PopoverSurface aria-label={t.header.inPortal} className="fo-scope-pop">
        <div className="fo-scope-head">
          <b>{t.header.inPortal}</b>
          <span>{count}</span>
        </div>
        {count > 12 && (
          <input
            className="fo-scope-filter"
            type="search"
            placeholder={t.header.filterPlaceholder}
            aria-label={t.header.filterLabel}
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            autoFocus
          />
        )}
        <ul className="fo-scope-list">
          {rows.map((s) => (
            <li key={s.id}>
              <span className="fo-scope-name">{s.name}</span>
              <span className="fo-scope-id">{s.id}</span>
            </li>
          ))}
          {!rows.length && <li className="fo-scope-none">{t.header.noMatch}</li>}
        </ul>
        {scope.pending && <p className="fo-scope-note">{t.header.scopePending}</p>}
        <p className="fo-scope-note">{t.header.scopeHow}</p>
      </PopoverSurface>
    </Popover>
  )
}

export function HeaderTools({ scope, userName }: { scope: SubscriptionScope | null; userName: string | null }) {
  return (
    <div className="fo-tools">
      {scope && !scope.all && <ScopeList scope={scope} />}
      {userName && <span className="fo-user">{userName}</span>}
      {userName && (
        <Tooltip content={t.common.signOut} relationship="label">
          <Button className="fo-tool-btn" appearance="subtle" icon={<SignOut20Regular />} onClick={() => { window.location.href = LOGOUT_URL }} />
        </Tooltip>
      )}
    </div>
  )
}
