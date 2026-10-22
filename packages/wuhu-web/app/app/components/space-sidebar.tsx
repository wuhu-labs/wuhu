import {
  AgentCard,
  AvatarSlot,
  Count,
  EntityCard,
  Icon,
  type IconName,
  LeadIcon,
  ListCard,
  Row,
} from '@wuhu/ui'
import type { QueryOutput } from '~/lib/contract.gen'
import { initialsFrom } from '~/lib/directory'
import { cardGroups, inCreationOrder, sessionStatusLine } from '~/lib/cards'
import type { ChannelSummary } from '~/lib/channels'
import { sharedGroup } from '~/lib/groups'
import { conversationHref, sessionHref } from '~/lib/links'
import type { SessionRecord, SessionSummary } from '~/lib/session-model'
import {
  everything,
  type RowTarget,
  rowTarget,
  type SidebarFile,
  type SidebarNode,
  sidebarNodes,
  type SidebarSection,
} from '~/lib/sidebars'
import { useObserve } from '~/lib/use-observe'
import { errorMessage } from '~/sdk/errors'
import { sqlSubscription } from '~/sdk/subscriptions'
import { Avatar } from './avatar'

interface Navigation {
  // The address on screen, pathname plus search, to light up its row.
  here: string
  // A custom row passes its title along: the page pill's name for a page
  // with no title of its own.
  onNavigate: (href: string, title?: string) => void
}

// A session's photo, else its initials.
export function SessionAvatar(
  { session, size }: {
    session: Pick<SessionSummary, 'id' | 'title'>
    size: number
  },
) {
  return (
    <AvatarSlot size={size}>
      <Avatar principal={session.id} name={session.title} session size={size} />
    </AvatarSlot>
  )
}

// Everything: one card per top-level agent, its child agents one level down
// (tasks are not listed), and one card of channels when there is any.
export function EverythingSidebar({
  sessions,
  channels,
  here,
  onNavigate,
}: Navigation & {
  sessions: SessionRecord[] | null
  channels: ChannelSummary[] | null
}) {
  const listed = inCreationOrder(
    sessions?.filter((s) => s.lifecycle !== 'archived') ?? [],
  )

  const tops = listed.filter((s) => s.kind === 'agent' && s.parent == null)
  return (
    <>
      {tops.map((agent) => {
        const children = listed.filter((s) =>
          s.kind === 'agent' && s.parent === agent.id
        )
        const href = sessionHref(agent.id, agent.group)
        if (children.length === 0) {
          return (
            <AgentCard
              key={agent.id}
              href={href}
              current={here === href}
              onNavigate={onNavigate}
              lead={<SessionAvatar session={agent} size={34} />}
              name={agent.title}
              status={sessionStatusLine(agent)}
              count={<Count value={agent.unread} />}
            />
          )
        }
        return (
          <EntityCard
            key={agent.id}
            href={href}
            current={here === href}
            onNavigate={onNavigate}
            lead={<SessionAvatar session={agent} size={34} />}
            title={agent.title}
            status={sessionStatusLine(agent)}
            trail={<Count value={agent.unread} />}
          >
            {children.map((child) => {
              const childHref = sessionHref(child.id, child.group)
              return (
                <Row
                  key={child.id}
                  href={childHref}
                  current={here === childHref}
                  onNavigate={onNavigate}
                  lead={<SessionAvatar session={child} size={26} />}
                  label={child.title}
                  status={sessionStatusLine(child)}
                  trail={<Count value={child.unread} tone='grey' />}
                />
              )
            })}
          </EntityCard>
        )
      })}
      {channels != null && channels.length > 0 && (
        <ListCard title='Channels'>
          {channels.map((channel) => {
            const href = conversationHref(channel.id, sharedGroup)
            return (
              <Row
                key={channel.id}
                href={href}
                current={here === href}
                onNavigate={onNavigate}
                lead={
                  <LeadIcon>
                    <Icon name='bubble' w={16} h={16} />
                  </LeadIcon>
                }
                label={channel.title}
                trail={<Count value={channel.unread} />}
              />
            )
          })}
        </ListCard>
      )}
    </>
  )
}

// A custom sidebar: the first section's top-level rows each their own card
// with one level of children; every later section one titled card of its
// top-level rows.
export function CustomSidebar({
  file,
  group,
  sessions,
  here,
  onNavigate,
}: Navigation & {
  file: SidebarFile
  group: string
  sessions: SessionRecord[] | null
}) {
  if ('failure' in file) {
    return (
      <ListCard title={file.title}>
        <p className='wuhu-alert'>{file.failure}</p>
      </ListCard>
    )
  }
  return file.sections.map((section, index) => (
    <CustomSection
      key={section.id}
      section={section}
      first={index === 0}
      group={group}
      sessions={sessions}
      here={here}
      onNavigate={onNavigate}
    />
  ))
}

interface Resolved {
  node: SidebarNode
  target: RowTarget
  session: SessionRecord | null
}

