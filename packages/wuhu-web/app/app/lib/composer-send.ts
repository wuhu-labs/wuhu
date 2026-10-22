import type { ComposeTarget } from './composer-target.ts'
import { postConversationMessage } from '../sdk/conversation.ts'

// A composer's Send: the text into its target's box, posted from `group`,
// naming `viewing` (lib/viewing.ts) as the page on screen, or none.
export function composerSend({ target, group, viewing }: {
  target: ComposeTarget
  group: string
  viewing: string | null
}): (text: string) => Promise<unknown> {
  return (text) =>
    postConversationMessage(
      target.kind === 'conversation'
        ? { conversation: target.id }
        : { session: target.id },
      group,
      text,
      viewing,
    )
}
