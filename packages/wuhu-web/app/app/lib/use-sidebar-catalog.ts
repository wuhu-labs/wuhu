import { useEffect, useRef, useState } from 'react'
import type { GroupDetail, ReadOutput, RevisionEvents } from './contract.gen.ts'
import {
  catalogSidebars,
  namedSidebars,
  readSidebarPreferences,
  selectedSidebar,
  type SidebarAddress,
  sidebarGroupRows,
  sidebarGroups,
  sidebarKey,
  type SidebarPreferences,
  sidebarScripts,
  sidebarSettingsPath,
  writeSidebarVisibility,
} from './sidebar-catalog.ts'
import { discoverSidebarGroups } from './sidebar-discovery.ts'
import { scriptSidebar } from '~/components/script-sidebar'
import type { SidebarView } from './sidebars.ts'
import { useScripts } from './widgets/use-script.ts'
import { useSpaceFeeds } from './space-feeds.tsx'
import { useOwnPrincipal } from './use-directory.tsx'
import { useObserve } from './use-observe.ts'
import { globSubscription } from '~/sdk/subscriptions'
import type { SpaceServer } from '~/sdk/client'
import { ApiError, errorMessage } from '~/sdk/errors'
import { api, inGroup, post } from '~/sdk/http'

export function useSidebarCatalog(
  server: SpaceServer,
  view: SidebarView,
  active: boolean,
  askedGroup: string | null,
) {
  const feeds = useSpaceFeeds()
  const principal = useOwnPrincipal()
  const preferenceChanges = useObserve<number, RevisionEvents>(
    principal == null
      ? null
      : globSubscription(server.client(principal), sidebarSettingsPath, 0),
    (_, event) => event.rev,
    0,
  )
  const [details, setDetails] = useState<ReadonlyMap<string, GroupDetail>>(() =>
    new Map()
  )
  const [detailErrors, setDetailErrors] = useState<ReadonlyMap<string, string>>(
    () => new Map(),
  )
  const [preferences, setPreferences] = useState<SidebarPreferences>({
    hidden: [],
    error: null,
  })
  const [preferencesLoaded, setPreferencesLoaded] = useState(false)
  const [writeError, setWriteError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const writing = useRef(false)
  useEffect(() => {
    if (feeds.groups === null) return
    return discoverSidebarGroups(
      feeds.groups,
      (id) => api<GroupDetail>(`/v1/group/${encodeURIComponent(id)}`),
      (id, detail) => {
        setDetails((previous) => new Map(previous).set(id, detail))
        setDetailErrors((previous) => {
          const next = new Map(previous)
          next.delete(id)
          return next
        })
      },
      (id, failure) =>
        setDetailErrors((previous) =>
          new Map(previous).set(id, errorMessage(failure))
        ),
    )
  }, [feeds.groups, feeds.liveness])
  useEffect(() => {
    if (principal === undefined) return
    if (principal === null) {
      setPreferencesLoaded(true)
      return
    }
    return server.client(principal).read(sidebarSettingsPath)(
      (output) => {
        setPreferencesLoaded(true)
        setPreferences((previous) =>
          readSidebarPreferences(previous, output.content)
        )
      },
      (failure) => {
        setPreferencesLoaded(true)
        setPreferences((previous) =>
          failure instanceof ApiError && failure.code === 'notFound'
            ? readSidebarPreferences(previous, null)
            : { ...previous, error: "Sidebar settings can't be read" }
        )
      },
    )
  }, [server, principal, preferenceChanges.data, preferenceChanges.liveness])
  const groups = feeds.groups === null ? null : sidebarGroups(
    feeds.groups,
    [...details.values()],
    new Set(detailErrors.keys()),
  )
  const entries = groups === null || !preferencesLoaded
    ? null
    : catalogSidebars(groups, (id) =>
      feeds.feed(id).sidebars, preferences.hidden)
  const selected = selectedSidebar(entries, view)
  const scripts = useScripts(
    server,
    sidebarScripts(preferencesLoaded ? entries ?? [] : []),
    selected == null
      ? null
      : sidebarKey({ group: selected.group.id, path: selected.path }),
    active,
  )
  const namedEntries = entries === null
    ? null
    : namedSidebars(entries, (entry) => {
      const tree = scriptSidebar(
        entry.path,
        scripts.get(sidebarKey({ group: entry.group.id, path: entry.path })),
      )
      return typeof tree === 'object' && tree != null ? tree.name : null
    })
  const groupRows = sidebarGroupRows(
    groups ?? [],
    namedEntries ?? [],
    askedGroup,
    (id) => preferencesLoaded && feeds.feed(id).sidebars !== null,
  )
  const selectedGroup = groupRows.find((group) => group.selected) ?? null
  const errors = [...detailErrors].filter(([id]) =>
    groups?.some((group) => group.id === id)
  ).map(([id, message]) =>
    `${groups?.find((group) => group.id === id)?.label ?? id}: ${message}`
  )
  const error =
    [preferences.error, writeError, ...errors].filter(Boolean).join(' · ') ||
    null
  const setVisible = async (address: SidebarAddress, visible: boolean) => {
    if (principal == null || writing.current) return
    writing.current = true
    setBusy(true)
    setWriteError(null)
    try {
      const hidden = await writeSidebarVisibility(
        {
          read: async () => {
            try {
              return await post<ReadOutput>('/v1/tools/read', {
                path: sidebarSettingsPath,
              }, inGroup(principal))
            } catch (failure) {
              if (
                failure instanceof ApiError && failure.code === 'notFound'
              ) return null
              throw failure
            }
          },
          write: (input) => post('/v1/tools/write', input, inGroup(principal)),
        },
        address,
        visible,
      )
      setPreferences({ hidden, error: null })
    } catch (failure) {
      setWriteError(errorMessage(failure))
    } finally {
      writing.current = false
      setBusy(false)
    }
  }
  return {
    groups: groups === null ? null : groupRows,
    selectedGroup,
    entries: namedEntries,
    scripts,
    error,
    busy,
    setVisible,
  }
}

export type SidebarCatalog = ReturnType<typeof useSidebarCatalog>