function CustomSection({
  section,
  first,
  group,
  sessions,
  here,
  onNavigate,
}: Navigation & {
  section: SidebarSection
  first: boolean
  group: string
  sessions: SessionRecord[] | null
}) {
  const observed = useObserve<QueryOutput | null, QueryOutput>(
    sqlSubscription(section.sql, group),
    (_, output) => output,
    null,
  )
  let nodes: SidebarNode[] = []
  let failure: string | null = null
  if (observed.data != null) {
    try {
      nodes = sidebarNodes(observed.data)
    } catch (refusal) {
      failure = errorMessage(refusal)
    }
  }
  const firstAgent =
    sessions?.find((session) =>
      session.group === group && session.kind === 'agent' &&
      session.lifecycle !== 'archived'
    )?.id ?? null
  const resolved = nodes.flatMap((node): Resolved[] => {
    const target = rowTarget(node.destination, firstAgent, group)
    if (target == null) return []
    const session = target.kind === 'session'
      ? sessions?.find((record) => record.id === target.id) ?? null
      : null
    return [{ node, target, session }]
  })
  const groups = cardGroups(
    resolved.map((row) => ({
      ...row,
      id: row.node.id,
      parent: row.node.parent,
    })),
  )
  const row = (item: Resolved, size: number) => ({
    href: item.target.href,
    current: here === item.target.href,
    onNavigate: (href: string) => onNavigate(href, item.node.title),
    lead: rowLead(item, size),
    status: item.session && sessionStatusLine(item.session),
  })

  if (failure != null) {
    return (
      <ListCard title={section.title}>
        <p className='wuhu-alert'>{failure}</p>
      </ListCard>
    )
  }
  if (!first) {
    if (groups.length === 0) return null
    return (
      <ListCard title={section.title}>
        {groups.map(({ item }) => (
          <Row
            key={item.node.id}
            {...row(item, 32)}
            label={item.node.title}
            trail={<Count value={badgeOf(item)} />}
          />
        ))}
      </ListCard>
    )
  }
  return groups.map(({ item, children }) =>
    children.length === 0
      ? (
        <AgentCard
          key={item.node.id}
          {...row(item, 34)}
          name={item.node.title}
          count={<Count value={badgeOf(item)} />}
        />
      )
      : (
        <EntityCard
          key={item.node.id}
          {...row(item, 34)}
          title={item.node.title}
          trail={<Count value={badgeOf(item)} />}
        >
          {children.map((child) => (
            <Row
              key={child.node.id}
              {...row(child, 26)}
              label={child.node.title}
              trail={<Count value={badgeOf(child)} />}
            />
          ))}
        </EntityCard>
      )
  )
}

// The row's own badge, else, for a row naming a session's box, its unread;
// `chat` shows the agent it opens, not that agent's mail.
function badgeOf({ node, session }: Resolved): number {
  if (node.badge != null) return Math.max(0, node.badge)
  return session != null && node.destination !== 'chat' ? session.unread : 0
}

function rowLead({ node, target, session }: Resolved, size: number) {
  if (session != null) return <SessionAvatar session={session} size={size} />
  if (target.kind === 'session') {
    return (
      <SessionAvatar
        session={{ id: target.id, title: node.title }}
        size={size}
      />
    )
  }
  const glyph = documentGlyph(target)
  return (
    <LeadIcon>
      {glyph === 'doc'
        ? <Icon name='doc' w={13} h={16} />
        : <Icon name={glyph} w={16} h={16} />}
    </LeadIcon>
  )
}

// One glyph for HTML pages, one for Markdown documents.
function documentGlyph(target: RowTarget): IconName {
  if (target.kind === 'conversation') return 'bubble'
  return /\.html?($|[?#])/.test(target.href) ? 'grid' : 'doc'
}

// The SF Symbol a definition names, drawn with the design's nearest glyph.
const symbolGlyphs: Record<string, IconName> = {
  hammer: 'hammer',
  book: 'book',
  'book.closed': 'book',
  pencil: 'pencil',
  clock: 'clock',
  sparkles: 'sparkles',
  folder: 'folder',
  doc: 'doc',
  'doc.text': 'doc',
  bubble: 'bubble',
  'bubble.left': 'bubble',
  message: 'bubble',
  gear: 'gear',
  gearshape: 'gear',
  'square.grid.2x2': 'grid',
  'chart.xyaxis.line': 'graph',
}

// The rail: Everything, then one button per sidebar file.
export function SidebarRail({
  files,
  current,
  onPick,
}: {
  files: SidebarFile[] | null
  current: string
  onPick: (sidebar: string) => void
}) {
  return (
    <>
      <button
        type='button'
        title='Everything'
        aria-label='Everything'
        aria-pressed={current === everything}
        onClick={() => onPick(everything)}
      >
        <Icon name='bubble' w={18} h={18} />
      </button>
      {files?.map((file) => {
        const glyph = file.icon == null ? undefined : symbolGlyphs[file.icon]
        return (
          <button
            key={file.path}
            type='button'
            title={file.title}
            aria-label={file.title}
            aria-pressed={current === file.path}
            onClick={() => onPick(file.path)}
          >
            {glyph ? <Icon name={glyph} w={18} h={18} /> : initialsFrom(
              file.title,
            ).slice(0, 1)}
          </button>
        )
      })}
    </>
  )
}
