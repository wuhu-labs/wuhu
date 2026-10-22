import { useCallback, useEffect, useMemo, useState } from 'react'
import { Outlet, useLocation, useNavigate } from 'react-router'
import {
  AppShell,
  GlassButton,
  Icon,
  NavButtons,
  type PageLayout,
  TitlePill,
} from '@wuhu/ui'
import { AISharingDialog } from '~/components/ai-sharing-dialog'
import { Composer } from '~/components/composer'
import { SessionCreateDialog } from '~/components/session-create'
import {
  settingsPlace,
  SettingsRail,
  SettingsSidebar,
} from '~/components/settings-nav'
import {
  CustomSidebar,
  EverythingSidebar,
  SessionAvatar,
  SidebarRail,
} from '~/components/space-sidebar'
import { aiSharing, decideAISharing } from '~/lib/ai-sharing'
import { inCreationOrder } from '~/lib/cards'
import { composerSend } from '~/lib/composer-send'
import {
  composerAim,
  dockAfter,
  keepDock,
  keptDock,
  pageTarget,
  targetKey,
} from '~/lib/composer-target'
import type { QueryOutput } from '~/lib/contract.gen'
import { memberGroups, sharedGroup } from '~/lib/groups'
import { placeGroup, screens, withoutGroup } from '~/lib/links'
import {
  type SessionCapability,
  sessionCapability,
} from '~/lib/session-capability'
import { everything, sameView } from '~/lib/sidebars'
import {
  SpaceFeedsProvider,
  spaceScope,
  useSpaceFeeds,
} from '~/lib/space-feeds'
import { type SpaceDestination, spaceDestination } from '~/lib/space-url'
import { useConversationAccess } from '~/lib/use-conversation-access'
import {
  type ContentOrigin,
  contentOriginString,
} from '~/lib/use-content-origin'
import { useDictationOffered } from '~/lib/use-dictation'
import { ownPrincipal } from '~/lib/use-directory'
import { DraftsProvider, useDrafts } from '~/lib/use-drafts'
import { useObserve } from '~/lib/use-observe'
import { useShownNode } from '~/lib/use-shown-node'
import { useSidebarView } from '~/lib/use-sidebar-view'
import { useThemeStylesheet } from '~/lib/use-theme'
import { type ShownPage, viewingOf } from '~/lib/viewing'
import { ViewerCacheContext } from '~/lib/viewer-cache'
import { type EnrolledDevice, enrolledDevice } from '~/sdk/auth'
import { type SpaceClient, SpaceServer } from '~/sdk/client'
import { onUnauthorized } from '~/sdk/http'
import { viewerCaches } from '~/sdk/open-cache'
import { sqlSubscription } from '~/sdk/subscriptions'

export interface SpaceContext {
  group: string
  client: SpaceClient
  contentOrigin: ContentOrigin
  contentHost: string | null
  reviewAISharing: () => void
  // The node page on screen, or null elsewhere: while the next node at this
  // address loads, the page it replaces.
  shown: ShownPage | null
}

