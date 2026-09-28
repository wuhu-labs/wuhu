import {
  type DotTone,
  Picker,
  Pill,
  PrimaryAction,
  Sidebar,
  SidebarActions,
  SidebarFooter,
  SidebarHeader,
  SidebarNote,
  SidebarRow,
  SidebarScroll,
  SidebarSection,
  useChrome,
} from '@wuhu/ui'
import { useEffect, useState } from 'react'
import type { SessionRecord, SessionSummary } from '~/lib/session-model'
import { errorMessage } from '~/sdk/errors'
import type { SessionAddress } from '~/sdk/session'
import { displayNameFor, handleFor } from '~/lib/directory'
import { screens, sessionHref, withGroup } from '~/lib/links'
import { ancestors, flatten, nest, stableOrder } from '~/lib/outline'
import { groupLabel, memberGroups, memberOr } from '~/lib/groups'
import {
  everything,
  sameView,
  sidebarName,
  sidebarPaths,
  type SidebarView,
} from '~/lib/sidebars'
import { useSpaceFeeds } from '~/lib/space-feeds'
import { spaceDestination } from '~/lib/space-url'
import { buildTree } from '~/lib/tree'
import { useDirectory, useOwnPrincipal } from '~/lib/use-directory'
import { Avatar } from './avatar'
import { CustomSidebar } from './custom-sidebar'
import { SessionRow } from './session-row'
import { SpaceTree } from './space-tree'
import { WebPushControl } from './web-push-control'

// A session's state as one colour, for the composer's target chip.
export function sessionTone(
  session: Pick<SessionSummary, 'lifecycle' | 'hold' | 'work'>,
): DotTone {
  if (session.lifecycle === 'archived') return 'idle'
  if (session.hold === 'errored' || session.work === 'errored') return 'rose'
  if (session.work === 'has_work' || session.work === 'working') return 'amber'
  if (session.hold === 'released') return 'idle'
  return 'mint'
}

function viewKey(view: SidebarView): string {
  return `${view.group}\n${view.sidebar}`
}

