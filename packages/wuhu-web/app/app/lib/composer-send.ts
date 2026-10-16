import type { ComposeTarget } from './composer-target.ts'
import type { Draft } from './drafts.ts'
import { postConversationMessage } from '../sdk/conversation.ts'

// A composer's Send: the draft into its target's box, posted from `group`,
// naming `viewing` (lib/viewing.ts) as the page on screen, or none.
export function composerSend({ target, group, viewing }: {
  target: ComposeTarget
  group: string
  viewing: string | null
}): (draft: Draft) => Promise<unknown> {
  return (draft) =>
    postConversationMessage(
      target.kind === 'conversation'
        ? { conversation: target.id }
        : { session: target.id },
      group,
      draft.text,
      draft.reply?.messageId,
      draft.files.map((held) => held.file),
      viewing,
    )
}
