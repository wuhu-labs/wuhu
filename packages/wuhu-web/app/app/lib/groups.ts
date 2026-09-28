import type { GroupSummary } from './contract.gen.ts'
import { type Directory, displayNameFor } from './directory.ts'
import { sharedGroup } from './shell-sdk/open-cache.js'

export { sharedGroup }

// The groups the viewer acts in, Shared first, then the server's order.
export function memberGroups(groups: readonly GroupSummary[]): string[] {
  const ids = groups.filter((group) => group.member).map((group) => group.id)
  return ids.includes(sharedGroup)
    ? [sharedGroup, ...ids.filter((id) => id !== sharedGroup)]
    : ids
}

// Where the view's group stands: itself while the groups are loading or when
// the viewer is a member there, else Shared.
export function memberOr(
  group: string,
  members: readonly string[] | null,
): string {
  return members == null || members.includes(group) ? group : sharedGroup
}

// A personal group's id is its person's.
export function groupLabel(group: string, directory: Directory): string {
  return group === sharedGroup
    ? 'Shared'
    : displayNameFor(directory, group) ?? group
}

// A sender from outside the conversation's group carries that group's label.
export function senderGroupLabel(
  senderGroup: string | null | undefined,
  group: string,
  directory: Directory,
): string | null {
  return senderGroup == null || senderGroup === group
    ? null
    : groupLabel(senderGroup, directory)
}

// A group host is another site than Shared's, so its reads carry the cookie.
export function crossOriginFor(group: string): 'use-credentials' | undefined {
  return group === sharedGroup ? undefined : 'use-credentials'
}
