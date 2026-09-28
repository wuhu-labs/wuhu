import { useCallback, useEffect, useRef, useState } from 'react'
import {
  type DeviceCommand,
  deviceCommands,
  deviceCommandsSQL,
  playCommands,
} from './device-commands.ts'
import type { QueryOutput } from './contract.gen.ts'
import { sharedGroup } from './groups.ts'
import { recallSidebar, rememberSidebar, type SidebarView } from './sidebars.ts'
import { useSpaceFeeds } from './space-feeds.tsx'
import { useObserve } from './use-observe.ts'
import { registerDevice } from '~/sdk/device'
import { sqlSubscription } from '~/sdk/subscriptions'

// The person's pick and a manipulate_ui command are one selection: both land
// here and both are remembered.
export function useSidebarView(
  scope: string | null,
  key: string | null,
): [SidebarView, (view: SidebarView) => void] {
  const [view, setView] = useState(() => recallSidebar(scope))
  const select = useCallback((next: SidebarView) => {
    setView(next)
    rememberSidebar(scope, next)
  }, [scope])

  // Registration runs again on every reconnect of the space feed, as native
  // registers on every connect, so one failed attempt is not final.
  const { liveness } = useSpaceFeeds()
  const [device, setDevice] = useState<string | null>(null)
  useEffect(() => {
    if (key == null || liveness !== 'live') return
    let cancelled = false
    registerDevice(key).then(
      (registered) => {
        if (!cancelled) setDevice(registered.id)
      },
      () => undefined,
    )
    return () => {
      cancelled = true
    }
  }, [key, liveness])

  const commands = useObserve<DeviceCommand[], QueryOutput>(
    device == null
      ? null
      : sqlSubscription(deviceCommandsSQL(device), sharedGroup),
    (_, output) => deviceCommands(output),
    [],
  ).data
  const played = useRef(0)
  useEffect(() => {
    const next = playCommands(commands, played.current, Date.now())
    played.current = next.played
    // manipulate_ui names "everything" or one of Shared's sidebar paths.
    if (next.sidebar != null) {
      select({ group: sharedGroup, sidebar: next.sidebar })
    }
  }, [commands, select])

  return [view, select]
}
