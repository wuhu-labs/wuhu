import { sessionRunState } from './session-model'
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from 'react'
import type {
  GroupSummary,
  QueryOutput,
  RevisionEvents,
} from './contract.gen.ts'
import {
  executorLabel,
  executorSpec,
  sessionKind,
  type SessionRecord,
} from './session-model.ts'
import type { EnrolledDevice } from '~/sdk/auth'
import { channelRows, channelsSQL, type ChannelSummary } from './channels.ts'
import {
  routeRows,
  type SessionRoute,
  sessionRoutesSQL,
  withRoutes,
} from './model-route.ts'
import { useObserve } from './use-observe.ts'
import { type FeedStart, FeedStartDiscovery } from './feed-start.ts'
import type { SidebarFile } from './sidebars.ts'
import { useSidebarFiles } from './use-sidebar-files.ts'
import { memberGroups, sharedGroup } from './groups.ts'
import { DirectoryProvider } from './use-directory.tsx'
import {
  type ContentOrigin,
  contentOriginString,
  useContentOrigin,
} from './use-content-origin.ts'
import { cachedThenLive, kept } from './cached-then-live.ts'
import type { SpaceClient, SpaceServer } from '~/sdk/client'
import { globSubscription, sqlSubscription } from '~/sdk/subscriptions'
import { sessionOfAvatarPath } from '~/sdk/avatar'
import type { Liveness } from '~/sdk/observe'
import { useViewerCache } from './viewer-cache.ts'

export function spaceScope(
  device: Pick<EnrolledDevice, 'principal' | 'spaceId'> | null,
): string | null {
  return device?.principal == null
    ? null
    : `${device.principal}:${device.spaceId}`
}

// What the group's change feed tells the chrome: the revision it reached,
// the theme's and each session photo's latest change.
interface FileState {
  rev: number
  themeRev: number
  avatarRevs: Record<string, number>
}

function foldFiles(state: FileState, event: RevisionEvents): FileState {
  const touched = event.events.flatMap(
    (event) => [event.path, event.kind === 'move' ? event.to : null],
  )
    .filter((path): path is string => path !== null)
  const avatars = touched.map(sessionOfAvatarPath)
    .filter((session): session is string => session !== null)
  const avatarRevs = avatars.length ? { ...state.avatarRevs } : state.avatarRevs
  for (const session of avatars) avatarRevs[session] = event.rev
  return {
    rev: event.rev,
    themeRev: touched.includes('/theme.css')
      ? state.themeRev + 1
      : state.themeRev,
    avatarRevs,
  }
}

// viewer() belongs to the authenticated account, not to a sidebar row.
const sessionsSQL = `SELECT id, title, hold, work, lifecycle, kind, parent,
  (SELECT COUNT(*) FROM notifications n
    WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = sessions.id
      AND n.n > COALESCE((SELECT last_read_n FROM watermarks w
        WHERE w.identity = viewer() AND w.source = sessions.id), 0)) AS unread,
  executor, executor_config, last_activity_at, error_message, created_by, run_state,
  created_at
FROM sessions ORDER BY last_activity_at DESC`

function sessionRows(output: QueryOutput, group: string): SessionRecord[] {
  return output.rows.map((row) => ({
    id: String(row[0]),
    group,
    title: String(row[1]),
    hold: String(row[2]),
    work: String(row[3]),
    runState: sessionRunState(row[13]),
    lifecycle: String(row[4]),
    kind: sessionKind(row[5]),
    parent: row[6] == null ? null : String(row[6]),
    unread: Number(row[7]),
    executorLabel: executorLabel(String(row[8]), String(row[9])),
    spec: executorSpec(String(row[9])),
    lastActivityAt: String(row[10]),
    errorMessage: row[11] == null ? null : String(row[11]),
    createdBy: String(row[12]),
    createdAt: String(row[14]),
  }))
}

const keepRevDelayMs = 1_000

const noRoutes: ReadonlyMap<string, SessionRoute> = new Map()

export interface GroupFeed {
  files: FileState
  sidebars: SidebarFile[] | null
  liveness: Liveness
  sessions: SessionRecord[] | null
  channels: ChannelSummary[] | null
  contentOrigin: ContentOrigin
}

const emptyFeed: GroupFeed = {
  files: {
    rev: 0,
    themeRev: 0,
    avatarRevs: {},
  },
  sidebars: null,
  liveness: 'reconnecting',
  sessions: null,
  channels: null,
  contentOrigin: undefined,
}

export interface SpaceFeeds {
  // Null until the viewer's groups are known.
  groups: GroupSummary[] | null
  feed(group: string): GroupFeed
  liveness: Liveness
  // Every member group's roster, once each has arrived.
  sessions: SessionRecord[] | null
}

export const SpaceFeedsContext = createContext<SpaceFeeds | null>(null)

export function useSpaceFeeds(): SpaceFeeds {
  const feeds = useContext(SpaceFeedsContext)
  if (feeds === null) throw new Error('SpaceFeedsProvider is required')
  return feeds
}

