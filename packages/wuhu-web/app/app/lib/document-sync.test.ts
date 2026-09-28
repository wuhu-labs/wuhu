import type { SyncOutput } from './contract.gen.ts'
import {
  applySync,
  documentState,
  editDocument,
  keepLocal,
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
  assertEquals(
    useRemote(conflict),
    documentState({
      token: '2',
      content: 'remote\n',
    }),
  )
  assertEquals(keepLocal(conflict), {
    base: { token: '2', content: 'remote\n' },
    draft: 'local\n',
    phase: 'dirty',
  })
})
