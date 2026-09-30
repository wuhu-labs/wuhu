export interface DirectoryUser {
  id: string
  handle?: string | null
  displayName?: string | null
}

export interface DirectoryEntry {
  handle?: string
  displayName?: string
}

export type Directory = ReadonlyMap<string, DirectoryEntry>

export const emptyDirectory: Directory = new Map()

function present(value: string | null | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed == null || trimmed === '' ? undefined : trimmed
}

export function directoryOf(users: readonly DirectoryUser[]): Directory {
  const entries = new Map<string, DirectoryEntry>()
  for (const user of users) {
    const handle = present(user.handle)
    const displayName = present(user.displayName)
    entries.set(user.id, {
      ...(handle == null ? {} : { handle }),
      ...(displayName == null ? {} : { displayName }),
    })
  }
  return entries
}

export function handleFor(
  directory: Directory,
  principal: string,
): string | undefined {
  return directory.get(principal)?.handle
}

export function displayNameFor(
  directory: Directory,
  principal: string,
): string | undefined {
  return directory.get(principal)?.displayName
}

export function displayFor(
  directory: Directory,
  principal: string,
  handle?: string | null,
  sessions: SessionTitles = noSessionTitles,
  kind?: string | null,
): string {
  if (senderIsSession(sessions, { sender: principal, senderKind: kind })) {
    return sessionName(sessions, principal)
  }
  const entry = directory.get(principal)
  const name = entry?.displayName
  if (name != null) return name
  const found = entry == null ? present(handle) : entry.handle
  return found == null ? principal : `@${found}`
}

// Every session's group, and the titles of the ones that have one. A session
// is never a user, so a known session id is never looked up in the user
// directory, titled or not.
export interface SessionTitles {
  groups: ReadonlyMap<string, string>
  titles: ReadonlyMap<string, string>
}

export const noSessionTitles: SessionTitles = {
  groups: new Map(),
  titles: new Map(),
}

export function sessionTitlesOf(
  sessions:
    | readonly { id: string; group: string; title: string }[]
    | null
    | undefined,
): SessionTitles {
  const groups = new Map<string, string>()
  const titles = new Map<string, string>()
  for (const session of sessions ?? []) {
    groups.set(session.id, session.group)
    if (session.title !== '') titles.set(session.id, session.title)
  }
  return { groups, titles }
}

export function isSession(sessions: SessionTitles, id: string): boolean {
  return sessions.groups.has(id)
}

// The name a session is shown under: its title, else its id.
export function sessionName(sessions: SessionTitles, id: string): string {
  return sessions.titles.get(id) ?? id
}

export function senderIsSession(
  sessions: SessionTitles,
  message: { sender: string; senderKind?: string | null },
): boolean {
  return message.senderKind == null
    ? isSession(sessions, message.sender)
    : message.senderKind === 'session'
}

export function senderName(
  directory: Directory,
  message: {
    sender: string
    senderHandle?: string | null
    senderKind?: string | null
  },
  sessions: SessionTitles = noSessionTitles,
): string {
  return displayFor(
    directory,
    message.sender,
    message.senderHandle,
    sessions,
    message.senderKind,
  )
}

export function principalName(
  directory: Directory,
  sessions: SessionTitles,
  principal: string,
): string {
  return displayFor(directory, principal, undefined, sessions)
}

export function memberName(
  directory: Directory,
  member: { member: string; memberHandle?: string | null; kind?: string },
  sessions: SessionTitles = noSessionTitles,
): string {
  return displayFor(
    directory,
    member.member,
    member.memberHandle,
    sessions,
    member.kind,
  )
}

export function memberHandle(
  directory: Directory,
  member: { member: string; memberHandle?: string | null; kind?: string },
  sessions: SessionTitles,
): string | undefined {
  if (
    senderIsSession(sessions, {
      sender: member.member,
      senderKind: member.kind,
    })
  ) {
    return undefined
  }
  const entry = directory.get(member.member)
  if (entry?.displayName == null || entry.handle == null) return undefined
  const handle = `@${entry.handle}`
  return handle === entry.displayName ? undefined : handle
}

export function initialsFrom(source: string): string {
  const words = source.split(/[\s._-]+/).filter(Boolean)
  const letters = words.length > 1
    ? `${words[0][0]}${words[1][0]}`
    : (words[0] ?? source).slice(0, 2)
  return letters.toUpperCase()
}

export function initialsOf(directory: Directory, principal: string): string {
  const entry = directory.get(principal)
  return initialsFrom(entry?.displayName ?? entry?.handle ?? principal)
}
