import type { GroupDetail, GroupSummary } from './contract.gen.ts'

import { type RetryClock, retryClock, retryRead } from './retry-read.ts'

export function discoverSidebarGroups(
  summaries: readonly GroupSummary[],
  read: (id: string) => Promise<GroupDetail>,
  receive: (id: string, detail: GroupDetail) => void,
  failed: (id: string, error: unknown) => void,
  clock: RetryClock = retryClock,
): () => void {
  const stops = summaries.filter((group) => group.readable).map(({ id }) =>
    retryRead(
      () => read(id),
      (detail) => receive(id, detail),
      (error) => failed(id, error),
      clock,
    )
  )
  return () => stops.forEach((stop) => stop())
}
