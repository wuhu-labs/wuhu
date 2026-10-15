import type { SyncOutput } from './contract.gen.ts'
import {
  applySync,
  documentState,
  editDocument,
  keepLocal,
  remoteDocument,
  useRemote,
} from './document-sync.ts'

const original = { token: '1', content: 'one\ntwo\n' }

function assertEquals<T>(actual: T, expected: T): void {
  const renderedActual = JSON.stringify(actual)
  const renderedExpected = JSON.stringify(expected)
  if (renderedActual !== renderedExpected) {
    throw new Error(`expected ${renderedExpected}, got ${renderedActual}`)
  }
}

Deno.test('a completed save advances the document baseline', () => {
  const dirty = editDocument(documentState(original), 'ONE\ntwo\n')
  const output: SyncOutput = {
    kind: 'saved',
    rev: 2,
    token: '2',
    content: 'ONE\ntwo\n',
  }
  assertEquals(applySync(dirty, dirty.draft, output), {
    base: { token: '2', content: 'ONE\ntwo\n' },
    draft: 'ONE\ntwo\n',
    phase: 'clean',
    revision: 0,
  })
})

Deno.test('typing during an ordinary save remains dirty on the new baseline', () => {
  const saving = editDocument(documentState(original), 'ONE\ntwo\n')
  const newer = editDocument(saving, 'ONE\nTWO\n')
  const output: SyncOutput = {
    kind: 'saved',
    rev: 2,
    token: '2',
    content: saving.draft,
  }
  assertEquals(applySync(newer, saving.draft, output), {
    base: { token: '2', content: saving.draft },
    draft: newer.draft,
    phase: 'dirty',
    revision: 0,
  })
})

Deno.test('a concurrent merge while more typing occurs preserves both versions', () => {
  const saving = editDocument(documentState(original), 'one\nTWO\n')
  const newer = editDocument(saving, 'one\nTWO!\n')
  const output: SyncOutput = {
    kind: 'merged',
    rev: 3,
    token: '3',
    content: 'ONE\nTWO\n',
  }
  const conflicted = applySync(newer, saving.draft, output)
  assertEquals(conflicted.phase, 'conflict')
  assertEquals(conflicted.draft, 'one\nTWO!\n')
  assertEquals(conflicted.remote, { token: '3', content: 'ONE\nTWO\n' })
})

Deno.test('conflicts can explicitly choose either side', () => {
  const dirty = editDocument(documentState(original), 'local\n')
  const conflict = applySync(dirty, dirty.draft, {
    kind: 'conflict',
    token: '2',
    content: 'remote\n',
  })
  assertEquals(useRemote(conflict), {
    ...documentState({ token: '2', content: 'remote\n' }),
    revision: 1,
  })
  assertEquals(keepLocal(conflict), {
    base: { token: '2', content: 'remote\n' },
    draft: 'local\n',
    phase: 'dirty',
    revision: 0,
  })
})

Deno.test('the revision moves only when text the editor did not write replaces the draft', () => {
  const dirty = editDocument(documentState(original), 'ONE\ntwo\n')
  assertEquals(dirty.revision, 0)

  const saved = applySync(dirty, dirty.draft, {
    kind: 'saved',
    rev: 2,
    token: '2',
    content: dirty.draft,
  })
  assertEquals(saved.revision, 0)

  const merged = applySync(dirty, dirty.draft, {
    kind: 'merged',
    rev: 3,
    token: '3',
    content: 'ONE\ntwo\nthree\n',
  })
  assertEquals(merged.draft, 'ONE\ntwo\nthree\n')
  assertEquals(merged.revision, 1)

  assertEquals(
    remoteDocument(saved, { token: '2', content: saved.draft }).revision,
    0,
  )
  assertEquals(
    remoteDocument(saved, { token: '4', content: 'other\n' }).revision,
    1,
  )

  const conflict = applySync(editDocument(saved, 'local\n'), 'local\n', {
    kind: 'conflict',
    token: '5',
    content: 'remote\n',
  })
  assertEquals(editDocument(conflict, 'local!\n').revision, 0)
  assertEquals(keepLocal(conflict).revision, 0)
  assertEquals(useRemote(conflict).revision, 1)
})
