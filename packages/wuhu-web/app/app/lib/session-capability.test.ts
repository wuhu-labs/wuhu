import {
  canCompose,
  canManageSession,
  sessionActions,
  sessionCapability,
} from './session-capability.ts'
import { conversationCapability } from './use-conversation-access.ts'

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

Deno.test('only a known live agent box or authorized conversation takes input', () => {
  const agent = sessionCapability({ kind: 'agent', lifecycle: 'live' })
  const task = sessionCapability({ kind: 'task', lifecycle: 'live' })
  const archived = sessionCapability({ kind: 'agent', lifecycle: 'archived' })
  equal([agent.kind, task.kind, archived.kind, sessionCapability(null).kind], [
    'agent',
    'task',
    'archived',
    'unknown',
  ])
  equal([agent, task, archived, sessionCapability(null)].map(canCompose), [
    true,
    false,
    false,
    false,
  ])
  equal(
    [agent, task, archived, sessionCapability(null)].map(canManageSession),
    [true, true, false, false],
  )
})

Deno.test('conversation access waits for membership and roster, and excludes tasks', () => {
  const agent = { id: 'a', kind: 'agent' as const, lifecycle: 'live' }
  const task = { id: 't', kind: 'task' as const, lifecycle: 'live' }
  const roster = [agent, task] as Parameters<typeof conversationCapability>[1]
  const members = [{ member: 'owner', kind: 'user' }, {
    member: 'a',
    kind: 'session',
  }]
  equal(canCompose(conversationCapability(null, roster)), false)
  equal(canCompose(conversationCapability(members, null)), false)
  equal(canCompose(conversationCapability(members, roster)), true)
  equal(
    canCompose(
      conversationCapability(
        [...members, { member: 't', kind: 'session' }],
        roster,
      ),
    ),
    false,
  )
  equal(
    canCompose(
      conversationCapability([...members, {
        member: 'missing',
        kind: 'session',
      }], roster),
    ),
    false,
  )
})

Deno.test('the session menu offers lifecycle actions by capability', () => {
  const agent = sessionCapability({ kind: 'agent', lifecycle: 'live' })
  const task = sessionCapability({ kind: 'task', lifecycle: 'live' })
  const archived = sessionCapability({ kind: 'task', lifecycle: 'archived' })
  const unknown = sessionCapability(null)
  equal(sessionActions(agent), ['compact', 'restart', 'archive'])
  equal(sessionActions(task), ['compact', 'restart', 'archive'])
  equal(sessionActions(archived), ['unarchive'])
  equal(sessionActions(unknown), [])
  equal(sessionActions({ kind: 'conversation', allowed: true }), [])
})
