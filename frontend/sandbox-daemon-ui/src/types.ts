export interface StreamEnvelope<TEvent = unknown> {
  cursor: number
  event: TEvent
}

export type SandboxDaemonEventSource = 'daemon' | 'agent'

export interface SandboxDaemonBaseEvent {
  source: SandboxDaemonEventSource
  type: string
}

export interface SandboxDaemonAgentEventPayload {
  type: string
  [key: string]: unknown
}

export interface SandboxDaemonAgentEvent extends SandboxDaemonBaseEvent {
  source: 'agent'
  payload: SandboxDaemonAgentEventPayload
}

export interface SandboxDaemonDaemonEvent extends SandboxDaemonBaseEvent {
  source: 'daemon'
  // shape is free-form for now; UI just logs it
  [key: string]: unknown
}

export type SandboxDaemonEvent =
  | SandboxDaemonAgentEvent
  | SandboxDaemonDaemonEvent

export type AgentRole = 'user' | 'assistant' | 'tool' | 'system'

export type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

export interface ToolCallSummary {
  id: string
  name: string
}

export interface UiMessage {
  id: string
  role: AgentRole
  title: string
  text: string
  thinking?: string
  toolCalls?: ToolCallSummary[]
  status: MessageStatus
  timestamp?: string
}

export type ToolActivityStatus = 'running' | 'done' | 'error'

export interface ToolActivity {
  id: string
  toolName: string
  status: ToolActivityStatus
  output: string
  updatedAt: string
}

export type AgentStatus =
  | 'Idle'
  | 'Queued'
  | 'Responding'
  | `Running ${string}`

export interface UiState {
  cursor: number
  messages: UiMessage[]
  activities: ToolActivity[]
  lastEventType?: string
  agentStatus: AgentStatus
}

export const initialUiState: UiState = {
  cursor: 0,
  messages: [],
  activities: [],
  lastEventType: undefined,
  agentStatus: 'Idle',
}
