import {
  AgentCard,
  CatalogCard,
  CatalogError,
  type CatalogLinks,
  Count,
  EntityCard,
  Glyph,
  LeadIcon,
  ListCard,
  Row,
  type Status,
} from '@wuhu/ui'
import type { ReactNode } from 'react'
import type { ChannelSummary } from '~/lib/channels'
import type { QueryOutput } from '~/lib/contract.gen'
import { sessionStatusLine } from '~/lib/cards'
import { fileName, groupAddress, sessionHref } from '~/lib/links'
import type { SessionRecord } from '~/lib/session-model'
import { type RowTarget, rowTarget, validDestination } from '~/lib/sidebars'
import { spaceDestination } from '~/lib/space-url'
import { useObserve } from '~/lib/use-observe'
import {
  type PageCardSpec,
  type PageEntry,
  type SidebarItem,
  type SidebarTree,
  sidebarTree,
  type WidgetSize,
  widgetTree,
} from '~/lib/widgets/tree'
import { type ScriptState, useScript } from '~/lib/widgets/use-script'
import type { SpaceClient } from '~/sdk/client'
import { sqlSubscription } from '~/sdk/subscriptions'
import { SessionAvatar } from './space-sidebar'
import { WidgetBoundary } from './widget-boundary'

// Where a page address leads, or null when it names nowhere a row can open.
// A document's path and a conversation's id come along.
export function pageTarget(
  address: string,
  firstAgent: string | null,
  group: string,
): (RowTarget & { path?: string; id?: string }) | null {
  if (!validDestination(address)) return null
  const target = rowTarget(address, firstAgent, group)
  if (target == null) return null
  const destination = address === 'chat'
    ? null
    : spaceDestination(groupAddress(address, group).path)
  if (destination?.kind === 'path') return { ...target, path: destination.path }
  if (destination?.kind === 'conversation') {
    return { ...target, id: destination.id }
  }
  return target
}

interface Navigation {
  here: string
  onNavigate: (href: string, title?: string) => void
}

interface Context extends Navigation {
  client: SpaceClient
  sessions: SessionRecord[] | null
  channels: ChannelSummary[] | null
  docTitles: ReadonlyMap<string, string>
  firstAgent: string | null
  // Whether the sidebar is on screen: a fetch's `every` waits until it is.
  active: boolean
}

// A script's output as a sidebar, or the one sentence for its error card.
export function scriptSidebar(
  path: string,
  state: ScriptState | undefined,
): SidebarTree | string | null {
  if (state == null || state.kind === 'loading') return null
  if (state.kind === 'failed') return state.message
  if (!state.result.ok) return state.result.message
  try {
    return sidebarTree(state.result.value)
  } catch (refusal) {
    return `${path}: ${(refusal as Error).message}`
  }
}

// A sidebar script's content: its PageCards and widgets in order, each run
// of small widgets two to a row.
export function ScriptSidebar(
  props: Navigation & {
    path: string
    state: ScriptState | undefined
    client: SpaceClient
    sessions: SessionRecord[] | null
    channels: ChannelSummary[] | null
    active: boolean
  },
) {
  const tree = scriptSidebar(props.path, props.state)
  const group = props.client.group
  const docPaths = typeof tree === 'object' && tree != null
    ? [
      ...new Set(
        tree.items.flatMap((item) =>
          item.kind === 'page' ? [item.card, ...item.card.children] : []
        ).flatMap((entry) => {
          const path = entry.page == null
            ? undefined
            : pageTarget(entry.page, null, group)?.path
          return path == null ? [] : [path]
        }),
      ),
    ].sort()
    : []
  const docTitles = useObserve<ReadonlyMap<string, string>, QueryOutput>(
    docPaths.length === 0 ? null : sqlSubscription(
      `SELECT docs.path, COALESCE((SELECT json_extract(value, '$')
          FROM doc_custom_attrs AS attrs
          WHERE attrs.path = docs.path AND attrs.name = 'title'
          ORDER BY ord LIMIT 1), docs.title)
        FROM docs WHERE docs.path IN (${docPaths.map(() => '?').join(', ')})`,
      group,
      docPaths,
    ),
    (_, output) =>
      new Map(
        output.rows.flatMap(([path, title]) =>
          typeof path === 'string' && typeof title === 'string' &&
            title.trim() !== ''
            ? [[path, title] as const]
            : []
        ),
      ),
    new Map(),
  ).data
  if (tree == null) return null
  if (typeof tree === 'string') return <CatalogError message={tree} />
  const context: Context = {
    ...props,
    docTitles,
    firstAgent:
      props.sessions?.find((session) =>
        session.group === group && session.kind === 'agent' &&
        session.lifecycle !== 'archived'
      )?.id ?? null,
  }
  return placements(tree.items).map((placement, index) =>
    placement.length === 2 || placement[0]!.kind === 'widget' &&
        placement[0]!.size === 'small'
      ? (
        <div key={index} className='wui-widget-pair'>
          {placement.map((item, at) => (
            <Item key={at} item={item} context={context} />
          ))}
        </div>
      )
      : <Item key={index} item={placement[0]!} context={context} />
  )
}

