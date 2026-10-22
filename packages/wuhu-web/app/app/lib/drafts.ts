// What the composer holds for each target, kept in this browser for a week so
// a reload or a trip elsewhere never loses it. With two tabs the last write
// wins.
interface StoredDraft {
  text: string
  savedAt: number
}

export const draftLifetimeMs = 7 * 24 * 60 * 60 * 1000

const shelfPrefix = 'wuhu.draft:'

// A draft belongs to one account in one space, aimed at one target.
export function draftKey(scope: string, target: string): string {
  return `${shelfPrefix}${scope}/${target}`
}

export function withDictation(text: string, spoken: string): string {
  const words = spoken.trim()
  if (words === '') return text
  const held = text.trimEnd()
  return held === '' ? words : `${held} ${words}`
}

// Puts a failed send back in front of whatever was written while it was out.
export function restoreDraft(outgoing: string, meanwhile: string): string {
  return meanwhile === '' ? outgoing : `${outgoing.trimEnd()}\n${meanwhile}`
}

export class Drafts {
  private readonly drafts = new Map<string, string>()
  private readonly listeners = new Set<() => void>()

  constructor(
    private readonly scope: string,
    private readonly shelf: Storage,
    private readonly now: () => number,
  ) {}

  subscribe = (listener: () => void): () => void => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  get(target: string): string {
    const known = this.drafts.get(target)
    if (known !== undefined) return known
    const text = this.fresh(draftKey(this.scope, target))?.text ?? ''
    this.drafts.set(target, text)
    return text
  }

  set(target: string, text: string): void {
    if (text === this.get(target)) return
    this.drafts.set(target, text)
    const key = draftKey(this.scope, target)
    if (text === '') this.shelf.removeItem(key)
    else {
      this.shelf.setItem(
        key,
        JSON.stringify({ text, savedAt: this.now() } satisfies StoredDraft),
      )
    }
    for (const listener of this.listeners) listener()
  }

  // Empties the draft and hands back what it held.
  take(target: string): string {
    const text = this.get(target)
    this.set(target, '')
    return text
  }

  // Drops every expired draft this browser holds, whatever its scope.
  sweep(): void {
    const stale: string[] = []
    for (let index = 0; index < this.shelf.length; index += 1) {
      const key = this.shelf.key(index)
      if (key?.startsWith(shelfPrefix) && this.fresh(key) === null) {
        stale.push(key)
      }
    }
    for (const key of stale) this.shelf.removeItem(key)
  }

  private fresh(key: string): StoredDraft | null {
    const raw = this.shelf.getItem(key)
    if (raw === null) return null
    const stored = JSON.parse(raw) as StoredDraft
    return this.now() - stored.savedAt > draftLifetimeMs ? null : stored
  }
}
