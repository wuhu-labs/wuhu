import type { ReplyDraft } from './conversation.ts'
import { admitFiles } from './attachments.ts'
import { prepareAttachment } from './image-intake.ts'
import { errorMessage } from '../sdk/errors.ts'

export interface DraftFile {
  id: string
  file: File
}

export interface Draft {
  text: string
  reply: ReplyDraft | null
  files: readonly DraftFile[]
  preparing: boolean
  refusal: string | null
}

export const emptyDraft: Draft = {
  text: '',
  reply: null,
  files: [],
  preparing: false,
  refusal: null,
}

export interface FileVault {
  read(key: string): Promise<DraftFile[] | undefined>
  write(key: string, files: DraftFile[]): Promise<void>
  remove(key: string): Promise<void>
  sweep(keep: (key: string) => boolean): Promise<void>
}

// The one record every non-empty draft has; its `savedAt` dates the whole
// draft, files included, and is stamped on every edit.
interface StoredDraft {
  text: string
  reply: ReplyDraft | null
  savedAt: number
}

export const draftLifetimeMs = 7 * 24 * 60 * 60 * 1000

const shelfPrefix = 'wuhu.draft:'

// A draft belongs to one account in one space, aimed at one target.
export function draftKey(scope: string, target: string): string {
  return `${shelfPrefix}${scope}/${target}`
}

function isEmpty(draft: Draft): boolean {
  return draft.text === '' && draft.reply === null && draft.files.length === 0
}

export function withDictation(draft: Draft, spoken: string): Draft {
  const words = spoken.trim()
  if (words === '') return draft
  const held = draft.text.trimEnd()
  return { ...draft, text: held === '' ? words : `${held} ${words}` }
}

// Puts a failed send back in front of whatever was written while it was out.
export function restoreDraft(outgoing: Draft, meanwhile: Draft): Draft {
  return {
    ...meanwhile,
    text: meanwhile.text === ''
      ? outgoing.text
      : `${outgoing.text.trimEnd()}\n${meanwhile.text}`,
    reply: meanwhile.reply ?? outgoing.reply,
    files: [...outgoing.files, ...meanwhile.files],
  }
}

// Text and reply live in localStorage, files in the vault. Each edit rewrites
// the parts it touched whole, so with two tabs the last write wins.
export class Drafts {
  private readonly drafts = new Map<string, Draft>()
  private readonly savedAt = new Map<string, number>()
  private readonly loading = new Set<string>()
  private readonly preparing = new Map<string, Set<string>>()
  private readonly listeners = new Set<() => void>()
  private lostFiles = 0

  constructor(
    private readonly scope: string,
    private readonly shelf: Storage,
    private readonly vault: FileVault,
    private readonly now: () => number,
  ) {}

  subscribe = (listener: () => void): () => void => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  // Counts vault reads and writes that failed: files that won't survive a
  // reload.
  get vaultFailures(): number {
    return this.lostFiles
  }

  get(target: string): Draft {
    const known = this.drafts.get(target)
    if (known !== undefined) return known
    const key = draftKey(this.scope, target)
    const stored = this.fresh(key)
    this.savedAt.set(target, stored?.savedAt ?? this.now())
    const draft: Draft = stored === null ? emptyDraft : {
      ...emptyDraft,
      text: stored.text,
      reply: stored.reply,
      preparing: true,
    }
    this.drafts.set(target, draft)
    if (stored !== null) {
      this.loading.add(target)
      this.vault.read(key).then((files) => {
        if (!this.loading.delete(target)) return
        this.change(target, (current) => ({
          ...current,
          files: [...(files ?? []), ...current.files],
        }), false)
      }, () => {
        if (!this.loading.delete(target)) return
        this.vaultFailed()
        this.change(target, (current) => current, false)
      })
    }
    return draft
  }

  attach(target: string, incoming: readonly File[]): void {
    this.update(target, (current) => {
      const { admitted, refusal } = admitFiles(
        current.files.map((held) => held.file),
        incoming,
      )
      return {
        ...current,
        files: [
          ...current.files,
          ...admitted.map((file) => ({ id: crypto.randomUUID(), file })),
        ],
        refusal,
      }
    })
  }

