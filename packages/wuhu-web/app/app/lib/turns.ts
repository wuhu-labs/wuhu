import { firstLine, noticeLabel } from './turn-labels.ts'
import {
  eventKey,
  type WorkEvent,
  type WorkEventID,
  type WorkInput,
  type WorkNotice,
  type WorkToolResult,
} from './work-events.ts'

export type ToolState = 'running' | 'queued' | 'done' | 'failed' | 'unknown'

export interface ToolActivity {
  callID: string
  name: string
  arguments: unknown
  result: WorkToolResult | null
  calledAt: Date | null
  settledAt: Date | null
  receiptID?: string
  pending?: 'running' | 'queued' | 'unknown'
}

export function toolState(tool: ToolActivity): ToolState {
  if (tool.result === null) return tool.pending ?? 'unknown'
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

export interface NoticePresentation {
  label: string
  subject: string | null
  sources: string[]
}

export function noticePresentation(notice: WorkNotice): NoticePresentation {
  const sources = [
    ...new Set(
      [...notice.text.matchAll(/<AGENTS\.md\s+from="([^"\r\n]+)"\s*>/g)]
        .map((match) => match[1]!),
    ),
  ]
  if (sources.length > 0) {
    return {
      label: 'Instructions loaded',
      subject:
        sources[0]!.replace(/^machines:\/\/[^/]+\/Users\/[^/]+\//, '').replace(
          /^machines:\/\/[^/]+\//,
          '',
        ) + (sources.length > 1 ? ` + ${sources.length - 1} more` : ''),
      sources,
    }
  }
  if (
    [
      'timer',
      'spaceObservation',
      'script',
      'owedReply',
      'parkReminder',
      'childFailed',
      'requestDeadline',
      'restart',
    ].includes(notice.kind)
  ) {
    return {
      label: noticeLabel(notice.kind),
      subject: firstLine(notice.text),
      sources: [],
    }
  }
  return {
    label: notice.kind === 'compactRequest'
      ? 'Compaction requested'
      : 'Context updated',
    subject: notice.kind === 'compactRequest'
      ? 'Context housekeeping'
      : 'System-provided context',
    sources: [],
  }
}

export interface WorkItem extends TurnStep {
  inference: string | null
  label: string
  subject: string | null
  sources: string[]
}

export type TranscriptRow =
  | { kind: 'input'; key: string; wake: Wake }
  | { kind: 'divider'; key: string; event: WorkEventID }
  | { kind: 'gap'; key: string }
  | { kind: 'item'; key: string; item: WorkItem; latest: boolean }
  | {
    kind: 'summary'
    key: string
    items: WorkItem[]
    tools: number
    duration: number | null
    working: boolean
  }

export interface TurnProjection {
  rows: TranscriptRow[]
  items: WorkItem[]
  isWorking: boolean
}

export function inferenceID(event: WorkEvent): string | null {
  if (event.id.kind !== 'kernel') return null
  switch (event.kind) {
    case 'assistantText':
      return event.streaming
        ? null
        : `${event.id.generation}:${event.id.position}`
    case 'reasoning':
    case 'toolCall':
      return `${event.id.generation}:${event.id.position}`
    default:
      return null
  }
}

export function activity(
  projection: TurnProjection,
  callID: string,
): ToolActivity | null {
  for (const item of projection.items) {
    if (
      (item.content.kind === 'tool' || item.content.kind === 'send') &&
      item.content.tool.callID === callID
    ) return item.content.tool
  }
  return null
}

function workItem(
  event: WorkEvent,
  content: StepContent,
  inference: string | null,
): WorkItem {
  const item: WorkItem = {
    key: eventKey(event.id),
    event: event.id,
    timestamp: event.timestamp,
    content,
    inference,
    label: '',
    subject: null,
    sources: [],
  }
  switch (content.kind) {
    case 'tool':
    case 'send':
      item.label = baseName(content.tool)
      item.subject = toolSubject(content.tool)
      break
    case 'reasoning':
      item.label = 'Reasoning'
      break
    case 'text':
      item.label = 'Preamble'
      item.subject =
        content.text.split(/\r?\n/).find((line) => line.trim() !== '') ?? null
      break
    case 'notice':
      Object.assign(item, noticePresentation(content.notice))
      break
    case 'bookmark':
      item.label = 'Bookmark'
      item.subject = content.name
      break
    case 'orphanResult':
      item.label = 'Tool result'
      item.subject = content.result.kind
      break
  }
  return item
}

export function workDuration(items: WorkItem[]): number | null {
  const moments = items.flatMap((item) =>
    item.content.kind === 'tool' || item.content.kind === 'send'
      ? [item.content.tool.calledAt, item.content.tool.settledAt]
      : [item.timestamp]
  ).filter((moment): moment is Date =>
    moment !== null && Number.isFinite(moment.getTime())
  )
  if (moments.length < 2) return null
  const times = moments.map((moment) => moment.getTime())
  return Math.max(0, (Math.max(...times) - Math.min(...times)) / 1000)
}

export function projectTurns(
  events: WorkEvent[],
  working: boolean,
  boundary?: {
    origins: WorkEvent[]
    runningCall?: string | null
  },
): TurnProjection {
  const committed = events.map(inferenceID).filter((id): id is string =>
    id !== null
  )
  const latest = committed.at(-1) ?? null
  const batchesWithTools = new Set(
    events.filter((e) => e.kind === 'toolCall').map(inferenceID),
  )
  const called = new Set(
    events.flatMap((e) => e.kind === 'toolCall' ? [e.call.callID] : []),
  )
  const origins = new Map(
    (boundary?.origins ?? []).flatMap((e) =>
      e.kind === 'toolCall' ? [[e.call.callID, e] as const] : []
    ),
  )
  const settled = new Map<
    string,
    { result: WorkToolResult; at: Date | null; receiptID: string }
  >()
  for (const event of events) {
    if (
      event.kind === 'toolResult' && event.result.callID !== null &&
      !settled.has(event.result.callID)
    ) {
      settled.set(event.result.callID, {
        result: event.result,
        at: event.timestamp,
        receiptID: eventKey(event.id),
      })
    }
  }
  const running = working
    ? events.find((e) =>
      e.kind === 'toolCall' && e.call.callID === boundary?.runningCall &&
      !settled.has(e.call.callID)
    )
    : undefined
  const runningInference = running ? inferenceID(running) : null
  let afterRunning = false
  const makeTool = (
    event: Extract<WorkEvent, { kind: 'toolCall' }>,
  ): ToolActivity => {
    const outcome = settled.get(event.call.callID)
    let pending: ToolActivity['pending'] = 'unknown'
    if (event === running && runningInference === latest) {
      pending = 'running'
      afterRunning = true
    } else if (
      afterRunning && runningInference === latest &&
      inferenceID(event) === runningInference
    ) pending = 'queued'
    return {
      ...event.call,
      result: outcome?.result ?? null,
      calledAt: event.timestamp,
      settledAt: outcome?.at ?? null,
      receiptID: outcome?.receiptID,
      pending,
    }
  }
  const rows: TranscriptRow[] = [], items: WorkItem[] = []
  let work: WorkItem[] = [], preceding: string | null = null
  const push = (item: WorkItem, eligible: boolean) => {
    if (item.content.kind === 'text' && !eligible) item.label = 'Assistant text'
    items.push(item)
    if (eligible) work.push(item)
    else {
      flush()
      rows.push({
        kind: 'item',
        key: item.key,
        item,
        latest: item.inference === latest && latest !== null,
      })
    }
  }
  const flush = () => {
    if (work.length === 0) return
    const hidden = work.filter((item) =>
      item.inference !== latest || latest === null
    )
    let placed = false
    for (const item of work) {
      if (item.inference === latest && latest !== null) {
        rows.push({ kind: 'item', key: item.key, item, latest: true })
      } else if (!placed) {
        rows.push({
          kind: 'summary',
          key: `summary:${hidden[0]!.key}`,
          items: hidden,
          tools: new Set(hidden.flatMap((item) =>
            item.content.kind === 'tool' ? [item.content.tool.callID] : []
          )).size,
          duration: workDuration(hidden),
          working: hidden.some((item) =>
            item.content.kind === 'tool' &&
            toolState(item.content.tool) === 'running'
          ),
        })
        placed = true
      }
    }
    work = []
  }
  const represented = new Set<string>()
  let previousPosition: number | null = null
  for (const event of events) {
    if (event.id.kind === 'kernel') {
      if (
        previousPosition !== null && event.id.position > previousPosition + 1
      ) {
        flush()
        preceding = null
        rows.push({ kind: 'gap', key: `gap:${eventKey(event.id)}` })
      }
      previousPosition = event.id.position
    }
    const inference = inferenceID(event)
    if (inference !== null) preceding = inference
    switch (event.kind) {
      case 'input':
        flush()
        rows.push({
          kind: 'input',
          key: eventKey(event.id),
          wake: {
            id: event.id,
            timestamp: event.timestamp,
            source: { kind: 'input', input: event.input },
          },
        })
        break
      case 'generationHead':
        flush()
        preceding = null
        rows.push({ kind: 'divider', key: eventKey(event.id), event: event.id })
        break
      case 'assistantText':
        if (event.text !== '') {
          push(
            workItem(event, {
              kind: 'text',
              text: event.text,
              streaming: event.streaming,
            }, inference),
            !event.streaming && batchesWithTools.has(inference),
          )
        }
        break
      case 'reasoning':
        push(
          workItem(
            event,
            { kind: 'reasoning', summary: event.summary },
            inference,
          ),
          true,
        )
        break
      case 'toolCall': {
        if (represented.has(event.call.callID)) break
        represented.add(event.call.callID)
        const tool = makeTool(event), sent = outgoing(tool)
        push(
          workItem(
            event,
            sent
              ? { kind: 'send', tool, outgoing: sent }
              : { kind: 'tool', tool },
            inference,
          ),
          sent === null,
        )
        break
      }
      case 'notification':
        // Without a loaded preceding inference, this is an annotation, not a folded invented parent.
        push(
          workItem(event, { kind: 'notice', notice: event.notice }, preceding),
          preceding !== null,
        )
        break
      case 'bookmark':
        push(
          workItem(event, { kind: 'bookmark', name: event.name }, null),
          false,
        )
        break
      case 'toolResult': {
        const callID = event.result.callID
        if (
          callID !== null && (called.has(callID) || represented.has(callID))
        ) break
        const origin = callID === null ? undefined : origins.get(callID)
        if (origin?.kind === 'toolCall') {
          represented.add(origin.call.callID)
          const tool = makeTool(origin)
          push(workItem(event, { kind: 'tool', tool }, null), false)
        } else {push(
            workItem(
              event,
              { kind: 'orphanResult', result: event.result },
              null,
            ),
            false,
          )}
        break
      }
    }
  }
  flush()
  return {
    rows,
    items,
    isWorking: working ||
      events.some((event) => event.kind === 'assistantText' && event.streaming),
  }
}

export function rowAnchors(row: TranscriptRow): string[] {
  const items = row.kind === 'summary'
    ? row.items
    : row.kind === 'item'
    ? [row.item]
    : []
  return [
    ...new Set(items.flatMap((item) => {
      const content = item.content
      const receipt = content.kind === 'tool' || content.kind === 'send'
        ? content.tool.receiptID
        : undefined
      return [item.key, ...(receipt ? [receipt] : [])]
    })),
  ].filter((key) => key !== row.key)
}

export function rowAtAnchor(
  projection: TurnProjection,
  key: string,
): TranscriptRow | null {
  const source = key.replace(/^summary:/, '')
  return projection.rows.find((row) =>
    row.key === key || rowAnchors(row).includes(source)
  ) ?? null
}
