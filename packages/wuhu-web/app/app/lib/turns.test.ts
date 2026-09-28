import { assert, assertEquals } from 'jsr:@std/assert@1'
import {
  activity,
  projectedTurns,
  projectTurns,
  type SendTarget,
  toolState,
  type Turn,
  turnDuration,
  type TurnLine,
  turnLines,
  type TurnProjection,
  turnSends,
  type TurnStep,
} from './turns.ts'
import type { WorkEvent, WorkEventBody } from './work-events.ts'

const epoch = Date.UTC(2001, 0, 1)

function event(
  n: number,
  body: WorkEventBody,
  { at, stop = null }: { at?: number; stop?: string | null } = {},
): WorkEvent {
  return {
    id: { kind: 'kernel', generation: 0, position: n, part: 0 },
    timestamp: new Date(epoch + (at ?? n) * 1000),
    stopReason: stop,
    ...body,
  }
}

function input(
  n: number,
  text = 'go',
  kind = 'message',
): WorkEvent {
  return event(n, {
    kind: 'input',
    input: {
      sender: 'you',
      text,
      conversation: null,
      messageID: null,
      replyTarget: null,
      attachments: [],
      kind,
      senderSession: null,
    },
  })
}

function notice(n: number, kind: string, at?: number): WorkEvent {
  return event(n, {
    kind: 'notification',
    notice: { kind, text: `${kind} fired`, conversations: [] },
  }, { at })
}

function call(
  n: number,
  id: string,
  name = 'read',
  args: unknown = { path: '/x' },
): WorkEvent {
  return event(n, {
    kind: 'toolCall',
    call: { callID: id, name, arguments: args },
  }, { stop: 'stop' })
}

function send(
  n: number,
  id: string,
  name = 'send_message',
  args: unknown = { message: 'on it' },
): WorkEvent {
  return call(n, id, name, args)
}

function settled(n: number, id: string, failed = false): WorkEvent {
  return event(n, {
    kind: 'toolResult',
    result: {
      callID: id,
      kind: failed ? 'failure' : 'read',
      failed,
      output: 'ok',
    },
  })
}

function text(n: number, body: string): WorkEvent {
  return event(n, { kind: 'assistantText', text: body, streaming: false }, {
    stop: 'stop',
  })
}

// Claude Code's closing entry after a send carries no text.
function stopped(n: number): WorkEvent {
  return event(n, { kind: 'assistantText', text: '', streaming: false }, {
    stop: 'stop',
  })
}

function head(n: number, summary: string, note: string | null = null) {
  return event(n, { kind: 'generationHead', head: { summary, note } })
}

function streaming(body: string): WorkEvent {
  return {
    id: { kind: 'stream', attempt: 'att' },
    timestamp: null,
    stopReason: null,
    kind: 'assistantText',
    text: body,
    streaming: true,
  }
}

function stepShape(step: TurnStep): string {
  const content = step.content
  switch (content.kind) {
    case 'text':
      return content.streaming ? 'streaming' : 'text'
    case 'reasoning':
      return 'reasoning'
    case 'tool':
      return `tool:${content.tool.callID}`
    case 'send':
      return `send:${content.tool.callID}`
    case 'notice':
      return `notice:${content.notice.kind}`
    case 'bookmark':
      return 'bookmark'
    case 'orphanResult':
      return 'orphan'
  }
}

function shape(projection: TurnProjection): string[] {
  return projection.items.map((item) => {
    if (item.kind === 'divider') return 'divider'
    const turn = item.turn
    const heading = turn.wakes.map((wake) =>
      wake.source.kind === 'input'
        ? wake.source.input.kind === 'message'
          ? 'input'
          : wake.source.input.kind
        : wake.source.notice.kind
    )
    if (turn.continued) heading.push('continued')
    return [heading.join('+'), ...turn.steps.map(stepShape)].join(' ')
  })
}

function run(events: WorkEvent[], working = true): string[] {
  return shape(projectTurns(events, working))
}

function lineShape(lines: TurnLine[]): string[] {
  return lines.map((line) => {
    switch (line.kind) {
      case 'wake':
        return 'wake'
      case 'continued':
        return 'continued'
      case 'summary':
        return `summary:${line.tools}`
      case 'step':
        return stepShape(line.step)
      case 'fold':
        return `fold:${line.tools.length}`
      case 'fallback':
        return 'fallback'
    }
  })
}

function turn(events: WorkEvent[], index = 0): Turn {
  const found = projectedTurns(projectTurns(events, false))[index]
  assert(found !== undefined, `no turn ${index}`)
  return found
}

Deno.test('a message opens a turn that holds its work', () => {
  assertEquals(
    run([
      input(0),
      text(1, 'looking'),
      call(2, 'c1'),
      settled(3, 'c1'),
      text(4, 'done'),
    ]),
    ['input text tool:c1 text'],
  )
})

