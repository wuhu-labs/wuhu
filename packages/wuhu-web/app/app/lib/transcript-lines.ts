import type { SessionLineEvent, SessionLinePayload } from './contract.gen.ts'

export interface LinesState {
  generation: number
  lines: readonly SessionLinePayload[]
}

export const initialLines: LinesState = { generation: 0, lines: [] }

// Places a line at its position, replacing the one there: a resume resends
// the prompt lines and a backfill refolds what is already held.
export function foldLines(
  state: LinesState,
  event: SessionLineEvent,
): LinesState {
  if (event.kind === 'reset') return { generation: event.generation, lines: [] }
  if (event.generation !== state.generation) return state
  const { line } = event
  const lines = state.lines
  let index = lines.length
  while (index > 0 && lines[index - 1]!.position > line.position) index--
  const replaces = index > 0 && lines[index - 1]!.position === line.position
  return {
    generation: state.generation,
    lines: [
      ...lines.slice(0, replaces ? index - 1 : index),
      line,
      ...lines.slice(index),
    ],
  }
}

export type LineBlock =
  | { kind: 'text'; text: string }
  | { kind: 'reasoning'; text: string }
  | { kind: 'toolCall'; name: string; arguments: string }
  | { kind: 'media'; mimeType: string }
  | { kind: 'hostedTool'; type: string }

export interface LineView {
  position: number
  key: string
  role: SessionLinePayload['role']
  at: Date
  blocks: LineBlock[]
  failed: boolean
  // The blob holding the system line's preamble.
  rendered: string | null
}

type Json = Record<string, unknown>

function record(value: unknown): Json | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Json
    : null
}

function block(value: unknown): LineBlock | null {
  const wrapped = record(value)
  if (!wrapped) return null
  const text = record(wrapped.text)
  if (text && typeof text.text === 'string') {
    return { kind: 'text', text: text.text }
  }
  const reasoning = record(wrapped.reasoning)
  if (reasoning) {
    const summary = reasoning.unencrypted ?? reasoning.summary
    return typeof summary === 'string'
      ? { kind: 'reasoning', text: summary }
      : null
  }
  const call = record(wrapped.tool_call)
  if (call) {
    return {
      kind: 'toolCall',
      name: String(call.name ?? ''),
      arguments: typeof call.arguments === 'string'
        ? call.arguments
        : JSON.stringify(call.arguments ?? null),
    }
  }
  const media = record(wrapped.media)
  if (media) return { kind: 'media', mimeType: String(media.mime_type ?? '') }
  const hosted = record(wrapped.hosted_tool)
  if (hosted) return { kind: 'hostedTool', type: String(hosted.type ?? '') }
  return null
}

export function lineView(line: SessionLinePayload): LineView {
  const message = record(line.message) ?? {}
  const body = record(message.user) ?? record(message.assistant) ??
    record(message.tool_result)
  const content = Array.isArray(body?.content) ? body.content : []
  return {
    position: line.position,
    key: line.key,
    role: line.role,
    at: new Date(line.at * 1000),
    blocks: content.flatMap((value) => block(value) ?? []),
    failed: body?.is_error === true,
    rendered: line.role === 'system' && typeof message.rendered === 'string'
      ? message.rendered
      : null,
  }
}

export function hasContent(view: LineView): boolean {
  return view.rendered !== null ||
    view.blocks.some((block) =>
      block.kind !== 'text' && block.kind !== 'reasoning' ||
      block.text.trim() !== ''
    )
}
