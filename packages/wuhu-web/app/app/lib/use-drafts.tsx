import {
  createContext,
  type ReactNode,
  useContext,
  useEffect,
  useState,
  useSyncExternalStore,
} from 'react'
import { type Draft, Drafts } from './drafts.ts'
import { indexedDBVault } from './draft-vault.ts'

const DraftsContext = createContext<Drafts | null>(null)

// An unenrolled browser has no account to keep drafts for, and no composer.
export function DraftsProvider(
  { scope, children }: { scope: string | null; children: ReactNode },
) {
  const [drafts] = useState(() =>
    scope === null
      ? null
      : new Drafts(scope, localStorage, indexedDBVault, Date.now)
  )
  useEffect(() => {
    void drafts?.sweep()
  }, [drafts])
  return <DraftsContext value={drafts}>{children}</DraftsContext>
}

export function useDrafts(): Drafts | null {
  return useContext(DraftsContext)
}

export function useDraft(drafts: Drafts, target: string): Draft {
  return useSyncExternalStore(drafts.subscribe, () => drafts.get(target))
}
