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
  return value == null || value === '' ? undefined : value
}

export function directoryOf(users: readonly DirectoryUser[]): Directory {
  const entries = new Map<string, DirectoryEntry>()
  for (const user of users) {
    const handle = present(user.handle)
    const displayName = present(user.displayName)
    if (handle == null && displayName == null) continue
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
): string {
  const found = present(handle) ?? handleFor(directory, principal)
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
  if (senderIsSession(sessions, message)) {
    return sessionName(sessions, message.sender)
  }
  return displayFor(directory, message.sender, message.senderHandle)
}

export function principalName(
  directory: Directory,
  sessions: SessionTitles,
  principal: string,
): string {
  return isSession(sessions, principal)
    ? sessionName(sessions, principal)
    : displayFor(directory, principal)
}

export function memberName(
  directory: Directory,
  member: { member: string; memberHandle?: string | null },
): string {
  return displayFor(directory, member.member, member.memberHandle)
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
