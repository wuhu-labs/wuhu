import { useEffect, useRef, useState } from 'react'
import type {
  GroupDetail,
  SidebarVisibilityInput,
  UserSettingsPayload,
} from './contract.gen.ts'
import {
  catalogSidebars,
  namedSidebars,
  selectedSidebar,
  type SidebarAddress,
  sidebarGroupRows,
  sidebarGroups,
  sidebarKey,
  sidebarScripts,
} from './sidebar-catalog.ts'
import { discoverSidebarGroups } from './sidebar-discovery.ts'
import { scriptSidebar } from '~/components/script-sidebar'
import type { SidebarView } from './sidebars.ts'
import { useScripts } from './widgets/use-script.ts'
import { useSpaceFeeds } from './space-feeds.tsx'
import { usePageVisible } from './use-page-visible.ts'
import type { SpaceServer } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { api } from '~/sdk/http'

export function useSidebarCatalog(
  server: SpaceServer,
  view: SidebarView,
  active: boolean,
  askedGroup: string | null,
) {
  const feeds = useSpaceFeeds()
  const pageVisible = usePageVisible()
  const settingsRequest = useRef(0)
  const [details, setDetails] = useState<ReadonlyMap<string, GroupDetail>>(() =>
    new Map()
  )
  const [detailErrors, setDetailErrors] = useState<ReadonlyMap<string, string>>(
    () => new Map(),
  )
  const [preferences, setPreferences] = useState<
    UserSettingsPayload & { error: string | null }
  >({ hidden: [], error: null })
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
    if ((!pageVisible && settingsRequest.current !== 0) || writing.current) {
      return
    }
    const request = ++settingsRequest.current
    let cancelled = false
    void api<UserSettingsPayload>('/v1/user/me/settings').then(
      (output) => {
        if (cancelled || request !== settingsRequest.current) return
        setPreferencesLoaded(true)
        setPreferences({ ...output, error: null })
      },
      () => {
        if (cancelled || request !== settingsRequest.current) return
        setPreferencesLoaded(true)
        setPreferences((previous) => ({
          ...previous,
          error: "Sidebar settings can't be read",
        }))
      },
    )
    return () => {
      cancelled = true
    }
  }, [pageVisible])
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
    if (writing.current) return
    writing.current = true
    settingsRequest.current++
    setBusy(true)
    setWriteError(null)
    try {
      const input: SidebarVisibilityInput = { ...address, hidden: !visible }
      const output = await api<UserSettingsPayload>(
        '/v1/user/me/settings/sidebar',
        {
          method: 'PUT',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(input),
        },
      )
      setPreferences({ ...output, error: null })
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
