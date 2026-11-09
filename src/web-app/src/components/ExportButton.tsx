import { Button } from '@fluentui/react-components'
import { ArrowDownload16Regular } from '@fluentui/react-icons'
import { downloadCsv, toCsv, type CsvColumn } from '../lib/csv'
import { t } from '../i18n'

type Props<T> = {
  fileBase: string
  rows: T[]
  columns: CsvColumn<T>[]
  label?: string
}

// "Export CSV" for whatever a table currently shows.
export function ExportButton<T>({ fileBase, rows, columns, label = t.common.exportCsv }: Props<T>) {
  return (
    <Button
      size="small"
      appearance="subtle"
      icon={<ArrowDownload16Regular />}
      disabled={rows.length === 0}
      onClick={() => downloadCsv(fileBase, toCsv(rows, columns))}
      title={rows.length ? t.common.exportRows(rows.length) : t.common.nothingToExport}
    >
      {label}
    </Button>
  )
}