export function meta() {
  return [{ title: 'Wuhu' }]
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

// How each page sits in the window: chats, settings and Markdown scroll; an
// HTML page is framed unless its stat says immersive; every other node is
// framed content. A Markdown node still loading waits in the scroll layout;
// anything else loading answers null: SpaceBody keeps the page already on
// screen, layout and content, until it knows, so neither a frame blinks off
// between framed pages nor an immersive page shows a frame first.
export function pageLayout(
  destination: SpaceDestination | null,
  shown: ShownPage | null,
): PageLayout | null {
  if (destination?.kind !== 'path' || shown === null) return 'scroll'
  const view = shown.view
  switch (view.state) {
    case 'markdown':
    case 'error':
      return 'scroll'
    case 'html':
      return view.layout === 'immersive' ? 'immersive' : 'framed'
    case 'loading':
      return shown.requested.endsWith('.md') ? 'scroll' : null
    default:
      return 'framed'
  }
}

// The page pill's name: an HTML page's <title> or a Markdown document's
// frontmatter title, else the title of the sidebar row that opened it, else
// its file name (its folder's for an index page).
function usePageTitle(
  group: string,
  shown: ShownPage | null,
  rowTitle: string | null,
): string | null {
  const markdown = shown?.path.endsWith('.md') ? shown.path : null
  const declared = useObserve<string | null, QueryOutput>(
    markdown === null ? null : sqlSubscription(
      `SELECT json_extract(value, '$') FROM doc_custom_attrs
        WHERE path = ? AND name = 'title' ORDER BY ord LIMIT 1`,
      group,
      [markdown],
    ),
    (_, output) => {
      const title = output.rows[0]?.[0]
      return typeof title === 'string' && title.trim() !== '' ? title : null
    },
    null,
  ).data
  if (shown === null) return null
  const view = shown.view
  return (view.state === 'html' ? view.title : declared) ?? rowTitle ??
    fileName(shown.path)
}

// A document's name without its kind's extension; other files keep theirs.
function fileName(path: string): string {
  const names = path.split('/').filter(Boolean)
  const last = names.at(-1)
  if (last === undefined) return '/'
  if (names.length > 1 && /^index\.[a-z]+$/i.test(last)) return names.at(-2)!
  return last.replace(/\.(md|html?|view|table)$/i, '')
}

// What a navigation carries: the sidebar row's title, or, inside Settings,
// the page Settings was opened from and that page's row title.
interface NavigationState {
  title?: string
  from?: string
  fromTitle?: string
}

interface HistoryReach {
  canGoBack: boolean
  canGoForward: boolean
}

// The Navigation API knows both directions; without it, Back is offered and
// Forward is not.
function historyReach(): HistoryReach {
  const navigation = (globalThis as { navigation?: HistoryReach }).navigation
  return navigation == null
    ? { canGoBack: globalThis.history.length > 1, canGoForward: false }
    : {
      canGoBack: navigation.canGoBack,
      canGoForward: navigation.canGoForward,
    }
}

export function SpaceBody(
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
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [reviewingAISharing, setReviewingAISharing] = useState(() =>
    aiSharing() == null
  )
  const [view, selectView] = useSidebarView(scope, device?.label ?? null)
  const feeds = useSpaceFeeds()
  const { sessions } = feeds
  const group = placeGroup(location.search)
  const client = server.client(group)
  const { contentOrigin } = feeds.feed(group)
  const shared = feeds.feed(sharedGroup)
  const members = feeds.groups == null
    ? [sharedGroup]
    : memberGroups(feeds.groups)
  const onSettings = location.pathname === screens.settings
  const destination = onSettings ? null : spaceDestination(location.pathname)
  const shown = useShownNode({
    group,
    client,
    contentOrigin,
    path: destination?.kind === 'path' ? destination.path : null,
    suffix: withoutGroup(location.search) + location.hash,
  })
  const here = location.pathname + location.search
  const carried = (location.state ?? {}) as NavigationState
  // Where the Settings button returns to, with the title the page had.
  const settingsFrom = onSettings ? carried.from ?? '/' : here
  const settingsFromTitle = onSettings ? carried.fromTitle : carried.title

  const go = useCallback((to: string, title?: string) => {
    const state: NavigationState | null =
      new URL(to, globalThis.location.origin).pathname === screens.settings
        ? { from: settingsFrom, fromTitle: settingsFromTitle }
        : title == null
        ? null
        : { title }
    void navigate(to, { state })
  }, [navigate, settingsFrom, settingsFromTitle])
  const toggleSidebar = useCallback(() => setSidebarOpen((open) => !open), [])

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

  useThemeStylesheet(
    contentOriginString(shared.contentOrigin),
    shared.files.themeRev,
  )

  const reach = historyReach()

  // The composer: a session or channel page posts to itself; any other page
  // asks the last agent box opened, else Shared's first live agent.
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
  const page = pageTarget(destination, capability)
  // The dock follows navigation, adjusted while rendering, and is kept per
  // space; before any agent box was opened it is Shared's oldest live agent.
  const [dock, setDock] = useState(() => keptDock(scope))
  if (dockAfter(dock, page) !== dock) setDock(dockAfter(dock, page))
  useEffect(() => keepDock(scope, dock), [scope, dock])
  const fallbackDock =
    inCreationOrder(shared.sessions ?? []).find((session) =>
      session.kind === 'agent' && session.parent == null &&
      session.lifecycle !== 'archived'
    )?.id ?? null
  const live = (id: string | null) =>
    sessions?.find((session) =>
      session.id === id && session.lifecycle !== 'archived'
    )
  const docked = live(dock) ?? live(fallbackDock) ?? null
  const aim = onSettings ? null : composerAim({
    destination,
    page,
    dock: docked?.id ?? null,
  })
  const drafts = useDrafts()
  const dictate = useDictationOffered()
  const channel = conversationId == null
    ? null
    : shared.channels?.find((found) => found.id === conversationId) ?? null
  const pageTitle = usePageTitle(group, shown, carried.title ?? null)

  const composer = drafts === null || aim === null ? null : (
    <Composer
      key={targetKey(aim.target)}
      drafts={drafts}
      draftKey={targetKey(aim.target)}
      placeholder={aim.docked
        ? `Ask ${docked!.title} about this page`
        : `Message ${
          aim.target.kind === 'session'
            ? record?.title ?? 'this agent'
            : channel?.title ?? 'this channel'
        }`}
      dictate={dictate}
      onSend={composerSend({
        target: aim.target,
        group: aim.docked ? docked!.group : group,
        viewing: aim.docked ? viewingOf(shown) : null,
      })}
    />
  )

  const pill = onSettings
    ? <TitlePill>Settings</TitlePill>
    : destination?.kind === 'session'
    ? (
      <TitlePill
        lead={record && <SessionAvatar session={record} size={26} />}
      >
        {record?.title ?? destination.id}
      </TitlePill>
    )
    : destination?.kind === 'conversation'
    ? <TitlePill>{channel?.title ?? 'Channel'}</TitlePill>
    : pageTitle && <TitlePill>{pageTitle}</TitlePill>

  // While a node loads, the page already on screen stays, layout and
  // content; a first open with nothing on screen waits under the whole
  // window.
  const [held, setHeld] = useState<{
    layout: PageLayout
    shown: ShownPage | null
  }>({ layout: 'immersive', shown: null })
  const known = pageLayout(destination, shown)
  if (known !== null && (known !== held.layout || shown !== held.shown)) {
    setHeld({ layout: known, shown })
  }
  const layout = known ?? held.layout
  const onScreen = known === null ? held.shown : shown

  const settings = onSettings ? settingsPlace(location.search) : null
  const sidebarFiles = shared.sidebars
  // A view whose file left the space falls back to Everything without
  // forgetting the choice.
  const file = sidebarFiles?.find((found) => found.path === view.sidebar) ??
    null

  return (
    <>
      <AppShell
        sidebarOpen={sidebarOpen}
        onToggleSidebar={toggleSidebar}
        pinned={onSettings}
        tools={
          <>
            <GlassButton
              aria-label='Settings'
              title='Settings'
              aria-pressed={onSettings}
              solid={onSettings}
              onClick={() =>
                onSettings
                  ? go(settingsFrom, settingsFromTitle)
                  : go(screens.settings)}
            >
              <Icon name='gear' w={18} h={18} />
            </GlassButton>
            <GlassButton
              aria-label='New agent'
              title='New agent'
              onClick={() => setCreating(true)}
            >
              <Icon name='plus' w={15} h={16} />
            </GlassButton>
          </>
        }
        rail={settings
          ? <SettingsRail topic={settings.topic} onNavigate={go} />
          : (
            <SidebarRail
              files={sidebarFiles}
              current={file?.path ?? everything}
              onPick={(sidebar) => {
                const next = { group: sharedGroup, sidebar }
                if (!sameView(next, view)) selectView(next)
              }}
            />
          )}
        sidebar={settings
          ? (
            <SettingsSidebar
              topic={settings.topic}
              row={settings.row}
              onNavigate={go}
            />
          )
          : file == null
          ? (
            <EverythingSidebar
              sessions={shared.sessions}
              channels={shared.channels}
              here={here}
              onNavigate={go}
            />
          )
          : (
            <CustomSidebar
              key={file.path}
              file={file}
              group={sharedGroup}
              sessions={sessions}
              here={here}
              onNavigate={go}
            />
          )}
        toolbar={
          <>
            <NavButtons
              canBack={reach.canGoBack}
              canForward={reach.canGoForward}
              onBack={() => globalThis.history.back()}
              onForward={() => globalThis.history.forward()}
            />
            {pill}
          </>
        }
        composer={composer}
        layout={layout}
      >
        <Outlet
          context={{
            group,
            client,
            contentOrigin,
            contentHost,
            reviewAISharing: () => setReviewingAISharing(true),
            shown: onScreen,
          } satisfies SpaceContext}
        />
      </AppShell>
      <SessionCreateDialog
        open={creating}
        groups={members}
        group={sharedGroup}
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
    </>
  )
}