export function SpaceSidebar({
  account,
  activePath,
  expanded,
  onArchiveSession,
  onNavigate: navigateTo,
  onNewDocument,
  onNewSession,
  onSelectView,
  onToggle,
  pathname,
  placeGroup,
  space,
  view,
}: {
  account: { initials: string; name: string; detail?: string }
  activePath: string | null
  expanded: ReadonlySet<string>
  onArchiveSession: (session: SessionAddress) => Promise<void>
  onNavigate: (to: string) => void
  onNewDocument: (directory: string, group: string) => void
  onNewSession: () => void
  onSelectView: (view: SidebarView) => void
  onToggle: (path: string) => void
  pathname: string
  placeGroup: string
  // The host names the space, as native's sidebar does.
  space: string
  view: SidebarView
}) {
  const { compact, setMode } = useChrome()
  const feeds = useSpaceFeeds()
  const members = feeds.groups == null ? [] : memberGroups(feeds.groups)
  const directory = useDirectory()
  const principal = useOwnPrincipal()
  const [archiveError, setArchiveError] = useState<string | null>(null)
  // Disclosure is per view: Everything opens nothing until asked, a custom
  // sidebar opens every branch until asked, so one toggle set serves both.
  const [toggled, setToggled] = useState<Record<string, ReadonlySet<string>>>(
    {},
  )
  // Compact chrome shows the sidebar over the canvas, so following a link there
  // has to dismiss it or the destination stays covered.
  const onNavigate = (to: string) => {
    if (compact) setMode('focus')
    navigateTo(to)
  }

  // A chosen view whose group or file left shows Everything without losing
  // the choice, so either coming back brings the view back.
  const group = memberOr(view.group, feeds.groups == null ? null : members)
  const { error, files, loaded, sessions, sidebars } = feeds.feed(
    group,
  )
  const shown: SidebarView = {
    group,
    sidebar: group === view.group &&
        sidebarPaths(files.paths).includes(view.sidebar)
      ? view.sidebar
      : everything,
  }
  const selected = sidebars?.find((file) => file.path === shown.sidebar)
  const title = selected?.title ??
    (shown.sidebar === everything ? 'Everything' : sidebarName(shown.sidebar))
  const sections = members.map((member) => ({
    id: member,
    label: groupLabel(member, directory),
    options: [
      { path: everything, title: 'Everything' },
      ...feeds.feed(member).sidebars ?? [],
    ].map((option) => ({
      id: option.path,
      label: option.title,
      selected: sameView(shown, { group: member, sidebar: option.path }),
      onSelect: () => onSelectView({ group: member, sidebar: option.path }),
    })),
  }))
  const ambiguous = sections.flatMap((section) => section.options)
    .filter((option) => option.label === title).length > 1
  const key = viewKey(shown)
  const toggles = toggled[key] ?? new Set<string>()
  const toggle = (id: string) =>
    setToggled((current) => {
      const next = new Set(current[key])
      if (!next.delete(id)) next.add(id)
      return { ...current, [key]: next }
    })

  const here = withGroup(pathname, placeGroup)
  const destination = spaceDestination(pathname)
  const activeSession = destination?.kind === 'session' ? destination.id : null
  const lineage = activeSession == null || sessions == null
    ? ''
    : ancestors(sessions, activeSession).join('\n')
  const everythingKey = viewKey({ group, sidebar: everything })
  useEffect(() => {
    if (lineage === '') return
    setToggled((current) => {
      const open = current[everythingKey] ?? new Set<string>()
      const missing = lineage.split('\n').filter((id) => !open.has(id))
      if (missing.length === 0) return current
      return { ...current, [everythingKey]: new Set([...open, ...missing]) }
    })
  }, [lineage, everythingKey])

  const handle = principal == null ? undefined : handleFor(directory, principal)
  const known = principal == null
    ? undefined
    : displayNameFor(directory, principal) ??
      (handle == null ? undefined : `@${handle}`)
  const archive = (session: SessionAddress) => {
    setArchiveError(null)
    onArchiveSession(session).catch((failure: unknown) => {
      setArchiveError(errorMessage(failure))
    })
  }
  return (
    <Sidebar>
      <SidebarHeader
        brand='Wuhu'
        href='/'
        onNavigate={() => onNavigate('/')}
        status={feeds.liveness === 'live'
          ? undefined
          : <Pill tone='amber' dot>reconnecting</Pill>}
      />
      <SidebarActions>
        <PrimaryAction
          label='New agent'
          onClick={() => {
            if (compact) setMode('focus')
            onNewSession()
          }}
        />
      </SidebarActions>
      <SidebarScroll>
        <Picker
          eyebrow={ambiguous
            ? `${space} · ${groupLabel(group, directory)}`
            : undefined}
          title={title}
          label={`Switch view, ${title}`}
          sections={sections}
        />
        {shown.sidebar !== everything &&
          (selected == null
            ? <SidebarNote>Loading…</SidebarNote>
            : (
              <CustomSidebar
                file={selected}
                group={group}
                sessions={feeds.sessions}
                here={here}
                collapsed={toggles}
                onToggle={toggle}
                onNavigate={onNavigate}
              />
            ))}
        {shown.sidebar === everything && (
          <>
            <SidebarSection
              title='Agents'
              count={sessions == null
                ? undefined
                : `${
                  sessions.filter((s) =>
                    s.lifecycle !== 'archived' && s.hold !== 'released'
                  ).length
                } active`}
            >
              {archiveError && (
                <SidebarNote tone='alert'>{archiveError}</SidebarNote>
              )}
              <SessionOutline
                sessions={sessions}
                here={here}
                open={toggles}
                onToggle={toggle}
                onArchive={archive}
                onNavigate={onNavigate}
              />
              <SidebarRow
                label='All agents'
                icon='archive'
                quiet
                href={screens.sessions}
                active={pathname === screens.sessions}
                onClick={() => onNavigate(screens.sessions)}
              />
            </SidebarSection>
            <SidebarSection title='Documents'>
              {error && <SidebarNote tone='alert'>{error}</SidebarNote>}
              {!error && !loaded && <SidebarNote>Loading…</SidebarNote>}
              {!error && loaded && (
                <SpaceTree
                  tree={buildTree(files.paths)}
                  group={group}
                  activePath={placeGroup === group ? activePath : null}
                  expanded={expanded}
                  onToggle={onToggle}
                  onNavigate={onNavigate}
                  onNewDocument={onNewDocument}
                />
              )}
            </SidebarSection>
          </>
        )}
      </SidebarScroll>
      <SidebarFooter
        initials={account.initials}
        avatar={<Avatar principal={principal} name={known} />}
        name={known ?? account.name}
        detail={known != null && handle != null && known !== `@${handle}`
          ? `@${handle}`
          : account.detail}
        settingsLabel='Settings'
        onOpen={() => onNavigate(screens.settings)}
        onSettings={() => onNavigate(screens.settings)}
      >
        <WebPushControl />
      </SidebarFooter>
    </Sidebar>
  )
}

function SessionOutline({
  sessions,
  here,
  open,
  onToggle,
  onArchive,
  onNavigate,
}: {
  sessions: SessionRecord[] | null
  here: string
  open: ReadonlySet<string>
  onToggle: (id: string) => void
  onArchive: (session: SessionAddress) => void
  onNavigate: (to: string) => void
}) {
  // Rows keep the place they were first drawn in while the sidebar is
  // mounted; the roster's activity order would move them under the pointer.
  const [order, setOrder] = useState<readonly string[]>([])
  const listed = stableOrder(
    sessions?.filter((s) => s.lifecycle !== 'archived') ?? [],
    order,
  )
  const ids = listed.map((s) => s.id)
  if (ids.join('\n') !== order.join('\n')) setOrder(ids)

  if (sessions == null) return <SidebarNote>Loading…</SidebarNote>
  if (listed.length === 0) return <SidebarNote>No agents yet</SidebarNote>
  return flatten(nest(listed), (id) => open.has(id)).map((row) => (
    <SessionRow
      key={row.item.id}
      session={row.item}
      depth={row.depth}
      expanded={row.hasChildren ? row.open : undefined}
      active={here === sessionHref(row.item.id, row.item.group)}
      menu={[
        {
          label: 'Archive agent',
          icon: 'archive',
          onSelect: () => onArchive(row.item),
        },
      ]}
      onToggle={row.hasChildren ? () => onToggle(row.item.id) : undefined}
      onNavigate={onNavigate}
    />
  ))
}
