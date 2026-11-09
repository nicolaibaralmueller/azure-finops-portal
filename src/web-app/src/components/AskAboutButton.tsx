import { Button, Tooltip } from '@fluentui/react-components'
import { ChatSparkle16Regular } from '@fluentui/react-icons'
import type { AskContext } from '../api/client'
import { useAsk } from '../lib/ask'
import { t } from '../i18n'

type Props = {
  question: string
  context: AskContext
  /** Icon-only (for dense tables) or with a label. */
  compact?: boolean
}

// Opens the Ask panel with a question about this item, carrying the item as context so the
// answer (and any follow-up) is scoped to it.
export function AskAboutButton({ question, context, compact }: Props) {
  const { askAbout } = useAsk()
  const onClick = (e: React.MouseEvent) => {
    // Rows that expand on click must not also toggle.
    e.stopPropagation()
    askAbout(question, context)
  }
  if (compact) {
    return (
      <Tooltip content={t.ask.aboutThisTip(question)} relationship="label">
        <Button size="small" appearance="subtle" icon={<ChatSparkle16Regular />} onClick={onClick} />
      </Tooltip>
    )
  }
  return (
    <Button size="small" appearance="subtle" icon={<ChatSparkle16Regular />} onClick={onClick} title={question}>
      {t.ask.aboutThis}
    </Button>
  )
}