Deno.test('a timer, a notification and a report each open their own turn', () => {
  const events = [
    input(0),
    text(1, 'done'),
    notice(2, 'timer'),
    text(3, 'cleaned'),
    notice(4, 'spaceObservation'),
    text(5, 'noted'),
    input(6, 'halfway', 'progress'),
    text(7, 'passing it on'),
  ]
  assertEquals(run(events), [
    'input text',
    'timer text',
    'spaceObservation text',
    'progress text',
  ])
})

Deno.test('wake-ups with no output between them share a turn', () => {
  assertEquals(
    run([notice(0, 'timer'), input(1), notice(2, 'script'), text(3, 'both')]),
    ['timer+input+script text'],
  )
})

Deno.test('a notification mid-turn stays inline', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    notice(3, 'context'),
    call(4, 'c2'),
  ]
  assertEquals(run(events), ['input tool:c1 notice:context tool:c2'])
})

Deno.test('a notification after an entry that stopped opens its own turn', () => {
  const events = [
    input(0),
    send(1, 'c1'),
    settled(2, 'c1'),
    stopped(3),
    notice(4, 'timer', 33),
    text(5, 'on it'),
  ]
  assertEquals(run(events), ['input send:c1', 'timer text'])
})

Deno.test('a tool stop keeps the turn going', () => {
  const toolStop = event(1, {
    kind: 'toolCall',
    call: { callID: 'c1', name: 'read', arguments: {} },
  }, { stop: 'tool_use' })
  assertEquals(
    run([input(0), toolStop, notice(2, 'context'), call(3, 'c2')]),
    ['input tool:c1 notice:context tool:c2'],
  )
})

Deno.test('a message mid-turn opens a new turn', () => {
  assertEquals(
    run([input(0), call(1, 'c1'), input(2, 'and also'), call(3, 'c2')]),
    ['input tool:c1', 'input tool:c2'],
  )
})

Deno.test('a compaction mid-turn continues after the divider', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    head(3, 'so far'),
    call(4, 'c2'),
    text(5, 'done'),
  ]
  assertEquals(run(events), [
    'input tool:c1',
    'divider',
    'continued tool:c2 text',
  ])
})

Deno.test('a notification after a compaction opens its own turn', () => {
  assertEquals(
    run([head(0, 'so far'), notice(1, 'timer'), text(2, 'done')]),
    ['divider', 'timer text'],
  )
})

Deno.test('a compaction between turns leaves the next wake-up its own header', () => {
  assertEquals(run([head(0, 'so far'), input(1), text(2, 'hi')]), [
    'divider',
    'input text',
  ])
})

Deno.test('starting over stacks a Started over wake-up with the opening one and an empty head is dropped', () => {
  assertEquals(
    run([head(0, '', 'Started over by Morgan'), input(1), text(2, 'fresh')]),
    ['restart+input text'],
  )
  assertEquals(run([head(0, ''), input(1), text(2, 'fresh')]), ['input text'])
})

Deno.test('an empty streaming placeholder is working and gets no row', () => {
  const projection = projectTurns([input(0), streaming('')], false)
  assertEquals(shape(projection), ['input'])
  assert(projection.isWorking)
  assertEquals(run([input(0), streaming('still writ')], false), [
    'input streaming',
  ])
})

Deno.test('sends and reports in either naming are outgoing', () => {
  const events = [
    input(0),
    send(1, 'c1'),
    send(2, 'c2', 'mcp__wuhu__send_message', {
      message: 'hi',
      session: 'se_2',
    }),
    send(3, 'c3', 'mcp__wuhu__report', {
      request_id: 'rq',
      kind: 'progress',
      content: 'half',
    }),
    send(4, 'c4', 'report', {
      request_id: 'rq',
      kind: 'final',
      content: 'done',
    }),
    send(5, 'c5', 'send_message', { message: 'all', conversation: 'cv_team' }),
  ]
  const targets = turnSends(turn(events)).flatMap((step): SendTarget[] =>
    step.content.kind === 'send' ? [step.content.outgoing.target] : []
  )
  assertEquals(targets, [
    { kind: 'box' },
    { kind: 'session', id: 'se_2' },
    { kind: 'report', report: 'progress' },
    { kind: 'report', report: 'final' },
    { kind: 'conversation', id: 'cv_team' },
  ])
})

Deno.test('a folded turn stacks its wake, tool line and sends', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    send(3, 'c2'),
    settled(4, 'c2'),
    text(125, 'sent'),
  ]
  const folded = turn(events)
  assertEquals(lineShape(turnLines(folded, true, false)), [
    'wake',
    'summary:1',
    'send:c2',
  ])
  assertEquals(turnDuration(folded), 125)
})

Deno.test('a folded turn with nothing sent falls back to its last text', () => {
  const folded = turn([
    input(0, 'go', 'progress'),
    text(1, 'first'),
    text(2, 'passing it on'),
  ])
  const lines = turnLines(folded, true, false)
  assertEquals(lineShape(lines), ['wake', 'summary:0', 'fallback'])
  const last = lines.at(-1)
  assertEquals(last?.kind === 'fallback' ? last.text : null, 'passing it on')
})