export function SpaceFeedsProvider({
  server,
  children,
}: {
  server: SpaceServer
  children: ReactNode
}) {
  const [groups, setGroups] = useState<GroupSummary[] | null>(null)
  const [feeds, setFeeds] = useState<ReadonlyMap<string, GroupFeed>>(
    new Map(),
  )
  const cache = useViewerCache(sharedGroup)
  useEffect(() => {
    let cancelled = false
    cachedThenLive(
      () => kept(cache?.get<GroupSummary[]>('meta', 'groups')),
      () => server.groups(),
      (found) => {
        if (!cancelled) setGroups(found)
      },
      () => undefined,
    )
    return () => {
      cancelled = true
    }
  }, [server, cache])
  const report = useCallback((group: string, feed: GroupFeed) => {
    setFeeds((current) => new Map(current).set(group, feed))
  }, [])

  const members = groups == null ? [] : memberGroups(groups)
  const rosters = members.map((group) => feeds.get(group)?.sessions ?? null)
  const sessions = groups == null || rosters.includes(null)
    ? null
    : rosters.flatMap((roster) => roster!).sort((a, b) =>
      b.lastActivityAt.localeCompare(a.lastActivityAt)
    )
  const origins = new Map(
    members.flatMap((group) => {
      const origin = contentOriginString(feeds.get(group)?.contentOrigin)
      return origin === null ? [] : [[group, origin] as const]
    }),
  )
  const avatarRevs = Object.assign(
    {},
    ...members.map((group) => feeds.get(group)?.files.avatarRevs),
  )
  return (
    <SpaceFeedsContext
      value={{
        groups,
        feed: (group) => feeds.get(group) ?? emptyFeed,
        liveness: members.length > 0 &&
            members.every((group) => feeds.get(group)?.liveness === 'live')
          ? 'live'
          : 'reconnecting',
        sessions,
      }}
    >
      {(groups ?? []).filter((group) => group.readable).map((
        { id: group, member },
      ) => (
        <GroupFeedReporter
          key={group}
          client={server.client(group)}
          member={member === true}
          report={report}
        />
      ))}
      <DirectoryProvider
        contentOrigins={origins}
        sessions={sessions}
        sessionAvatarRevs={avatarRevs}
      >
        {children}
      </DirectoryProvider>
    </SpaceFeedsContext>
  )
}

function GroupFeedReporter({
  client,
  member,
  report,
}: {
  client: SpaceClient
  member: boolean
  report: (group: string, feed: GroupFeed) => void
}) {
  const feed = useGroupFeed(client, member)
  useEffect(() => report(client.group, feed), [client, feed, report])
  return null
}

// One change feed per group (`**`): it follows every open read and stat
// (SpaceClient), the theme and session photos. It starts where it last
// reached, else at the head, so no change between a read and the feed's
// open is lost.
function useGroupFeed(
  client: SpaceClient,
  member: boolean,
): GroupFeed {
  const [start, setStart] = useState<FeedStart>({ from: null, error: null })
  const [themeSeed] = useState(() => Date.now())
  const cache = useViewerCache(client.group)
  const contentOrigin = useContentOrigin(client)
  const discovery = useMemo(() =>
    new FeedStartDiscovery({
      kept: () =>
        cache?.get<number>('meta', 'feed-rev') ?? Promise.resolve(undefined),
      load: async () => (await client.ls('/')).rev ?? 0,
    }, setStart), [client, cache])
  const [ready, setReady] = useState<FeedStartDiscovery | null>(null)
  useEffect(() => {
    let cancelled = false
    void discovery.restore().then(() => {
      if (!cancelled) setReady(discovery)
    })
    return () => {
      cancelled = true
      discovery.close()
    }
  }, [discovery])
  const events = useMemo(() => ({
    onEvent: (event: RevisionEvents) => {
      discovery.opened()
      client.filesChanged(event)
    },
    onOpen: () => {
      discovery.opened()
      client.filesConnected()
    },
  }), [discovery, client])
  const sidebars = useSidebarFiles(client)
  const active = groupFeedActive(member, sidebars)
  const files = useObserve<FileState, RevisionEvents>(
    ready === discovery
      ? groupChangeSubscription(client, member, sidebars, start.from)
      : null,
    foldFiles,
    { rev: start.from ?? 0, themeRev: themeSeed, avatarRevs: {} },
    events,
  )
  const { rev } = files.data
  useEffect(() => {
    if (cache === null || start.from === null) return
    const timer = setTimeout(() => {
      void cache.put('meta', 'feed-rev', rev)
    }, keepRevDelayMs)
    return () => clearTimeout(timer)
  }, [cache, start.from !== null, rev])

  const channels = useObserve<ChannelSummary[] | null, QueryOutput>(
    active ? sqlSubscription(channelsSQL, client.group) : null,
    (_, output) => channelRows(output),
    null,
  ).data
  const roster = useObserve<SessionRecord[] | null, QueryOutput>(
    member ? sqlSubscription(sessionsSQL, client.group) : null,
    (_, output) => sessionRows(output, client.group),
    null,
  )
  const rows = roster.data
  // A server without the route tables refuses this query once; its sessions
  // keep their rows and carry no route for the rest of the connection.
  const routes = useObserve<ReadonlyMap<string, SessionRoute>, QueryOutput>(
    member
      ? {
        ...sqlSubscription(sessionRoutesSQL, client.group),
        stopOnRefusal: true,
      }
      : null,
    (_, output) => routeRows(output),
    noRoutes,
  ).data
  const sessions = useMemo(() => withRoutes(rows, routes), [rows, routes])

  return useMemo(() => ({
    files: files.data,
    sidebars,
    liveness: files.liveness,
    sessions,
    channels,
    contentOrigin,
  }), [
    files,
    sidebars,
    sessions,
    channels,
    contentOrigin,
  ])
}

export function groupFeedActive(
  member: boolean,
  sidebars: readonly SidebarFile[] | null,
): boolean {
  return member || (sidebars?.length ?? 0) > 0
}

export function groupChangeSubscription(
  client: SpaceClient,
  member: boolean,
  sidebars: readonly SidebarFile[] | null,
  from: number | null,
) {
  return globSubscription(
    client,
    groupFeedActive(member, sidebars) ? '**' : '/.sidebars/**',
    from,
  )
}
