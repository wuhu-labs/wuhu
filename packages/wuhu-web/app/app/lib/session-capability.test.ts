import { sessionPresentation } from './session-model.ts'
import { canCompose, sessionCapability } from './session-capability.ts'
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
})

Deno.test('conversation access waits for membership and roster, and excludes tasks', () => {
  const agent = { id: 'a', kind: 'agent' as const, lifecycle: 'live' }
  const task = { id: 't', kind: 'task' as const, lifecycle: 'live' }
  const roster = [agent, { ...agent, id: 'b' }, task] as Parameters<
    typeof conversationCapability
  >[1]
  const members = [{ member: 'b', kind: 'session' }, {
    member: 'a',
    kind: 'session',
  }]
  equal(canCompose(conversationCapability(null, roster)), false)
  equal(
    canCompose(conversationCapability({ kind: 'dm_session', members }, null)),
    false,
  )
  equal(
    canCompose(conversationCapability({ kind: 'dm_session', members }, roster)),
    true,
  )
  equal(
    canCompose(
      conversationCapability(
        {
          kind: 'dm_session',
          members: [...members, { member: 't', kind: 'session' }],
        },
        roster,
      ),
    ),
    false,
  )
  equal(
    canCompose(
      conversationCapability({
        kind: 'dm_session',
        members: [...members, {
          member: 'missing',
          kind: 'session',
        }],
      }, roster),
    ),
    false,
  )
})

Deno.test('session route presentation opens tasks directly and agents only on their transcript journey', () => {
  equal(sessionPresentation('task', null), 'transcript')
  equal(sessionPresentation('task', 'transcript'), 'transcript')
  equal(sessionPresentation('agent', null), 'chat')
  equal(sessionPresentation('agent', 'transcript'), 'transcript')
  equal(sessionPresentation('agent', 'unknown'), 'chat')
})
