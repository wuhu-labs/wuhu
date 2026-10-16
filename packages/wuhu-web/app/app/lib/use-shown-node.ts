import { useEffect, useRef, useState } from 'react'
import { cachedThenLive } from './cached-then-live.ts'
import { loadShownNode, type NodeSource, type ShownNode } from './node-view.ts'
import type { GroupFeed } from './space-feeds.tsx'
import type { ContentOrigin } from './use-content-origin.ts'
import type { ShownPage } from './viewing.ts'
import type { SpaceClient } from '~/sdk/client'
import { ApiError, errorMessage } from '~/sdk/errors'

export interface NodeAddress {
  group: string
  client: SpaceClient
  contentOrigin: ContentOrigin
  // The node path the address opens, or null away from a node page.
  path: string | null
  suffix: string
  viewRev: number
}

// The node page at an address as it is on screen: the one state the node
// route renders and a send names (lib/viewing.ts). Loading again whenever
// the address changes, so nothing of the page left behind survives.
export function useShownNode(
  address: NodeAddress,
  groupFeed: GroupFeed,
): ShownPage | null {
  const { group, client, contentOrigin, path, suffix, viewRev } = address
  const loading = (): ShownPage | null =>
    path === null
      ? null
      : { group, requested: path, path, view: { state: 'loading' } }
  const [shown, setShown] = useState(loading)
  // The tree names a path's kind without a round trip; reading it through a
  // ref keeps every space mutation from reloading the page.
  const feed = useRef(groupFeed)
  feed.current = groupFeed
  const [active, setActive] = useState(address)
  if (
    active.group !== group ||
    active.client !== client ||
    active.contentOrigin !== contentOrigin ||
    active.path !== path ||
    active.suffix !== suffix ||
    active.viewRev !== viewRev
  ) {
    setActive(address)
    setShown(loading())
  }

  useEffect(() => {
    if (path === null) return
    let cancelled = false
    const apply = (next: ShownNode) => {
      if (!cancelled) setShown({ group, requested: path, ...next })
    }
    const kept: NodeSource = {
      stat: (at) => {
        if (!feed.current.loaded) {
          return Promise.reject(new Error('The kept tree is not loaded.'))
        }
        const kind = at === '/' ? 'directory' : feed.current.files.paths.get(at)
        return kind === undefined
          ? Promise.reject(
            new ApiError(404, {
              code: 'notFound',
              message: `${at} is not in the kept tree`,
            }),
          )
          : Promise.resolve({ kind })
      },
      read: (at) => client.keptRead(at),
    }
    const live: NodeSource = {
      stat: (at) => client.stat(at),
      read: (at) => client.read(at),
    }
    cachedThenLive(
      () => loadShownNode(kept, contentOrigin, path, suffix, viewRev),
      () => loadShownNode(live, contentOrigin, path, suffix, viewRev),
      apply,
      (failure) =>
        apply({
          path,
          view: { state: 'error', message: errorMessage(failure) },
        }),
    )
    return () => {
      cancelled = true
    }
  }, [group, client, contentOrigin, path, suffix, viewRev])

  return shown
}
