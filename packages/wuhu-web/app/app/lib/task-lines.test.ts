import { assertEquals } from 'jsr:@std/assert@1'
import { taskLines } from './task-lines.ts'
import type { WorkEvent } from './work-events.ts'

const at = new Date(2026, 9, 22, 9, 0)
let position = 0
const event = (body: Partial<WorkEvent> & Pick<WorkEvent, 'kind'>) =>
  ({
    id: { kind: 'kernel', generation: 0, position: position++, part: 0 },
    timestamp: at,
    stopReason: null,
    ...body,
  }) as WorkEvent

Deno.test('a task reads as its brief, then what it said and reported', () => {
  const lines = taskLines([
    event({
      kind: 'input',
      input: {
        sender: 'parent',
        text: 'Fix the bug',
        conversation: null,
        messageID: null,
        replyTarget: null,
        attachments: [],
        kind: 'message',
        senderSession: 'parent',
      },
    }),
    event({ kind: 'reasoning', summary: 'thinking' }),
    event({
      kind: 'toolCall',
      call: { callID: '1', name: 'exec', arguments: { command: 'ls' } },
    }),
    event({ kind: 'assistantText', text: 'On it.', streaming: false }),
    event({
      kind: 'toolCall',
      call: { callID: '2', name: 'report', arguments: { content: 'Done.' } },
    }),
  ])
  assertEquals(
    lines.map((line) => [line.own, line.text]),
    [[true, 'Fix the bug'], [false, 'On it.'], [false, 'Done.']],
  )
})
