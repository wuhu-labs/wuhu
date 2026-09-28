import {
  type Draft,
  type DraftFile,
  draftKey,
  draftLifetimeMs,
  Drafts,
  emptyDraft,
  type FileVault,
  restoreDraft,
  withDictation,
} from './drafts.ts'

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

class MemoryShelf implements Storage {
  readonly items = new Map<string, string>()
  get length() {
    return this.items.size
  }
  clear() {
    this.items.clear()
  }
  getItem(key: string) {
    return this.items.get(key) ?? null
  }
  key(index: number) {
    return [...this.items.keys()][index] ?? null
  }
  removeItem(key: string) {
    this.items.delete(key)
  }
  setItem(key: string, value: string) {
    this.items.set(key, value)
  }
}

class MemoryVault implements FileVault {
  readonly records = new Map<string, DraftFile[]>()
  failing = false
  private done<T>(value: T): Promise<T> {
    return this.failing
      ? Promise.reject(new Error('quota'))
      : Promise.resolve(value)
  }
  read(key: string) {
    return this.done(this.records.get(key))
  }
  write(key: string, files: DraftFile[]) {
    if (!this.failing) this.records.set(key, files)
    return this.done(undefined)
  }
  remove(key: string) {
    if (!this.failing) this.records.delete(key)
    return this.done(undefined)
  }
  sweep(keep: (key: string) => boolean) {
    for (const key of this.records.keys()) {
      if (!keep(key)) this.records.delete(key)
    }
    return Promise.resolve()
  }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
const reply = { messageId: 'm1', sender: 'Joke teller', text: 'why?' }
const held = (id: string, name: string) => ({
  id,
  file: new File(['png'], name, { type: 'image/png' }),
})
const photo = held('f1', 'photo.png')
const later = held('f2', 'later.png')
const day = 24 * 60 * 60 * 1000

function shape(draft: Draft) {
  return {
    text: draft.text,
    reply: draft.reply,
    files: draft.files.map((file) => file.file.name),
  }
}

function names(vault: MemoryVault, key: string) {
  return (vault.records.get(key) ?? []).map((file) => file.file.name)
}

Deno.test('drafts are keyed by account, space and target', () => {
  equal(draftKey('ac_1:spc_1', 'session:a'), 'wuhu.draft:ac_1:spc_1/session:a')
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  const mine = new Drafts('ac_1:spc_1', shelf, vault, () => 0)
  mine.update('session:a', (draft) => ({ ...draft, text: 'for a' }))
  equal(mine.get('session:b').text, '')
  equal(
    new Drafts('ac_2:spc_1', shelf, vault, () => 0).get('session:a').text,
    '',
  )
  equal(
    new Drafts('ac_1:spc_2', shelf, vault, () => 0).get('session:a').text,
    '',
  )
  equal(
    new Drafts('ac_1:spc_1', shelf, vault, () => 0).get('session:a').text,
    'for a',
  )
})

Deno.test('text, reply and files come back after a reload', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  const before = new Drafts('s', shelf, vault, () => 10)
  before.update(
    'session:a',
    (draft) => ({ ...draft, text: 'hi', reply, files: [photo] }),
  )
  await settle()
  const after = new Drafts('s', shelf, vault, () => 20)
  equal(shape(after.get('session:a')), { text: 'hi', reply, files: [] })
  await settle()
  equal(shape(after.get('session:a')), {
    text: 'hi',
    reply,
    files: ['photo.png'],
  })
})

Deno.test('a file-only draft comes back after a reload', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  new Drafts('s', shelf, vault, () => 0).update(
    'session:a',
    (draft) => ({ ...draft, files: [photo] }),
  )
  const after = new Drafts('s', shelf, vault, () => 0)
  after.get('session:a')
  await settle()
  equal(shape(after.get('session:a')).files, ['photo.png'])
})

Deno.test('editing one part keeps the whole draft alive', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  let now = 0
  const drafts = new Drafts('s', shelf, vault, () => now)
  drafts.update('session:a', (draft) => ({ ...draft, files: [photo] }))
  now = 6 * day
  drafts.update('session:a', (draft) => ({ ...draft, text: 'still here' }))
  now = 12 * day
  const after = new Drafts('s', shelf, vault, () => now)
  after.get('session:a')
  await settle()
  equal(shape(after.get('session:a')), {
    text: 'still here',
    reply: null,
    files: ['photo.png'],
  })
  await after.sweep()
  equal(names(vault, draftKey('s', 'session:a')), ['photo.png'])
})

