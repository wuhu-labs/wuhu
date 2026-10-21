import { useEffect, useState } from 'react'
import { observeProjection } from '~/sdk/observation'
import { loadShownNode, type ShownNode } from './node-view.ts'
import type { ContentOrigin } from './use-content-origin.ts'
import type { ShownPage } from './viewing.ts'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'

export interface NodeAddress {
  group: string
  client: SpaceClient
  contentOrigin: ContentOrigin
  // The node path the address opens, or null away from a node page.
  path: string | null
  suffix: string
}

// The node page at an address as it is on screen: the one state the node
// route renders and a send names (lib/viewing.ts). Loading again whenever
// the address changes, so nothing of the page left behind survives.
export function useShownNode(
  address: NodeAddress,
): ShownPage | null {
  const { group, client, contentOrigin, path, suffix } = address
  const loading = (): ShownPage | null =>
    path === null
      ? null
      : { group, requested: path, path, view: { state: 'loading' } }
  const [shown, setShown] = useState(loading)
  const [active, setActive] = useState(address)
  if (
    active.group !== group ||
    active.client !== client ||
    active.contentOrigin !== contentOrigin ||
    active.path !== path ||
    active.suffix !== suffix
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
    const observation = observeProjection((get) =>
      loadShownNode(
        {
          stat: (at) => get(`stat:${at}`, client.stat(at)),
          read: (at) => get(`read:${at}`, client.read(at)),
        },
        contentOrigin,
        path,
        suffix,
      )
    )
    const stop = observation(
      apply,
      (failure) =>
        apply({
          path,
          view: { state: 'error', message: errorMessage(failure) },
        }),
    )
    return () => {
      cancelled = true
      stop()
    }
  }, [group, client, contentOrigin, path, suffix])

  return shown
}
