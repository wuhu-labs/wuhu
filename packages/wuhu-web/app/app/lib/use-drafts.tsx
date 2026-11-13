import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useState,
  useSyncExternalStore,
} from 'react'
import { Drafts } from './drafts.ts'

const DraftsContext = createContext<Drafts | null>(null)

// A browser the server seats as nobody has no drafts and no composer.
export function DraftsProvider(
  { scope, children }: { scope: string | null; children: ReactNode },
) {
  const [drafts] = useState(() =>
    scope === null ? null : new Drafts(scope, localStorage, Date.now)
  )
  useEffect(() => drafts?.sweep(), [drafts])
  return <DraftsContext value={drafts}>{children}</DraftsContext>
}

export function useDrafts(): Drafts | null {
  return useContext(DraftsContext)
}

export function useDraft(drafts: Drafts, target: string): string {
  return useSyncExternalStore(drafts.subscribe, () => drafts.get(target))
}