Deno.test('a failed send still shows marked failed', () => {
  const folded = turn([
    input(0),
    send(1, 'c1'),
    settled(2, 'c1', true),
    text(3, 'hmm'),
  ])
  const sent = turnSends(folded)[0]?.content
  assertEquals(sent?.kind === 'send' ? toolState(sent.tool) : null, 'failed')
  assertEquals(lineShape(turnLines(folded, true, false)), [
    'wake',
    'summary:0',
    'send:c1',
  ])
})

Deno.test('an expanded closed turn shows its chronology under the tool line', () => {
  const events = [
    input(0),
    event(1, { kind: 'reasoning', summary: 'hmm' }),
    send(2, 'c1'),
    call(3, 'c2'),
    text(4, 'done'),
  ]
  const closed = turn(events)
  assertEquals(lineShape(turnLines(closed, true, true)), [
    'wake',
    'summary:1',
    'reasoning',
    'send:c1',
    'tool:c2',
    'text',
  ])
  assertEquals(lineShape(turnLines(closed, false, false)), [
    'wake',
    'reasoning',
    'send:c1',
    'tool:c2',
    'text',
  ])
})

Deno.test('three or more tools in a row fold and the last stays visible', () => {
  const events = [
    input(0),
    text(1, 'looking'),
    call(2, 'read'),
    call(3, 'grep1'),
    call(4, 'grep2'),
    call(5, 'read2'),
    call(6, 'edit'),
    settled(7, 'read'),
    settled(8, 'grep1'),
    settled(9, 'grep2'),
    settled(10, 'read2'),
    settled(11, 'edit'),
    text(12, 'done'),
  ]
  assertEquals(lineShape(turnLines(turn(events), false, false)), [
    'wake',
    'text',
    'fold:4',
    'tool:edit',
    'text',
  ])
})

Deno.test('two tools in a row stay unfolded', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    call(2, 'c2'),
    text(3, 'then'),
    call(4, 'c3'),
  ]
  assertEquals(lineShape(turnLines(turn(events), false, false)), [
    'wake',
    'tool:c1',
    'tool:c2',
    'text',
    'tool:c3',
  ])
})

Deno.test('a send ends a run and notices keep their place', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    call(2, 'c2'),
    send(3, 's1'),
    call(4, 'c3'),
    call(5, 'c4'),
    call(6, 'c5'),
    settled(7, 'c3'),
    settled(8, 'c4'),
    settled(9, 'c5'),
    call(10, 'c6'),
    settled(11, 'c6'),
    notice(12, 'context'),
    call(13, 'c7'),
  ]
  assertEquals(lineShape(turnLines(turn(events), false, false)), [
    'wake',
    'tool:c1',
    'tool:c2',
    'send:s1',
    'fold:4',
    'notice:context',
    'tool:c7',
  ])
})

Deno.test('a running tool stays visible below the fold', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    call(3, 'c2'),
    call(4, 'c3'),
    settled(5, 'c3'),
    call(6, 'c4'),
    settled(7, 'c4'),
  ]
  assertEquals(lineShape(turnLines(turn(events), false, false)), [
    'wake',
    'fold:2',
    'tool:c2',
    'tool:c4',
  ])
})

Deno.test('a run that would hide one tool stays unfolded', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    call(3, 'c2'),
    call(4, 'c3'),
  ]
  assertEquals(lineShape(turnLines(turn(events), false, false)), [
    'wake',
    'tool:c1',
    'tool:c2',
    'tool:c3',
  ])
})

Deno.test('a result arriving later settles its call without moving anything', () => {
  const before = projectTurns([input(0), call(1, 'c1'), call(2, 'c2')], true)
  const after = projectTurns(
    [input(0), call(1, 'c1'), call(2, 'c2'), settled(3, 'c1')],
    true,
  )
  assertEquals(shape(before), shape(after))
  assertEquals(toolState(activity(after, 'c1')!), 'done')
  assertEquals(toolState(activity(after, 'c2')!), 'running')
})

Deno.test('a result with no call and a bookmark show in place', () => {
  const orphan = event(2, {
    kind: 'toolResult',
    result: { callID: null, kind: 'mount', failed: false, output: 'ok' },
  })
  assertEquals(
    run([
      input(0),
      call(1, 'c1'),
      orphan,
      event(3, { kind: 'bookmark', name: 'mark' }),
      text(4, 'done'),
    ]),
    ['input tool:c1 orphan bookmark text'],
  )
})

Deno.test('projecting the same events twice gives the same turns', () => {
  const events = [
    input(0),
    call(1, 'c1'),
    settled(2, 'c1'),
    notice(3, 'timer', 900),
    text(4, 'done'),
  ]
  assertEquals(projectTurns(events, true), projectTurns(events, true))
})