Deno.test('a file added before the stored files load joins them', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  new Drafts('s', shelf, vault, () => 0).update(
    'session:a',
    (draft) => ({ ...draft, text: 'hi', files: [photo] }),
  )
  const drafts = new Drafts('s', shelf, vault, () => 0)
  drafts.get('session:a')
  drafts.update(
    'session:a',
    (draft) => ({ ...draft, files: [...draft.files, later] }),
  )
  await settle()
  equal(shape(drafts.get('session:a')).files, ['photo.png', 'later.png'])
  equal(names(vault, draftKey('s', 'session:a')), ['photo.png', 'later.png'])
})

Deno.test('clearing a draft removes both parts, even before its files load', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  new Drafts('s', shelf, vault, () => 0).update(
    'session:a',
    (draft) => ({ ...draft, text: 'hi', reply, files: [photo] }),
  )
  const drafts = new Drafts('s', shelf, vault, () => 0)
  drafts.get('session:a')
  drafts.clear('session:a')
  await settle()
  equal(shelf.items.size, 0)
  equal(vault.records.size, 0)
  equal(shape(drafts.get('session:a')), { text: '', reply: null, files: [] })

  vault.records.set(draftKey('s', 'session:b'), [photo])
  new Drafts('s', shelf, vault, () => 0).clear('session:b')
  await settle()
  equal(vault.records.size, 0)
})

Deno.test('a draft older than seven days is dropped with its files', async () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  let now = 0
  const drafts = new Drafts('s', shelf, vault, () => now)
  drafts.update(
    'session:old',
    (draft) => ({ ...draft, text: 'old', files: [photo] }),
  )
  now = draftLifetimeMs
  drafts.update(
    'session:new',
    (draft) => ({ ...draft, text: 'new', files: [photo] }),
  )
  vault.records.set(draftKey('s', 'session:orphan'), [photo])
  shelf.setItem('unrelated', 'kept')
  now = draftLifetimeMs + 1
  equal(new Drafts('s', shelf, vault, () => now).get('session:old').text, '')
  await drafts.sweep()
  equal([...shelf.items.keys()], [draftKey('s', 'session:new'), 'unrelated'])
  equal([...vault.records.keys()], [draftKey('s', 'session:new')])
})

Deno.test('the last write from either tab wins', () => {
  const shelf = new MemoryShelf()
  const vault = new MemoryVault()
  const left = new Drafts('s', shelf, vault, () => 0)
  const right = new Drafts('s', shelf, vault, () => 0)
  left.update('session:a', (draft) => ({ ...draft, text: 'left' }))
  right.update('session:a', (draft) => ({ ...draft, text: 'right' }))
  equal(new Drafts('s', shelf, vault, () => 0).get('session:a').text, 'right')
})

Deno.test('a vault that fails is counted, and the draft stays in memory', async () => {
  const vault = new MemoryVault()
  vault.failing = true
  const drafts = new Drafts('s', new MemoryShelf(), vault, () => 0)
  drafts.update('session:a', (draft) => ({ ...draft, files: [photo] }))
  await settle()
  equal(drafts.vaultFailures, 1)
  equal(shape(drafts.get('session:a')).files, ['photo.png'])
})

Deno.test('a failed send goes back in front of what was written meanwhile', () => {
  const outgoing = { text: 'first', reply, files: [photo] }
  equal(restoreDraft(outgoing, emptyDraft), outgoing)
  equal(
    shape(
      restoreDraft(outgoing, { text: 'second', reply: null, files: [later] }),
    ),
    { text: 'first\nsecond', reply, files: ['photo.png', 'later.png'] },
  )
})

Deno.test('dictation appends to the draft with one space', () => {
  const draft = { text: 'ship it ', reply: null, files: [] }
  equal(withDictation(draft, ' after review ').text, 'ship it after review')
  equal(withDictation({ ...draft, text: '' }, 'hello').text, 'hello')
  equal(withDictation(draft, '  '), draft)
})
