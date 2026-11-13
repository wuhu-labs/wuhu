import { type ReactNode, useEffect, useMemo, useState } from 'react'
import { type EnrolledDevice, enrolledDevice } from '~/sdk/auth'
import { SpaceServer } from '~/sdk/client'
import { viewerCaches } from '~/sdk/open-cache'
import { ownViewer, type Viewer } from '~/sdk/viewer'
import { type RetryClock, retryClock, retryRead } from './retry-read.ts'
import { SpaceFeedsProvider, spaceScope } from './space-feeds.tsx'
import { DraftsProvider } from './use-drafts.tsx'
import { ViewerCacheContext } from './viewer-cache.ts'

// The key decides device registration; the server's answer decides who the
// browser is: null once it refuses, undefined while a failed ask retries.
interface Seat {
  device: EnrolledDevice | null
  viewer: Viewer | null | undefined
}

export function Seated({ children, clock = retryClock }: {
  children: (
    seated: {
      server: SpaceServer
      deviceKey: string | null
      scope: string | null
    },
  ) => ReactNode
  clock?: RetryClock
}) {
  const seat = useSeat(clock)
  const viewer = seat?.viewer ?? null
  const caches = useMemo(() => viewerCaches(viewer), [viewer])
  const server = useMemo(() => new SpaceServer(caches), [caches])
  if (seat === undefined) return null
  const scope = spaceScope(viewer)
  return (
    <ViewerCacheContext value={caches}>
      <SpaceFeedsProvider key={scope} server={server} viewer={seat.viewer}>
        <DraftsProvider scope={scope}>
          {children({ server, deviceKey: seat.device?.label ?? null, scope })}
        </DraftsProvider>
      </SpaceFeedsProvider>
    </ViewerCacheContext>
  )
}

function useSeat(clock: RetryClock): Seat | undefined {
  const [seat, setSeat] = useState<Seat>()
  useEffect(() => {
    let device: EnrolledDevice | null = null
    return retryRead(
      async () => {
        device = await enrolledDevice().catch(() => null)
        return { device, viewer: await ownViewer() }
      },
      setSeat,
      () => setSeat((seat) => seat ?? { device, viewer: undefined }),
      clock,
    )
  }, [clock])
  return seat
}
