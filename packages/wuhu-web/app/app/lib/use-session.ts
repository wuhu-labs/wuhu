import { useSpaceFeeds } from './space-feeds.tsx'
import type { SessionRecord } from './session-model.ts'

export function useSessionRecord(id: string): SessionRecord | null {
  const { sessions } = useSpaceFeeds()
  return sessions?.find((session) => session.id === id) ?? null
}