  take(target: string): Draft | null {
    const draft = this.get(target)
    if (draft.preparing) return null
    this.clear(target)
    return draft
  }

  update(target: string, change: (draft: Draft) => Draft): void {
    this.change(target, change, true)
  }

  private change(
    target: string,
    change: (draft: Draft) => Draft,
    userEdit: boolean,
  ): void {
    const before = this.get(target)
    const after = change(before)
    if (
      userEdit &&
      (after.text !== before.text || after.reply !== before.reply ||
        after.files !== before.files)
    ) {
      this.savedAt.set(target, this.now())
    }
    const pending = this.preparing.get(target) ?? new Set<string>()
    for (const id of pending) {
      if (!after.files.some((held) => held.id === id)) pending.delete(id)
    }
    const added = after.files.filter((held) =>
      !before.files.some((old) => old.id === held.id && old.file === held.file)
    )
    for (const held of added) pending.add(held.id)
    this.preparing.set(target, pending)
    this.store(target, {
      ...after,
      preparing: this.loading.has(target) || pending.size > 0,
    })
    for (const held of added) void this.prepare(target, held, pending)
  }

  private async prepare(
    target: string,
    held: DraftFile,
    pending: Set<string>,
  ): Promise<void> {
    let file: File | null = null
    let refusal: string | null = null
    try {
      file = await prepareAttachment(held.file)
    } catch (error) {
      refusal = errorMessage(error)
    }
    if (this.preparing.get(target) !== pending || !pending.delete(held.id)) {
      return
    }
    const current = this.get(target)
    this.store(target, {
      ...current,
      files: file === held.file
        ? current.files
        : file === null
        ? current.files.filter((item) => item.id !== held.id)
        : current.files.map((item) =>
          item.id === held.id ? { ...item, file } : item
        ),
      refusal: [current.refusal, refusal].filter(Boolean).join(' ') || null,
      preparing: this.loading.has(target) || pending.size > 0,
    })
  }

  private store(target: string, after: Draft): void {
    const before = this.get(target)
    this.set(target, after)
    if (
      after.text === before.text && after.reply === before.reply &&
      after.files === before.files
    ) return
    const key = draftKey(this.scope, target)
    if (isEmpty(after)) {
      this.shelf.removeItem(key)
    } else {
      this.shelf.setItem(
        key,
        JSON.stringify(
          {
            text: after.text,
            reply: after.reply,
            savedAt: this.savedAt.get(target)!,
          } satisfies StoredDraft,
        ),
      )
    }
    if (after.files !== before.files) {
      const saved = after.files.length === 0
        ? this.vault.remove(key)
        : this.vault.write(key, [...after.files])
      saved.catch(() => this.vaultFailed())
    }
  }

  // Empties the draft in memory and in both stores, and drops a vault read
  // still under way so it cannot bring the files back.
  clear(target: string): void {
    const key = draftKey(this.scope, target)
    this.loading.delete(target)
    this.preparing.delete(target)
    this.savedAt.delete(target)
    this.set(target, emptyDraft)
    this.shelf.removeItem(key)
    this.vault.remove(key).catch(() => this.vaultFailed())
  }

  // Drops every expired draft this browser holds, whatever its scope, and
  // any vault record whose draft is gone.
  async sweep(): Promise<void> {
    const stale: string[] = []
    for (let index = 0; index < this.shelf.length; index += 1) {
      const key = this.shelf.key(index)
      if (key?.startsWith(shelfPrefix) && this.fresh(key) === null) {
        stale.push(key)
      }
    }
    for (const key of stale) this.shelf.removeItem(key)
    await this.vault.sweep((key) => this.fresh(key) !== null)
  }

  private set(target: string, draft: Draft): void {
    this.drafts.set(target, draft)
    this.emit()
  }

  private emit(): void {
    for (const listener of this.listeners) listener()
  }

  private vaultFailed(): void {
    this.lostFiles += 1
    this.emit()
  }

  private fresh(key: string): StoredDraft | null {
    const raw = this.shelf.getItem(key)
    if (raw === null) return null
    const stored = JSON.parse(raw) as StoredDraft
    return this.now() - stored.savedAt > draftLifetimeMs ? null : stored
  }
}
