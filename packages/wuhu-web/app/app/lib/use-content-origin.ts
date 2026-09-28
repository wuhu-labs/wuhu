import { useEffect, useState } from 'react'
import type { SpaceClient } from '~/sdk/client'

// Undefined until the read cookie is minted, null for a serve with no
// content origin, an Error when the origin refused to mint one.
export type ContentOrigin = string | null | Error | undefined

export function contentOriginString(origin: ContentOrigin): string | null {
  return typeof origin === 'string' ? origin : null
}

export function useContentOrigin(client: SpaceClient): ContentOrigin {
  const [origin, setOrigin] = useState<
    { client: SpaceClient; origin: ContentOrigin }
  >({ client, origin: undefined })
  useEffect(() => {
    let cancelled = false
    const settle = (minting: Promise<string | null>) =>
      minting.then(
        (resolved) => {
          if (!cancelled) setOrigin({ client, origin: resolved })
        },
        (failure: unknown) => {
          if (!cancelled) {
            setOrigin({
              client,
              origin: failure instanceof Error
                ? failure
                : new Error(String(failure)),
            })
          }
        },
      )
    void settle(client.contentOrigin())
    // Back online, a fresh read cookie lets the pages' own reconnects go live.
    const online = () => void settle(client.remintContentSession())
    addEventListener('online', online)
    return () => {
      cancelled = true
      removeEventListener('online', online)
    }
  }, [client])
  return origin.client === client ? origin.origin : undefined
}
