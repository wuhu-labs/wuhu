import { useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { useChrome } from '@wuhu/ui'
import { ShellComposer } from '~/components/shell-composer'
import { sessionTone } from '~/components/space-sidebar'
import {
  composerAim,
  type ComposeTarget,
  dockAfter,
  targetKey,
} from '~/lib/composer-target'
import { placeGroup, sessionHref } from '~/lib/links'
import { sessionCapability } from '~/lib/session-capability'
import { useSpaceFeeds } from '~/lib/space-feeds'
import { useDictationOffered } from '~/lib/use-dictation'
import { useDrafts } from '~/lib/use-drafts'
import { postConversationMessage } from '~/sdk/conversation'

// On its own page the composer posts there. Elsewhere on desktop it stays
// docked on the last agent box opened, named by a pill, and never on a task.
export function SpaceComposer({ page }: { page: ComposeTarget | null }) {
  const drafts = useDrafts()
  const { compact } = useChrome()
  const { sessions } = useSpaceFeeds()
  const navigate = useNavigate()
  const group = placeGroup(useLocation().search)
  const dictate = useDictationOffered()
  const [dock, setDock] = useState<string | null>(null)
  const pageKey = page && targetKey(page)
  useEffect(() => {
    setDock((current) => dockAfter(current, page))
  }, [pageKey])

  const docked = sessions?.find((record) => record.id === dock) ?? null
  const aim = composerAim({
    page,
    dock,
    dockCapability: sessionCapability(docked),
    compact,
  })
  if (drafts === null || aim === null) return null
  const key = targetKey(aim.target)
  const { target } = aim
  return (
    <ShellComposer
      key={key}
      drafts={drafts}
      draftKey={key}
      pill={aim.docked
        ? {
          label: docked!.title,
          dot: sessionTone(docked!),
          href: sessionHref(docked!.id, docked!.group),
          onNavigate: () =>
            void navigate(sessionHref(docked!.id, docked!.group)),
        }
        : undefined}
      placeholder={target.kind === 'conversation'
        ? 'Message…'
        : aim.docked
        ? `Post into ${docked!.title}’s box…`
        : 'Post into the box…'}
      dictate={dictate}
      onSend={(draft) =>
        postConversationMessage(
          target.kind === 'conversation'
            ? { conversation: target.id }
            : { session: target.id },
          aim.docked ? docked!.group : group,
          draft.text,
          draft.reply?.messageId,
          draft.files.map((held) => held.file),
        )}
    />
  )
}
