import type { GroupSummary } from './contract.gen.ts'
import { type Directory, displayFor } from './directory.ts'
import { sharedGroup } from './shell-sdk/open-cache.js'

export { sharedGroup }

// The groups the viewer acts in, Shared first, then the server's order.
export function memberGroups(groups: readonly GroupSummary[]): string[] {
  const ids = groups.filter((group) => group.member).map((group) => group.id)
  return ids.includes(sharedGroup)
    ? [sharedGroup, ...ids.filter((id) => id !== sharedGroup)]
    : ids
}

// A personal group's id is its person's.
export function groupLabel(group: string, directory: Directory): string {
  return group === sharedGroup ? 'Shared' : displayFor(directory, group)
}

// A group host is another site than Shared's, so its reads carry the cookie.
export function crossOriginFor(group: string): 'use-credentials' | undefined {
  return group === sharedGroup ? undefined : 'use-credentials'
}
