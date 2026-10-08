import {
  type CSSProperties,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from 'react'
import { Outlet, useLocation, useNavigate } from 'react-router'
import { AppShell, type Crumb, Crumbs, Pill, Topbar } from '@wuhu/ui'
import { NewDocumentDialog } from '~/components/new-document'
import { SessionCreateDialog } from '~/components/session-create'
import { SpaceComposer } from '~/components/space-composer'
import { SpaceSidebar } from '~/components/space-sidebar'
import type { ReplyDraft } from '~/lib/conversation'
import type { SessionSummary } from '~/lib/session-model'
import type { ConversationMemberPayload } from '~/lib/contract.gen'
import { ancestorPaths, type PathMap } from '~/lib/tree'
import { initialsFrom } from '~/lib/directory'
import { ownPrincipal } from '~/lib/use-directory'
import {
  fileHref,
  placeGroup,
  screens,
  sessionView,
  systemAddress,
  withGroup,
} from '~/lib/links'
import { memberGroups, memberOr, sharedGroup } from '~/lib/groups'
import {
  type ContentOrigin,
  contentOriginString,
} from '~/lib/use-content-origin'
import { spaceDestination } from '~/lib/space-url'
import { homepages } from '~/lib/node-view'
import { ShareActions } from '~/components/share-actions'
import { SessionActions } from '~/components/session-actions'
import { AISharingDialog } from '~/components/ai-sharing-dialog'
import { aiSharing, decideAISharing } from '~/lib/ai-sharing'
import {
  SpaceFeedsProvider,
  spaceScope,
  useSpaceFeeds,
} from '~/lib/space-feeds'
import {
  type SessionCapability,
  sessionCapability,
} from '~/lib/session-capability'
import { pageTarget, targetKey } from '~/lib/composer-target'
import { DraftsProvider, useDrafts } from '~/lib/use-drafts'
import { useConversationAccess } from '~/lib/use-conversation-access'
import { useKeyboardViewport } from '~/lib/use-keyboard-viewport'
import { useSidebarView } from '~/lib/use-sidebar-view'
import { useThemeStylesheet } from '~/lib/use-theme'
import { type EnrolledDevice, enrolledDevice } from '~/sdk/auth'
import { type SpaceClient, SpaceServer } from '~/sdk/client'
import { viewerCaches } from '~/sdk/open-cache'
import { ViewerCacheContext } from '~/lib/viewer-cache'
import { onUnauthorized } from '~/sdk/http'
import { archiveSession } from '~/sdk/session'

export interface SpaceContext {
  group: string
  client: SpaceClient
  contentOrigin: ContentOrigin
  contentHost: string | null
  viewRevs: Record<string, number>
  capability: SessionCapability
  members: ConversationMemberPayload[]
  conversationError: string | null
  replyTo: ((draft: ReplyDraft) => void) | null
  reviewAISharing: () => void
}

interface SpaceShellStyle extends CSSProperties {
  '--wui-keyboard-inset'?: string
}

export function meta() {
  return [{ title: 'Wuhu' }]
}

function nodePathOf(pathname: string): string | null {
  const destination = spaceDestination(pathname)
  return destination?.kind === 'path' ? destination.path : null
}

function shortSpace(id: string): string {
  return id.length > 14 ? `${id.slice(0, 14)}…` : id
}

function initials(device: EnrolledDevice | null): string {
  return initialsFrom(device?.label ?? 'Wuhu')
}

export default function Space() {
  const [device, setDevice] = useState<EnrolledDevice | null | undefined>()
  const caches = useMemo(() => viewerCaches(device ?? null), [device])
  const server = useMemo(() => new SpaceServer(caches), [caches])
  useEffect(() => {
    let cancelled = false
    // Failing to adopt a persona leaves the browser enrolled, only without a
    // known principal yet.
    enrolledDevice().then((found) =>
      found == null || found.principal != null
        ? found
        : ownPrincipal().then(() => enrolledDevice(), () => found)
    ).then(
      (found) => {
        if (!cancelled) setDevice(found)
      },
      () => {
        if (!cancelled) setDevice(null)
      },
    )
    return () => {
      cancelled = true
    }
  }, [])
  if (device === undefined) return null
  const scope = spaceScope(device)
  return (
    <ViewerCacheContext value={caches}>
      <SpaceFeedsProvider key={scope} server={server}>
        <DraftsProvider scope={scope}>
          <SpaceBody server={server} device={device} scope={scope} />
        </DraftsProvider>
      </SpaceFeedsProvider>
    </ViewerCacheContext>
  )
}

function SpaceBody(
  { server, device, scope }: {
    server: SpaceServer
    device: EnrolledDevice | null
    scope: string | null
  },
) {
  const navigate = useNavigate()
  const location = useLocation()
  const [spaceName, setSpaceName] = useState('Wuhu')
  const [contentHost, setContentHost] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const [newDocument, setNewDocument] = useState<
    { directory: string; group: string } | null
  >(null)
  const [reviewingAISharing, setReviewingAISharing] = useState(() =>
    aiSharing() == null
  )
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set())
  const keyboardViewport = useKeyboardViewport()
  const [view, selectView] = useSidebarView(scope, device?.label ?? null)
  const feeds = useSpaceFeeds()
  const { sessions } = feeds
  const group = placeGroup(location.search)
  const client = server.client(group)
  const { files: { paths, viewRevs }, contentOrigin } = feeds.feed(group)
  const members = feeds.groups == null
    ? [sharedGroup]
    : memberGroups(feeds.groups)
  const activePath = nodePathOf(location.pathname)
  const shownPath = activePath === '/'
    ? homepages.find((page) => paths.has(page)) ?? activePath
    : activePath

  const go = useCallback((to: string) => {
    void navigate(to)
  }, [navigate])

  useEffect(() => {
    onUnauthorized(() => void navigate(screens.login, { replace: true }))
    return () => onUnauthorized(null)
  }, [navigate])

  useEffect(() => {
    let cancelled = false
    server.info()
      .then((info) => {
        if (!cancelled) {
          if (info.space) setSpaceName(info.space)
          setContentHost(info.contentHost ?? null)
        }
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [server])

  const shared = feeds.feed(sharedGroup)
  useThemeStylesheet(
    contentOriginString(shared.contentOrigin),
    shared.files.themeRev,
  )

  // Revealing the active file keeps the tree honest after a deep link or a
  // navigation from the document body.
  useEffect(() => {
    if (activePath == null) return
    setExpanded((current) => {
      const missing = ancestorPaths(activePath).filter((p) => !current.has(p))
      if (missing.length === 0) return current
      const next = new Set(current)
      for (const p of missing) next.add(p)
      return next
    })
  }, [activePath])

  const keyboardInset = keyboardViewport == null ? 0 : Math.max(
    0,
    Math.round(
      document.documentElement.clientHeight -
        (keyboardViewport.offsetTop + keyboardViewport.height),
    ),
  )
  const shellStyle: SpaceShellStyle = {
    '--wui-keyboard-inset': `${keyboardInset}px`,
  }

  const destination = spaceDestination(location.pathname)
  const conversationId = destination?.kind === 'conversation'
    ? destination.id
    : null
  const access = useConversationAccess(conversationId, sessions)
  const record = destination?.kind === 'session'
    ? sessions?.find((session) => session.id === destination.id) ?? null
    : null
  const capability: SessionCapability = destination?.kind === 'session'
    ? sessionCapability(record)
    : destination?.kind === 'conversation'
    ? access.capability
    : { kind: 'unknown' }
  const crumbs = describe(location, group, paths, record)
  const drafts = useDrafts()
  const page = pageTarget(
    destination,
    sessionView(location.search),
    capability,
  )
  const replyTo = page && drafts &&
    ((reply: ReplyDraft) =>
      drafts.update(targetKey(page), (draft) => ({ ...draft, reply })))

  return (
    <>
      <AppShell
        style={shellStyle}
        canvas={shownPath?.endsWith('.md') ? 'quiet' : 'atmospheric'}
        sidebar={
          <SpaceSidebar
            account={{
              initials: initials(device),
              name: 'This browser',
              detail: device == null ? 'not enrolled' : shortSpace(spaceName),
            }}
            activePath={activePath}
            expanded={expanded}
            onArchiveSession={archiveSession}
            onNavigate={go}
            onNewDocument={(directory, group) =>
              setNewDocument({ directory, group })}
            onNewSession={() => setCreating(true)}
            onSelectView={selectView}
            onToggle={(path) =>
              setExpanded((current) => {
                const next = new Set(current)
                if (!next.delete(path)) next.add(path)
                return next
              })}
            pathname={location.pathname}
            placeGroup={group}
            space={globalThis.location.hostname}
            view={view}
          />
        }
        topbar={
          <Topbar>
            <Crumbs
              path={crumbs.path}
              leaf={crumbs.leaf}
              onNavigate={go}
              pill={crumbs.pill && <Pill dot>{crumbs.pill}</Pill>}
            />
            {destination?.kind === 'session'
              ? (
                <SessionActions
                  key={destination.id}
                  session={{ id: destination.id, group }}
                  record={record}
                />
              )
              : <ShareActions />}
          </Topbar>
        }
        composer={<SpaceComposer page={page} />}
      >
        <Outlet
          context={{
            group,
            client,
            contentOrigin,
            contentHost,
            viewRevs,
            capability,
            members: access.members,
            conversationError: access.error,
            replyTo,
            reviewAISharing: () => setReviewingAISharing(true),
          } satisfies SpaceContext}
        />
      </AppShell>
      <SessionCreateDialog
        open={creating}
        groups={members}
        group={memberOr(view.group, members)}
        onClose={() => setCreating(false)}
      />
      <AISharingDialog
        open={reviewingAISharing}
        space={spaceName}
        server={globalThis.location.host}
        decision={aiSharing()}
        onChoose={(decision) => {
          decideAISharing(decision)
          setReviewingAISharing(false)
        }}
        onClose={() => setReviewingAISharing(false)}
      />
      <NewDocumentDialog
        client={server.client(newDocument?.group ?? group)}
        directory={newDocument?.directory ?? null}
        exists={(path) =>
          feeds.feed(newDocument?.group ?? group).files.paths.has(path)}
        onClose={() => setNewDocument(null)}
      />
    </>
  )
}

interface Place {
  pathname: string
  search: string
}

function describe(
  place: Place,
  group: string,
  paths: PathMap,
  record: SessionSummary | null,
): { path: Crumb[]; leaf: string; pill?: string } {
  if (place.pathname === screens.sessions) return { path: [], leaf: 'Agents' }
  if (place.pathname === screens.settings) return { path: [], leaf: 'Settings' }
  if (place.pathname === screens.templates) {
    return { path: [], leaf: 'Templates' }
  }
  const system = systemAddress(place.pathname)
  if (system != null) {
    const segments = system.split('/').slice(3)
    return {
      path: segments.slice(0, -1).map((label) => ({ label })),
      leaf: segments.at(-1)!,
      pill: 'System',
    }
  }
  const destination = spaceDestination(place.pathname)
  if (destination == null) return { path: [], leaf: 'Space' }
  switch (destination.kind) {
    case 'path': {
      const segments = destination.path.split('/').filter(Boolean)
      const path: Crumb[] = segments.slice(0, -1).map((label, index) => ({
        label,
        href: fileHref(`/${segments.slice(0, index + 1).join('/')}`, group),
      }))
      // A file's extension already names its kind; only the kinds a name
      // cannot carry earn a pill.
      const kind = paths.get(destination.path)
      const pill = kind === 'table'
        ? 'Table'
        : kind === 'directory'
        ? 'Directory'
        : undefined
      return {
        path: [{ label: 'files', href: withGroup('/', group) }, ...path],
        leaf: segments.at(-1) ?? '/',
        pill,
      }
    }
    case 'conversation':
      return { path: [], leaf: destination.id, pill: 'Conversation' }
    case 'session': {
      const view = sessionView(place.search)
      return {
        path: [{ label: 'agents', href: screens.sessions }],
        leaf: record?.title ?? destination.id.slice(0, 8),
        pill: record == null
          ? undefined
          : view === 'context'
          ? 'Context'
          : view === 'transcript'
          ? 'Transcript'
          : record.kind === 'task'
          ? 'Task'
          : 'Box',
      }
    }
  }
}
