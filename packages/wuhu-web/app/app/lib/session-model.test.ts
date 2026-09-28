import { lookupSession } from './session-model.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const roster = [{ id: 'scout' }]

Deno.test('a session in the roster is found', () => {
  equal(lookupSession(roster, 'scout', false), {
    kind: 'found',
    record: { id: 'scout' },
  })
})

Deno.test('every id is loading until the roster arrives', () => {
  equal(lookupSession(null, 'scout', false), { kind: 'loading' })
  equal(lookupSession(null, 'fresh', true), { kind: 'loading' })
})

Deno.test('an id this tab just created stays loading until the roster lists it', () => {
  equal(lookupSession(roster, 'fresh', true), { kind: 'loading' })
})

Deno.test('any other id missing from the loaded roster is not found', () => {
  equal(lookupSession(roster, 'nobody', false), { kind: 'missing' })
})
