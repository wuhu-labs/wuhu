import {
  AgentCard,
  AvatarSlot,
  Count,
  EntityCard,
  Glyph,
  type GlyphName,
  Icon,
  LeadIcon,
  ListCard,
  Row,
} from '@wuhu/ui'
import type { ReactNode } from 'react'
import type { QueryOutput } from '~/lib/contract.gen'
import { initialsFrom } from '~/lib/directory'
import { cardGroups, sessionStatusLine } from '~/lib/cards'
import type { SessionRecord, SessionSummary } from '~/lib/session-model'
import {
  type DefinitionFile,
  type RowTarget,
  rowTarget,
  type SidebarNode,
  sidebarNodes,
  type SidebarSection,
} from '~/lib/sidebars'
import { useObserve } from '~/lib/use-observe'
import type { ScriptState } from '~/lib/widgets/use-script'
import { knownIcon } from '~/lib/widgets/tree'
import { errorMessage } from '~/sdk/errors'
import { sqlSubscription } from '~/sdk/subscriptions'
import { Avatar } from './avatar'
import { scriptSidebar } from './script-sidebar'
import { type CatalogSidebar, sidebarKey } from '~/lib/sidebar-catalog'

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
  file: DefinitionFile
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
        ? <Glyph name='doc' w={13} h={16} />
        : <Glyph name={glyph} w={16} h={16} />}
    </LeadIcon>
  )
}

// One glyph for HTML pages, one for Markdown documents.
function documentGlyph(target: RowTarget): GlyphName {
  if (target.kind === 'conversation') return 'bubble'
  return /\.html?($|[?#])/.test(target.href) ? 'grid' : 'doc'
}

// The SF Symbol a definition names, drawn with the design's nearest glyph.
const symbolGlyphs: Record<string, GlyphName> = {
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

// The rail: one button per sidebar file, Everything first. A script's name
// and icon come from its last run.
export function SidebarRail({
  files,
  scripts,
  current,
  onPick,
}: {
  files: CatalogSidebar[] | null
  scripts: ReadonlyMap<string, ScriptState>
  current: string
  onPick: (sidebar: CatalogSidebar) => void
}) {
  return files?.map((file) => {
    const id = sidebarKey({ group: file.group.id, path: file.path })
    const title = file.title
    let glyph: ReactNode = null
    if ('script' in file) {
      const tree = scriptSidebar(file.path, scripts.get(id))
      if (typeof tree === 'object' && tree != null) {
        if (tree.icon != null && knownIcon(tree.icon)) {
          glyph = <Icon name={tree.icon} size={20} />
        }
      }
    } else {
      const symbol = file.icon == null ? undefined : symbolGlyphs[file.icon]
      if (symbol) glyph = <Glyph name={symbol} w={18} h={18} />
    }
    return (
      <button
        key={id}
        type='button'
        title={title}
        aria-label={title}
        aria-pressed={current === id}
        onClick={() => onPick(file)}
      >
        {glyph ?? initialsFrom(title).slice(0, 1)}
      </button>
    )
  })
}
