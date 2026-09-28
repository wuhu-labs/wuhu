import { useMemo, useSyncExternalStore } from 'react'
import {
  browserNetwork,
  type Fold,
  observeStore,
  realTimer,
  type Snapshot,
} from '~/sdk/observe'
import { openAuthorizedStream } from '~/sdk/sse'
import { inGroup } from '~/sdk/http'
import type { GroupSubscription } from '~/sdk/subscriptions'
import { useViewerCache } from './viewer-cache.ts'

// The fold must be a pure function of (data, event); the store captures it once
// per connection, so it must not close over changing render state.
export function useObserve<Data, Event>(
  subscription: GroupSubscription<Event> | null,
  fold: Fold<Data, Event>,
  initial: Data,
): Snapshot<Data> {
  const url = subscription ? subscription.url(subscription.from) : null
  const key = url === null ? null : `${subscription!.group}\n${url}`
  const cache = useViewerCache(subscription?.group ?? null)

  const store = useMemo(() => {
    if (!subscription || key === null) {
      const snapshot: Snapshot<Data> = {
        data: initial,
        liveness: 'reconnecting',
      }
      return {
        subscribe: () => () => {},
        getSnapshot: () => snapshot,
        close: () => {},
      }
    }
    return observeStore({
      subscription,
      fold,
      initial,
      open: (url) => openAuthorizedStream(url, inGroup(subscription.group)),
      timer: realTimer,
      cache,
      network: browserNetwork,
    })
    // The initial URL keys the store: a new session/query rebuilds it; a
    // re-render with the same target keeps the cursor and the live connection.
  }, [key, cache])

  return useSyncExternalStore(
    store.subscribe,
    store.getSnapshot,
    store.getSnapshot,
  )
}
