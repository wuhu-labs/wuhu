import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useState,
} from 'react'
import {
  type Directory,
  directoryOf,
  emptyDirectory,
  noSessionTitles,
  type SessionTitles,
  sessionTitlesOf,
} from '~/lib/directory'
import type {
  PersonaMintOutput,
  UserPayload,
  UserProfileInput,
  UsersOutput,
} from '~/lib/contract.gen'
import { enrolledDevice, recordPrincipal } from '~/sdk/auth'
import { api } from '~/sdk/http'
import { cachedThenLive, kept } from './cached-then-live.ts'
import { sharedGroup } from './groups.ts'
import { useViewerCache } from './viewer-cache.ts'

export const profileChangedEvent = 'wuhu:profile-changed'

interface DirectoryState {
  users: Directory
  sessions: SessionTitles
  // Undefined while the enrolled device's persona is being resolved; null
  // once it is known there is none, or the lookup failed.
  principal: string | null | undefined
  avatars: AvatarSource
}

export interface AvatarSource {
  // Users' photos are read on shared's content origin; a session's photo and a
  // conversation's attachments on their group's.
  origins: ReadonlyMap<string, string>
  rev: number
  // The revision a session's avatar.png last changed at, from the space's
  // mutation stream, so a replaced photo reloads where it is shown.
  sessionRevs: Readonly<Record<string, number>>
}

const DirectoryContext = createContext<DirectoryState>({
  users: emptyDirectory,
  sessions: noSessionTitles,
  principal: null,
  avatars: { origins: new Map(), rev: 0, sessionRevs: {} },
})

export function useDirectory(): Directory {
  return useContext(DirectoryContext).users
}

export function useSessionTitles(): SessionTitles {
  return useContext(DirectoryContext).sessions
}

export function useOwnPrincipal(): string | null | undefined {
  return useContext(DirectoryContext).principal
}

export function useAvatars(): AvatarSource {
  return useContext(DirectoryContext).avatars
}

export function useGroupOrigin(group: string): string | null {
  const { origins } = useAvatars()
  return origins.get(group) ?? null
}

// The enrolled device knows its account, not its persona, and only a persona
// is a principal here. Adoption is idempotent, so asking once and caching the
// answer converges every device onto the identity the server already attributes
// its writes to.
export async function ownPrincipal(): Promise<string | null> {
  const device = await enrolledDevice()
  if (device == null) return null
  if (device.principal != null) return device.principal
  const minted = await api<PersonaMintOutput>('/v1/persona', { method: 'POST' })
  await recordPrincipal(minted.persona).catch(() => undefined)
  return minted.persona
}

export function DirectoryProvider({
  children,
  contentOrigins = new Map(),
  sessions = null,
  sessionAvatarRevs = {},
}: {
  children: ReactNode
  contentOrigins?: ReadonlyMap<string, string>
  sessions?: readonly { id: string; group: string; title: string }[] | null
  sessionAvatarRevs?: Readonly<Record<string, number>>
}) {
  const [users, setUsers] = useState<Directory>(emptyDirectory)
  const [principal, setPrincipal] = useState<string | null | undefined>()
  const [rev, setRev] = useState(0)
  const cache = useViewerCache(sharedGroup)

  useEffect(() => {
    let cancelled = false
    const load = () => {
      setRev((current) => current + 1)
      cachedThenLive(
        () => kept(cache?.get<UsersOutput>('meta', 'users')),
        async () => {
          const output = await api<UsersOutput>('/v1/users')
          void cache?.put('meta', 'users', output)
          return output
        },
        (output) => {
          if (!cancelled) setUsers(directoryOf(output.users))
        },
        () => undefined,
      )
    }
    load()
    ownPrincipal().then(
      (found) => {
        if (!cancelled) setPrincipal(found)
      },
      () => {
        if (!cancelled) setPrincipal(null)
      },
    )
    globalThis.addEventListener(profileChangedEvent, load)
    return () => {
      cancelled = true
      globalThis.removeEventListener(profileChangedEvent, load)
    }
  }, [cache])

  return (
    <DirectoryContext
      value={{
        users,
        sessions: sessionTitlesOf(sessions),
        principal,
        avatars: {
          origins: contentOrigins,
          rev,
          sessionRevs: sessionAvatarRevs,
        },
      }}
    >
      {children}
    </DirectoryContext>
  )
}

export async function setOwnHandle(
  handle: string,
  displayName?: string | null,
): Promise<UserPayload> {
  const input: UserProfileInput = {
    handle,
    ...(displayName == null || displayName === '' ? {} : { displayName }),
  }
  const payload = await api<UserPayload>('/v1/user/me/profile', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  })
  await recordPrincipal(payload.id).catch(() => undefined)
  globalThis.dispatchEvent(new Event(profileChangedEvent))
  return payload
}
