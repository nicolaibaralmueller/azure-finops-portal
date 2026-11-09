import { lazy, Suspense, useEffect, useRef, useState } from 'react'
import {
  Button,
  DrawerBody,
  DrawerHeader,
  DrawerHeaderTitle,
  OverlayDrawer,
  Spinner,
  makeStyles,
  mergeClasses,
  shorthands,
  tokens,
} from '@fluentui/react-components'
import { ChatSparkle20Regular, Dismiss24Regular } from '@fluentui/react-icons'
import { useAsk } from '../lib/ask'
import { t } from '../i18n'

const Query = lazy(() => import('../pages/Query').then((m) => ({ default: m.Query })))

// Ask, on every page: a panel that slides in from the right over whatever the user is looking
// at, so an "Ask about this" answer sits next to the item it is about. Non-modal — the page
// behind stays usable — and kept mounted once opened, so the conversation survives closing it
// and switching pages. Opened by the floating button, Ctrl/⌘+K, the header search box (Azure
// look) and every "Ask about this" button; full screen on a phone.

const useStyles = makeStyles({
  launcher: {
    position: 'fixed',
    right: '20px',
    bottom: '44px',
    zIndex: 1000,
    boxShadow: tokens.shadow16,
    '@media print': { display: 'none' },
  },
  drawer: { width: 'min(560px, 100vw)' },
  // Kept mounted when closed, the drawer is only faded and part-shifted: hide it once the
  // slide-out has played, so it neither covers nor catches clicks on the page's right edge.
  closed: { visibility: 'hidden', pointerEvents: 'none', transitionProperty: 'visibility', transitionDelay: '300ms' },
  body: { display: 'flex', flexDirection: 'column', ...shorthands.padding(0, tokens.spacingHorizontalL, tokens.spacingVerticalL) },
})

export function AskPanel() {
  const styles = useStyles()
  const { panelOpen, setPanelOpen } = useAsk()
  // The Ask box (and its chunk) loads on first open, then stays.
  const [opened, setOpened] = useState(false)
  const body = useRef<HTMLDivElement>(null)

  useEffect(() => { if (panelOpen) setOpened(true) }, [panelOpen])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setPanelOpen(!panelOpen) }
      else if (e.key === 'Escape' && panelOpen) setPanelOpen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [panelOpen, setPanelOpen])

  // Put the cursor in the question box when the panel opens (once the lazy chunk is there).
  useEffect(() => {
    if (!panelOpen) return
    const t = window.setTimeout(() => body.current?.querySelector<HTMLTextAreaElement>('textarea')?.focus(), 250)
    return () => window.clearTimeout(t)
  }, [panelOpen])

  return (
    <>
      {!panelOpen && (
        <Button
          className={styles.launcher}
          appearance="primary"
          shape="circular"
          size="large"
          icon={<ChatSparkle20Regular />}
          onClick={() => setPanelOpen(true)}
          title={t.ask.open}
        >
          {t.ask.button}
        </Button>
      )}
      <OverlayDrawer
        className={mergeClasses(styles.drawer, !panelOpen && styles.closed)}
        position="end"
        modalType="non-modal"
        unmountOnClose={false}
        open={panelOpen}
        // Only Escape closes it from here (also handled above): a click on the page is not a
        // "close" — the panel stays while the user works beside it, and the opening click would
        // otherwise count as one.
        onOpenChange={(_e, d) => { if (!d.open && d.type === 'escapeKeyDown') setPanelOpen(false) }}
        aria-label={t.ask.title}
      >
        <DrawerHeader>
          <DrawerHeaderTitle
            action={<Button appearance="subtle" aria-label={t.common.close} icon={<Dismiss24Regular />} onClick={() => setPanelOpen(false)} />}
          >
            {t.ask.title}
          </DrawerHeaderTitle>
        </DrawerHeader>
        <DrawerBody className={styles.body} ref={body}>
          {opened && (
            <Suspense fallback={<Spinner label={t.common.loading} />}>
              <Query />
            </Suspense>
          )}
        </DrawerBody>
      </OverlayDrawer>
    </>
  )
}