// Consecutive small widgets pair up; a lone small one keeps its half.
function placements(items: SidebarItem[]): SidebarItem[][] {
  const rows: SidebarItem[][] = []
  for (const item of items) {
    const last = rows.at(-1)
    const small = item.kind === 'widget' && item.size === 'small'
    if (
      small && last?.length === 1 && last[0]!.kind === 'widget' &&
      last[0]!.size === 'small'
    ) {
      last.push(item)
    } else {
      rows.push([item])
    }
  }
  return rows
}

function Item({ item, context }: { item: SidebarItem; context: Context }) {
  return item.kind === 'page'
    ? <PageCard card={item.card} context={context} />
    : <WidgetSlot src={item.src} size={item.size} context={context} />
}

interface Resolved {
  href: string | null
  title: string
  status: Status | null
  caption: string | null
  badge: number
  lead: (size: number) => ReactNode
}

// What a page names, with the fields the card leaves out filled from it.
function resolve(entry: PageEntry, context: Context): Resolved {
  const group = context.client.group
  const target = entry.page == null
    ? null
    : pageTarget(entry.page, context.firstAgent, group)
  const given = {
    caption: entry.status ?? null,
    badge: entry.badge ?? null,
    avatar: entry.avatar == null ? null : (size: number) => (
      <img
        className='wuhu-avatar'
        src={entry.avatar}
        alt=''
        style={{ width: size, height: size, borderRadius: '50%' }}
      />
    ),
  }
  if (target?.kind === 'session') {
    const record = context.sessions?.find((session) => session.id === target.id)
    const title = entry.title ?? record?.title ?? target.id
    return {
      href: record == null ? target.href : sessionHref(record.id, record.group),
      title,
      status: given.caption == null && record != null
        ? sessionStatusLine(record)
        : null,
      caption: given.caption,
      badge: given.badge ?? record?.unread ?? 0,
      lead: given.avatar ??
        ((size) => (
          <SessionAvatar session={{ id: target.id, title }} size={size} />
        )),
    }
  }
  if (target?.kind === 'conversation') {
    const channel = context.channels?.find((found) => found.id === target.id)
    return {
      href: target.href,
      title: entry.title ?? channel?.title ?? 'Channel',
      status: null,
      caption: given.caption,
      badge: given.badge ?? channel?.unread ?? 0,
      lead: given.avatar ?? (() => (
        <LeadIcon>
          <Glyph name='bubble' w={16} h={16} />
        </LeadIcon>
      )),
    }
  }
  const path = target?.path ?? null
  const html = path != null && /\.html?$/i.test(path)
  return {
    href: target?.href ?? null,
    title: entry.title ??
      (path == null ? '' : context.docTitles.get(path) ?? fileName(path)),
    status: null,
    caption: given.caption,
    badge: given.badge ?? 0,
    lead: given.avatar ?? (() => (
      <LeadIcon>
        {html
          ? <Glyph name='grid' w={16} h={16} />
          : <Glyph name='doc' w={13} h={16} />}
      </LeadIcon>
    )),
  }
}

// A bare card is one link; with children its head and each row link on
// their own; without a page it is a titled card of its rows.
function PageCard(
  { card, context }: { card: PageCardSpec; context: Context },
) {
  const head = resolve(card, context)
  const link = (resolved: Resolved) =>
    resolved.href == null ? {} : {
      href: resolved.href,
      current: context.here === resolved.href,
      onNavigate: (href: string) => context.onNavigate(href, resolved.title),
    }
  const rows = card.children.map((entry) => resolve(entry, context))
  if (card.page == null) {
    return (
      <ListCard title={head.title}>
        {rows.map((row, at) => (
          <Row
            key={at}
            {...link(row)}
            lead={row.lead(32)}
            label={row.title}
            status={row.status}
            caption={row.caption}
            trail={<Count value={row.badge} />}
          />
        ))}
      </ListCard>
    )
  }
  if (rows.length === 0) {
    return (
      <AgentCard
        {...link(head)}
        lead={head.lead(34)}
        name={head.title}
        status={head.status}
        caption={head.caption}
        count={<Count value={head.badge} />}
      />
    )
  }
  return (
    <EntityCard
      {...link(head)}
      lead={head.lead(34)}
      title={head.title}
      status={head.status}
      caption={head.caption}
      trail={<Count value={head.badge} />}
    >
      {rows.map((row, at) => (
        <Row
          key={at}
          {...link(row)}
          lead={row.lead(26)}
          label={row.title}
          status={row.status}
          caption={row.caption}
          trail={<Count value={row.badge} tone='grey' />}
        />
      ))}
    </EntityCard>
  )
}

function WidgetSlot(
  { src, size, context }: { src: string; size: WidgetSize; context: Context },
) {
  const state = useScript(context.client, src, { size }, context.active)
  if (state.kind === 'loading') {
    return <div className={`wui-widget-loading ${size}`} aria-busy='true' />
  }
  if (state.kind === 'failed') return <CatalogError message={state.message} />
  if (!state.result.ok) return <CatalogError message={state.result.message} />
  let element
  try {
    element = widgetTree(state.result.value, state.result.sizes, size)
  } catch (refusal) {
    return <CatalogError message={`${src}: ${(refusal as Error).message}`} />
  }
  const links: CatalogLinks = {
    href: (to) =>
      pageTarget(to, context.firstAgent, context.client.group)?.href ?? null,
    navigate: (href) => context.onNavigate(href),
  }
  return (
    <WidgetBoundary key={JSON.stringify(element)} src={src}>
      <CatalogCard element={element} size={size} links={links} />
    </WidgetBoundary>
  )
}
