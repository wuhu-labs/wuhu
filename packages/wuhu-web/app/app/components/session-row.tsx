import { Icon, type MenuAction, SidebarRow } from '@wuhu/ui'
import { initialsFrom } from '~/lib/directory'
import { sessionHref } from '~/lib/links'
import { sessionStatus, type SessionSummary } from '~/lib/session-model'
import { Avatar } from './avatar'

type Identity = Pick<SessionSummary, 'id' | 'title' | 'kind'>

// A session's photo, else its initials; a task without a photo keeps the hammer
// so it never reads as an agent one could talk to.
export function SessionMark(
  { session, size, label = session.title }: {
    session: Identity
    size: number
    label?: string
  },
) {
  return (
    <Avatar
      principal={session.id}
      session
      size={size}
      fallback={
        <span className='wui-mark-glyph' aria-hidden='true'>
          {session.kind === 'task'
            ? <Icon name='hammer' />
            : initialsFrom(label)}
        </span>
      }
    />
  )
}

export function SessionRow({
  session,
  label = session.title,
  depth,
  expanded,
  active,
  menu,
  onToggle,
  onNavigate,
}: {
  session: SessionSummary
  label?: string
  depth: number
  expanded?: boolean
  active: boolean
  menu?: MenuAction[]
  onToggle?: () => void
  onNavigate: (to: string) => void
}) {
  const status = sessionStatus(session)
  const href = sessionHref(session.id, session.group)
  return (
    <SidebarRow
      label={label}
      mark={<SessionMark session={session} size={26} label={label} />}
      unread={session.unread}
      status={status == null ? undefined : {
        tone: status.tone === 'neutral' ? 'idle' : status.tone,
        label: status.label,
      }}
      href={href}
      active={active}
      depth={depth}
      expanded={expanded}
      menu={menu}
      onToggle={onToggle}
      onClick={() => onNavigate(href)}
    />
  )
}
