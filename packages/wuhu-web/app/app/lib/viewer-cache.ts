import { createContext, useContext } from 'react'
import type { ViewerCaches } from '~/sdk/open-cache'

// Null outside a space, or before the viewer's principal is known: nothing is
// painted from cache and nothing is kept.
export const ViewerCacheContext = createContext<ViewerCaches | null>(null)

export function useViewerCache(group: string | null) {
  const caches = useContext(ViewerCacheContext)
  return caches === null || group === null ? null : caches.of(group)
}
