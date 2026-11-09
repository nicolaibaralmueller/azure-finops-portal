import { TableHeaderCell, makeStyles } from '@fluentui/react-components'
import type { CSSProperties, ReactNode } from 'react'

const useStyles = makeStyles({
  cell: { textAlign: 'right', whiteSpace: 'nowrap' },
  // Fluent puts a TableHeaderCell's content inside its `button` slot, which is a full-width
  // flex container (display:flex; width:100%) defaulting to justify-content:flex-start.
  // That wrapper is what positions the label, so `text-align: right` on the cell is inert:
  // the heading stays pinned to the left edge of the column while the figures below it are
  // right-aligned, and the column reads as misaligned. Justify the wrapper instead.
  label: { justifyContent: 'flex-end' },
})

/**
 * Right-aligned table header for a column of numbers. Use this instead of a
 * `<TableHeaderCell className={rightAlignedClass}>` — see the note above for why that
 * doesn't work on its own.
 */
export function NumHeaderCell({ children, style }: { children?: ReactNode; style?: CSSProperties }) {
  const styles = useStyles()
  return (
    <TableHeaderCell className={styles.cell} style={style} button={{ className: styles.label }}>
      {children}
    </TableHeaderCell>
  )
}
