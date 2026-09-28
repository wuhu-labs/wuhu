import {
  eventKey,
  type WorkEvent,
  type WorkEventID,
  type WorkHead,
  type WorkInput,
  type WorkNotice,
  type WorkToolResult,
} from './work-events.ts'

export type ToolState = 'running' | 'done' | 'failed'

export interface ToolActivity {
  callID: string
  name: string
  arguments: unknown
  result: WorkToolResult | null
  calledAt: Date | null
  settledAt: Date | null
}

export function toolState(tool: ToolActivity): ToolState {
  if (tool.result === null) return 'running'
  return tool.result.failed ? 'failed' : 'done'
}

// Claude Code sessions name the space's tools with their server prefix.
export function baseName(tool: { name: string }): string {
  return tool.name.startsWith('mcp__wuhu__')
    ? tool.name.slice('mcp__wuhu__'.length)
    : tool.name
}

const subjectKeys = [
  'path',
  'file_path',
  'command',
  'cmd',
  'query',
  'pattern',
  'glob',
  'sql',
  'url',
  'title',
]

function fields(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function stringField(
  object: Record<string, unknown> | null,
  key: string,
): string | null {
  const value = object?.[key]
  return typeof value === 'string' ? value : null
}

export function toolSubject(tool: ToolActivity): string | null {
  const object = fields(tool.arguments)
  for (const key of subjectKeys) {
    const value = stringField(object, key)
    if (value === null || value === '') continue
    return value.split(/\r?\n/).find((line) => line !== '') ?? value
  }
  return null
}

export type SendTarget =
  | { kind: 'box' }
  | { kind: 'session'; id: string }
  | { kind: 'user'; id: string }
  | { kind: 'conversation'; id: string }
  | { kind: 'report'; report: string }

export interface Outgoing {
  target: SendTarget
  text: string
}

export function outgoing(tool: ToolActivity): Outgoing | null {
  const object = fields(tool.arguments)
  switch (baseName(tool)) {
    case 'send_message': {
      const text = stringField(object, 'message') ?? ''
      const session = stringField(object, 'session')
      if (session !== null) {
        return { target: { kind: 'session', id: session }, text }
      }
      const user = stringField(object, 'user')
      if (user !== null) return { target: { kind: 'user', id: user }, text }
      const conversation = stringField(object, 'conversation')
      if (conversation !== null) {
        return { target: { kind: 'conversation', id: conversation }, text }
      }
      return { target: { kind: 'box' }, text }
    }
    case 'report':
      return {
        target: {
          kind: 'report',
          report: stringField(object, 'kind') ?? 'final',
        },
        text: stringField(object, 'content') ?? '',
      }
    default:
      return null
  }
}

export type WakeSource =
  | { kind: 'input'; input: WorkInput }
  | { kind: 'notice'; notice: WorkNotice }

export interface Wake {
  id: WorkEventID
  timestamp: Date | null
  source: WakeSource
}

export function wakeText(wake: Wake): string {
  return wake.source.kind === 'input'
    ? wake.source.input.text
    : wake.source.notice.text
}

export type StepContent =
  | { kind: 'text'; text: string; streaming: boolean }
  | { kind: 'reasoning'; summary: string }
  | { kind: 'tool'; tool: ToolActivity }
  | { kind: 'send'; tool: ToolActivity; outgoing: Outgoing }
  | { kind: 'notice'; notice: WorkNotice }
  | { kind: 'bookmark'; name: string | null }
  | { kind: 'orphanResult'; result: WorkToolResult }

export interface TurnStep {
  key: string
  event: WorkEventID
  timestamp: Date | null
  content: StepContent
}

export interface Turn {
  id: WorkEventID
  wakes: Wake[]
  continued: boolean
  steps: TurnStep[]
}

export function turnTools(turn: Turn): ToolActivity[] {
  return turn.steps.flatMap((step) =>
    step.content.kind === 'tool' ? [step.content.tool] : []
  )
}

export function turnSends(turn: Turn): TurnStep[] {
  return turn.steps.filter((step) => step.content.kind === 'send')
}

export function lastText(turn: Turn): string | null {
  for (let index = turn.steps.length - 1; index >= 0; index -= 1) {
    const content = turn.steps[index]!.content
    if (content.kind === 'text' && !content.streaming && content.text !== '') {
      return content.text
    }
  }
  return null
}

function stepMoments(step: TurnStep): (Date | null)[] {
  switch (step.content.kind) {
    case 'tool':
    case 'send':
      return [step.content.tool.calledAt, step.content.tool.settledAt]
    default:
      return [step.timestamp]
  }
}

// Seconds from the wake-up to the turn's last event.
export function turnDuration(turn: Turn): number | null {
  const start = turn.wakes.find((wake) => wake.timestamp !== null)?.timestamp ??
    turn.steps.find((step) => step.timestamp !== null)?.timestamp
  const moments = [
    ...turn.wakes.map((wake) => wake.timestamp),
    ...turn.steps.flatMap(stepMoments),
  ].filter((moment): moment is Date => moment !== null)
  if (start == null || moments.length === 0) return null
  const end = Math.max(...moments.map((moment) => moment.getTime()))
  return Math.max(0, (end - start.getTime()) / 1000)
}

export type TurnItem =
  | { kind: 'divider'; id: WorkEventID; head: WorkHead }
  | { kind: 'turn'; turn: Turn }

export interface TurnProjection {
  items: TurnItem[]
  isWorking: boolean
}

export function projectedTurns(projection: TurnProjection): Turn[] {
  return projection.items.flatMap((item) =>
    item.kind === 'turn' ? [item.turn] : []
  )
}

export function latestTurn(projection: TurnProjection): Turn | null {
  return projectedTurns(projection).at(-1) ?? null
}

export function activity(
  projection: TurnProjection,
  callID: string,
): ToolActivity | null {
  for (const turn of projectedTurns(projection)) {
    for (const step of turn.steps) {
      const content = step.content
      if (
        (content.kind === 'tool' || content.kind === 'send') &&
        content.tool.callID === callID
      ) return content.tool
    }
  }
  return null
}

export function projectTurns(
  events: WorkEvent[],
  working: boolean,
): TurnProjection {
  const settled = new Map<
    string,
    { result: WorkToolResult; at: Date | null }
  >()
  const called = new Set<string>()
  for (const event of events) {
    if (event.kind === 'toolResult' && event.result.callID !== null) {
      settled.set(event.result.callID, {
        result: event.result,
        at: event.timestamp,
      })
    }
    if (event.kind === 'toolCall') called.add(event.call.callID)
  }

  const folding = new TurnFolding()
  let placeholder = false
  for (const event of events) {
    const step = (content: StepContent, key?: string): TurnStep => ({
      key: key ?? eventKey(event.id),
      event: event.id,
      timestamp: event.timestamp,
      content,
    })
    switch (event.kind) {
      case 'input':
        folding.wake({
          id: event.id,
          timestamp: event.timestamp,
          source: { kind: 'input', input: event.input },
        })
        break
      case 'notification':
        if (folding.isMidTurn) {
          folding.output(step({ kind: 'notice', notice: event.notice }))
        } else {
          folding.wake({
            id: event.id,
            timestamp: event.timestamp,
            source: { kind: 'notice', notice: event.notice },
          })
        }
        break
      case 'generationHead':
        if (event.head.summary !== '') {
          folding.divide(event.id, event.head)
        } else if (event.head.note != null && event.head.note !== '') {
          folding.wake({
            id: event.id,
            timestamp: event.timestamp,
            source: {
              kind: 'notice',
              notice: {
                kind: 'restart',
                text: event.head.note,
                conversations: [],
              },
            },
          })
        }
        break
      case 'assistantText':
        if (event.streaming && event.text === '') {
          placeholder = true
        } else if (event.text !== '') {
          folding.output(
            step({
              kind: 'text',
              text: event.text,
              streaming: event.streaming,
            }),
          )
        }
        break
      case 'reasoning':
        folding.output(step({ kind: 'reasoning', summary: event.summary }))
        break
      case 'toolCall': {
        const outcome = settled.get(event.call.callID)
        const tool: ToolActivity = {
          callID: event.call.callID,
          name: event.call.name,
          arguments: event.call.arguments,
          result: outcome?.result ?? null,
          calledAt: event.timestamp,
          settledAt: outcome?.at ?? null,
        }
        const sent = outgoing(tool)
        folding.output(
          step(
            sent === null
              ? { kind: 'tool', tool }
              : { kind: 'send', tool, outgoing: sent },
            `tool:${tool.callID}`,
          ),
        )
        break
      }
      case 'toolResult':
        if (event.result.callID !== null && called.has(event.result.callID)) {
          folding.settle()
        } else {
          folding.output(step({ kind: 'orphanResult', result: event.result }))
        }
        break
      case 'bookmark':
        folding.output(step({ kind: 'bookmark', name: event.name }), true)
        break
    }
    if (event.stopReason !== null) folding.stop(event.stopReason)
  }
  return { items: folding.finish(), isWorking: working || placeholder }
}

class TurnFolding {
  private items: TurnItem[] = []
  private current: Turn | null = null
  private phase: 'waking' | 'working' | 'ended' = 'ended'
  private afterDivider = false
  private entryCalledTools = false

  get isMidTurn(): boolean {
    return this.current !== null && this.phase === 'working'
  }

  wake(wake: Wake) {
    if (this.phase === 'waking' && this.current !== null) {
      this.current.wakes.push(wake)
    } else {
      this.close()
      this.current = { id: wake.id, wakes: [wake], continued: false, steps: [] }
      this.afterDivider = false
    }
    this.phase = 'waking'
  }

  divide(id: WorkEventID, head: WorkHead) {
    this.close()
    this.items.push({ kind: 'divider', id, head })
    this.afterDivider = true
    this.phase = 'ended'
  }

  output(step: TurnStep, keepsPhase = false) {
    if (this.current === null) {
      this.current = {
        id: step.event,
        wakes: [],
        continued: this.afterDivider,
        steps: [],
      }
      this.afterDivider = false
      this.phase = 'working'
    }
    this.current.steps.push(step)
    if (step.content.kind === 'tool' || step.content.kind === 'send') {
      this.entryCalledTools = true
    }
    if (!keepsPhase && this.phase === 'waking') this.phase = 'working'
  }

  settle() {
    if (this.current !== null) this.phase = 'working'
  }

  // An entry that called tools goes on; any other stop ends the turn's work.
  stop(reason: string) {
    const toolStop = this.entryCalledTools || reason === 'tool_use' ||
      reason === 'toolUse'
    this.entryCalledTools = false
    if (this.current !== null) this.phase = toolStop ? 'working' : 'ended'
  }

  finish(): TurnItem[] {
    this.close()
    return this.items
  }

  private close() {
    if (this.current !== null) {
      this.items.push({ kind: 'turn', turn: this.current })
    }
    this.current = null
  }
}

export type TurnLine =
  | { key: string; kind: 'wake'; wake: Wake; clamped: boolean }
  | { key: 'continued'; kind: 'continued' }
  | {
    key: 'summary'
    kind: 'summary'
    tools: number
    duration: number | null
    expanded: boolean
  }
  | { key: string; kind: 'step'; step: TurnStep }
  | { key: string; kind: 'fold'; tools: ToolActivity[] }
  | { key: string; kind: 'fallback'; text: string }

function stepLine(step: TurnStep): TurnLine {
  return { key: step.key, kind: 'step', step }
}

// A closed turn folds to what woke it, its tool line and what it sent; the
// latest turn always shows its whole chronology.
export function turnLines(
  turn: Turn,
  closed: boolean,
  expanded: boolean,
): TurnLine[] {
  const folded = closed && !expanded
  const lines: TurnLine[] = turn.wakes.map((wake) => ({
    key: `wake:${eventKey(wake.id)}`,
    kind: 'wake',
    wake,
    clamped: folded,
  }))
  if (turn.continued) lines.push({ key: 'continued', kind: 'continued' })
  if (closed) {
    lines.push({
      key: 'summary',
      kind: 'summary',
      tools: turnTools(turn).length,
      duration: turnDuration(turn),
      expanded,
    })
  }
  if (!folded) return [...lines, ...foldToolRuns(turn.steps)]
  const sends = turnSends(turn)
  if (sends.length > 0) return [...lines, ...sends.map(stepLine)]
  const text = lastText(turn)
  if (text !== null) lines.push({ key: 'fallback', kind: 'fallback', text })
  return lines
}

// Three or more tool calls with no text or send between them fold into one
// line; the running calls and the run's last call stay visible below it, and a
// fold never hides a single call.
export function foldToolRuns(steps: TurnStep[]): TurnLine[] {
  const lines: TurnLine[] = []
  let run: TurnStep[] = []

  const flush = () => {
    const tools = run.flatMap((step) =>
      step.content.kind === 'tool' ? [step.content.tool] : []
    )
    const last = tools.at(-1)
    const hidden = tools.filter((tool) =>
      tool.callID !== last?.callID && toolState(tool) !== 'running'
    )
    if (tools.length < 3 || hidden.length < 2) {
      lines.push(...run.map(stepLine))
    } else {
      const hiddenIDs = new Set(hidden.map((tool) => tool.callID))
      let placed = false
      for (const step of run) {
        const content = step.content
        if (content.kind === 'tool' && hiddenIDs.has(content.tool.callID)) {
          if (placed) continue
          placed = true
          lines.push({
            key: `fold:${content.tool.callID}`,
            kind: 'fold',
            tools: hidden,
          })
        } else {
          lines.push(stepLine(step))
        }
      }
    }
    run = []
  }

  for (const step of steps) {
    if (step.content.kind === 'text' || step.content.kind === 'send') {
      flush()
      lines.push(stepLine(step))
    } else {
      run.push(step)
    }
  }
  flush()
  return lines
}
