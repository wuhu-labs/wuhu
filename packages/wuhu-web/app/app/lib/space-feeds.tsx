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
  EntryKind,
  GroupSummary,
  MutationEvent,
  QueryOutput,
} from './contract.gen.ts'
import {
  executorLabel,
  executorSpec,
  sessionKind,
  type SessionRecord,
} from './session-model.ts'
import type { EnrolledDevice } from '~/sdk/auth'
import { useObserve } from './use-observe.ts'
import { applyEvent, loadPaths, type PathMap } from './tree.ts'
import { type SidebarFile, sidebarPaths, touchesSidebars } from './sidebars.ts'
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

interface FileState {
  paths: PathMap
  rev: number
  themeRev: number
  sidebarRev: number
  viewRevs: Record<string, number>
  avatarRevs: Record<string, number>
}

function foldFiles(state: FileState, event: MutationEvent): FileState {
  const touched = [event.path, event.kind === 'move' ? event.to : null]
    .filter((path): path is string => path !== null)
  const views = touched.filter((path) => path.endsWith('.view'))
  const avatars = touched.map(sessionOfAvatarPath)
    .filter((session): session is string => session !== null)
  const viewRevs = views.length ? { ...state.viewRevs } : state.viewRevs
  const avatarRevs = avatars.length ? { ...state.avatarRevs } : state.avatarRevs
  for (const path of views) viewRevs[path] = event.rev
  for (const session of avatars) avatarRevs[session] = event.rev
  return {
    paths: applyEvent(state.paths, event),
    rev: event.rev,
    themeRev: touched.includes('/theme.css')
      ? state.themeRev + 1
      : state.themeRev,
    sidebarRev: touched.some(touchesSidebars)
      ? state.sidebarRev + 1
      : state.sidebarRev,
    viewRevs,
    avatarRevs,
  }
}

// viewer() belongs to the authenticated account, not to a sidebar row.
const sessionsSQL = `SELECT id, title, hold, work, lifecycle, kind, parent,
  EXISTS (SELECT 1 FROM notifications n
    WHERE n.recipient = viewer() AND n.kind = 'conversation_message' AND n.source = sessions.id
      AND n.n > COALESCE((SELECT last_read_n FROM watermarks w
        WHERE w.identity = viewer() AND w.source = sessions.id), 0)) AS has_unread,
  executor, executor_config, last_activity_at, error_message, created_by
FROM sessions ORDER BY last_activity_at DESC`

function sessionRows(output: QueryOutput, group: string): SessionRecord[] {
  return output.rows.map((row) => ({
    id: String(row[0]),
    group,
    title: String(row[1]),
    hold: String(row[2]),
    work: String(row[3]),
    lifecycle: String(row[4]),
    kind: sessionKind(row[5]),
    parent: row[6] == null ? null : String(row[6]),
    unread: row[7] === 1,
    executorLabel: executorLabel(String(row[8]), String(row[9])),
    spec: executorSpec(String(row[9])),
    lastActivityAt: String(row[10]),
    errorMessage: row[11] == null ? null : String(row[11]),
    createdBy: String(row[12]),
  }))
}

interface KeptTree {
  paths: [string, EntryKind][]
  rev: number
}

const keepTreeDelayMs = 1_000

export interface GroupFeed {
  loaded: boolean
  error: string | null
  files: FileState
  sidebars: SidebarFile[] | null
  liveness: Liveness
  sessions: SessionRecord[] | null
  contentOrigin: ContentOrigin
}

const emptyFeed: GroupFeed = {
  loaded: false,
  error: null,
  files: {
    paths: new Map(),
    rev: 0,
    themeRev: 0,
    sidebarRev: 0,
    viewRevs: {},
    avatarRevs: {},
  },
  sidebars: null,
  liveness: 'reconnecting',
  sessions: null,
  contentOrigin: undefined,
}

interface SpaceFeeds {
  // Null until the viewer's groups are known.
  groups: GroupSummary[] | null
  feed(group: string): GroupFeed
  liveness: Liveness
  // Every member group's roster, once each has arrived.
  sessions: SessionRecord[] | null
}

const SpaceFeedsContext = createContext<SpaceFeeds | null>(null)

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
      {members.map((group) => (
        <GroupFeedReporter
          key={group}
          client={server.client(group)}
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
  report,
}: {
  client: SpaceClient
  report: (group: string, feed: GroupFeed) => void
}) {
  const feed = useGroupFeed(client)
  useEffect(() => report(client.group, feed), [client, feed, report])
  return null
}

function useGroupFeed(client: SpaceClient): GroupFeed {
  const [loaded, setLoaded] = useState<{ paths: PathMap; rev: number } | null>(
    null,
  )
  const [error, setError] = useState<string | null>(null)
  const [themeSeed] = useState(() => Date.now())
  const cache = useViewerCache(client.group)
  const contentOrigin = useContentOrigin(client)

  // A kept tree skips the crawl: the glob feed replays every change since
  // the revision it was kept at.
  useEffect(() => {
    let cancelled = false
    const kept = cache?.get<KeptTree>('meta', 'tree') ??
      Promise.resolve(undefined)
    kept.then((tree) =>
      tree === undefined
        ? loadPaths(client)
        : { paths: new Map(tree.paths), rev: tree.rev }
    ).then(
      (snapshot) => {
        if (!cancelled) setLoaded(snapshot)
      },
      (failure: unknown) => {
        if (!cancelled) setError(String(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [client, cache])

  const files = useObserve<FileState, MutationEvent>(
    loaded ? globSubscription(client, '**', loaded.rev) : null,
    foldFiles,
    {
      paths: loaded?.paths ?? new Map(),
      rev: loaded?.rev ?? 0,
      themeRev: themeSeed,
      sidebarRev: 0,
      viewRevs: {},
      avatarRevs: {},
    },
  )
  const { paths, rev } = files.data
  useEffect(() => {
    if (cache === null || loaded === null) return
    const timer = setTimeout(() => {
      void cache.put('meta', 'tree', { paths: [...paths], rev })
    }, keepTreeDelayMs)
    return () => clearTimeout(timer)
  }, [cache, loaded, paths, rev])

  const sidebars = useSidebarFiles(
    client,
    sidebarPaths(paths),
    files.data.sidebarRev,
  )
  const sessions = useObserve<SessionRecord[] | null, QueryOutput>(
    sqlSubscription(sessionsSQL, client.group),
    (_, output) => sessionRows(output, client.group),
    null,
  ).data

  return useMemo(() => ({
    loaded: loaded !== null,
    error,
    files: files.data,
    sidebars,
    liveness: files.liveness,
    sessions,
    contentOrigin,
  }), [loaded, error, files, sidebars, sessions, contentOrigin])
}
