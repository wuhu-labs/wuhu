import type {
  AgentStatus,
  SandboxDaemonAgentEvent,
  SandboxDaemonEvent,
  StreamEnvelope,
  ToolActivity,
  UiMessage,
  UiState,
} from './types'
import { initialUiState } from './types'

function formatTimestamp(value?: number | string): string {
  const date = value ? new Date(value) : new Date()
  return date.toLocaleTimeString([], { hour12: false })
}

function coerceAgentEvent(
  event: SandboxDaemonEvent,
): SandboxDaemonAgentEvent | null {
  if (event.source !== 'agent') return null
  if (!event || typeof event !== 'object') return null
  if (!event.payload || typeof event.payload !== 'object') return null
  return event as SandboxDaemonAgentEvent
}

function extractMessageParts(message: any): {
  role: string
  text: string
  thinking: string
  toolCalls: { id: string; name: string }[]
  timestamp?: number
} {
  const role = typeof message?.role === 'string' ? message.role : 'assistant'
  const timestamp = typeof message?.timestamp === 'number'
    ? message.timestamp
    : undefined

  const parts = {
    text: '',
    thinking: '',
    toolCalls: [] as {
      id: string
      name: string
    }[],
  }

  const content = message?.content
  if (typeof content === 'string') {
    parts.text = content
  } else if (Array.isArray(content)) {
    const toolCallById = new Map<string, { id: string; name: string }>()
    for (const item of content) {
      if (!item || typeof item !== 'object') continue
      if (item.type === 'text' && typeof item.text === 'string') {
        parts.text += item.text
      }
      if (item.type === 'thinking' && typeof item.thinking === 'string') {
        parts.thinking += item.thinking
      }
      if (item.type === 'toolCall') {
        const id = typeof item.id === 'string' ? item.id : ''
        const name = typeof item.name === 'string' ? item.name : 'tool'
        if (id) {
          toolCallById.set(id, { id, name })
        } else {
          parts.toolCalls.push({ id: name, name })
        }
      }
    }
    if (toolCallById.size) {
      parts.toolCalls.push(...toolCallById.values())
    }
  }

  return {
    role,
    text: parts.text,
    thinking: parts.thinking,
    toolCalls: parts.toolCalls,
    timestamp,
  }
}

function upsertMessage(
  messages: UiMessage[],
  message: UiMessage,
): UiMessage[] {
  const idx = messages.findIndex((m) => m.id === message.id)
  if (idx === -1) return [...messages, message]
  const next = [...messages]
  next[idx] = { ...next[idx], ...message }
  return next
}

function updateActivityFromEvent(
  activities: ToolActivity[],
  event: any,
): ToolActivity[] {
  const payload = event?.payload
  if (!payload || typeof payload !== 'object') return activities
  const type = payload.type
  if (
    type !== 'tool_execution_start' &&
    type !== 'tool_execution_update' &&
    type !== 'tool_execution_end'
  ) {
    return activities
  }
  const id = typeof payload.toolCallId === 'string'
    ? payload.toolCallId
    : `tool-${Date.now()}`
  const toolName = typeof payload.toolName === 'string'
    ? payload.toolName
    : 'tool'
  const outputRaw = payload.partialResult ?? payload.result
  let output = ''
  if (outputRaw && typeof outputRaw === 'object') {
    const content = (outputRaw as any).content
    if (Array.isArray(content)) {
      output = content
        .map((item) =>
          item && typeof item === 'object' && item.type === 'text'
            ? String(item.text ?? '')
            : ''
        )
        .join('')
    }
  }
  const status: ToolActivity['status'] = type === 'tool_execution_end'
    ? (payload.isError ? 'error' : 'done')
    : 'running'

  const updatedAt = formatTimestamp()

  const idx = activities.findIndex((a) => a.id === id)
  if (idx === -1) {
    return [
      {
        id,
        toolName,
        status,
        output,
        updatedAt,
      },
      ...activities,
    ].slice(0, 12)
  }
  const next = [...activities]
  next[idx] = {
    ...next[idx],
    status,
    output: output || next[idx].output,
    updatedAt,
  }
  return next.slice(0, 12)
}

function nextAgentStatus(
  current: AgentStatus,
  event: SandboxDaemonAgentEvent,
): AgentStatus {
  const t = event.payload?.type
  switch (t) {
    case 'turn_start':
    case 'message_start':
    case 'message_update':
      return 'Responding'
    case 'tool_execution_start':
    case 'tool_execution_update':
      return `Running ${String((event.payload as any).toolName || 'tool')}`
    case 'tool_execution_end':
      return 'Idle'
    case 'turn_end':
    case 'agent_end':
      return 'Idle'
    default:
      return current
  }
}

export function reduceEnvelope(
  state: UiState,
  envelope: StreamEnvelope<SandboxDaemonEvent>,
): UiState {
  const { event, cursor } = envelope

  if (event.source === 'daemon' && event.type === 'reset') {
    return { ...initialUiState }
  }

  if (event.source === 'daemon' && event.type === 'clear_activities') {
    return { ...state, activities: [] }
  }

  const next: UiState = { ...state, cursor, lastEventType: event.type }

  const agentEvent = coerceAgentEvent(event)
  if (!agentEvent) {
    // Daemon event → log as system message for now.
    const daemonMessage: UiMessage = {
      id: `daemon-${cursor}`,
      role: 'system',
      title: 'Daemon event',
      text: JSON.stringify(event),
      status: 'complete',
      timestamp: formatTimestamp(),
    }
    return {
      ...next,
      messages: [...next.messages, daemonMessage],
    }
  }

  const payload = agentEvent.payload
  const t = payload.type

  // Tool activity tracking
  const activities = updateActivityFromEvent(next.activities, agentEvent)

  // Message handling
  let messages = next.messages

  if (t === 'message_start' || t === 'message_update' || t === 'message_end') {
    const message = (payload as any).message
    const { role, text, thinking, toolCalls, timestamp } = extractMessageParts(
      message,
    )

    let status: UiMessage['status'] = 'streaming'
    if (t === 'message_end') status = 'complete'

    // Generate a stable-ish id per message by role + timestamp + optional signatures
    const sig = (message && typeof message.textSignature === 'string'
      ? message.textSignature
      : message && typeof message.thinkingSignature === 'string'
      ? message.thinkingSignature
      : '') ||
      `${role}-${timestamp ?? ''}`
    const id = sig || `msg-${cursor}`

    const base: UiMessage = {
      id,
      role: role === 'toolResult' ? 'tool' : (role as any),
      title: role === 'user'
        ? 'You'
        : role === 'assistant'
        ? 'Agent'
        : role === 'toolResult'
        ? message.toolName || 'Tool result'
        : role,
      text,
      thinking,
      toolCalls,
      status,
      timestamp: formatTimestamp(timestamp),
    }

    messages = upsertMessage(messages, base)
  }

  if (t === 'turn_end') {
    // Ensure no lingering streaming messages.
    messages = messages.map((m) =>
      m.status === 'streaming' ? { ...m, status: 'complete' } : m
    )
  }

  return {
    ...next,
    activities,
    messages,
    agentStatus: nextAgentStatus(next.agentStatus, agentEvent),
  }
}

export function reduceEnvelopes(
  envelopes: Array<StreamEnvelope<SandboxDaemonEvent>>,
  base: UiState = initialUiState,
): UiState {
  return envelopes.reduce(
    (state, env) => reduceEnvelope(state, env),
    base,
  )
}
