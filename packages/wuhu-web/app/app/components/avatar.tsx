import { type ReactNode, useState } from 'react'
import {
  initialsFrom,
  initialsOf,
  isSession,
  sessionName,
} from '~/lib/directory'
import { useAvatars, useDirectory, useSessionTitles } from '~/lib/use-directory'
import { avatarPath, sessionAvatarPath } from '~/sdk/avatar'
import { crossOriginFor, sharedGroup } from '~/lib/groups'

// A failed load is remembered per revision so a principal without an avatar
// is not re-requested on every mount; the map feeds real state because the
// compiler memoises renders on state, not on module variables.
const missing = new Map<string, number>()

// A session's photo is its home's avatar.png and a user's is under /users; a
// principal the session roster knows is a session unless the caller says so.
// A session outside every group the viewer is a member of shows its initials.
export function Avatar({
  principal,
  name,
  session,
  size = 30,
  fallback,
}: {
  principal: string | null | undefined
  name?: string | null
  session?: boolean
  size?: number
  fallback?: ReactNode
}) {
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const { origins, rev, sessionRevs } = useAvatars()
  const fromSession = principal != null &&
    (session ?? isSession(sessions, principal))
  const group = fromSession ? sessions.groups.get(principal!) : sharedGroup
  const origin = group == null ? null : origins.get(group) ?? null
  const key = principal == null
    ? null
    : `${fromSession ? 'session' : 'user'}:${principal}`
  const version = principal != null && fromSession
    ? sessionRevs[principal] ?? 0
    : rev
  const [failed, setFailed] = useState(
    () => key != null && missing.get(key) === version,
  )

  const initials = name == null || name === ''
    ? (principal == null
      ? ''
      : fromSession
      ? initialsFrom(sessionName(sessions, principal))
      : initialsOf(directory, principal))
    : initialsFrom(name)
  const style = {
    width: size,
    height: size,
    fontSize: Math.max(9, Math.round(size * 0.36)),
  }
  if (
    principal == null || key == null || origin == null ||
    (failed && missing.get(key) === version)
  ) {
    if (fallback != null) return fallback
    return (
      <span className='wuhu-avatar' style={style} aria-hidden='true'>
        {initials}
      </span>
    )
  }
  const path = fromSession
    ? sessionAvatarPath(principal)
    : avatarPath(principal)
  return (
    <img
      className='wuhu-avatar'
      style={style}
      src={`${origin}${path}?v=${version}`}
      crossOrigin={crossOriginFor(group ?? sharedGroup)}
      alt=''
      width={size}
      height={size}
      onError={() => {
        missing.set(key, version)
        setFailed(true)
      }}
    />
  )
}
