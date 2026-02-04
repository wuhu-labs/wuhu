import { useEffect, useReducer, useRef, useState } from 'react'
import type { KeyboardEvent } from 'react'
import {
  Form,
  Link,
  redirect,
  useFetcher,
  useLoaderData,
  useRevalidator,
} from 'react-router'
import type { Route } from './+types/sandboxes.$id.ts'
function parseSseChunk(chunk: string): { id: string; data?: string } {
  const lines = chunk.split(/\r?\n/)
  const dataLines: string[] = []
  let id = ''

  for (const line of lines) {
    if (!line || line.startsWith(':')) continue
    if (line.startsWith('id:')) {
      id = line.slice('id:'.length).trim()
      continue
    }
    if (line.startsWith('data:')) {
      dataLines.push(line.slice('data:'.length).trimStart())
    }
  }

  const data = dataLines.length ? dataLines.join('\n') : undefined
  return { id, data }
}

interface StreamEnvelope<TEvent = unknown> {
  cursor: number
  event: TEvent
}

type SandboxDaemonEventSource = 'daemon' | 'agent'

interface SandboxDaemonBaseEvent {
  source: SandboxDaemonEventSource
  type: string
}

interface SandboxDaemonAgentEventPayload {
  type: string
  [key: string]: unknown
}

interface SandboxDaemonAgentEvent extends SandboxDaemonBaseEvent {
  source: 'agent'
  payload: SandboxDaemonAgentEventPayload
}

interface SandboxDaemonDaemonEvent extends SandboxDaemonBaseEvent {
  source: 'daemon'
  [key: string]: unknown
}

type SandboxDaemonEvent =
  | SandboxDaemonAgentEvent
  | SandboxDaemonDaemonEvent

type AgentRole = 'user' | 'assistant' | 'tool' | 'system'

type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

interface ToolCallSummary {
  id: string
  name: string
}

interface UiMessage {
  id: string
  role: AgentRole
  title: string
  text: string
  thinking?: string
  toolCalls?: ToolCallSummary[]
  status: MessageStatus
  timestamp?: string
}

type ToolActivityStatus = 'running' | 'done' | 'error'

interface ToolActivity {
  id: string
  toolName: string
  status: ToolActivityStatus
  output: string
  updatedAt: string
}

type AgentStatus =
  | 'Idle'
  | 'Queued'
  | 'Responding'
  | `Running ${string}`

interface UiState {
  cursor: number
  messages: UiMessage[]
  activities: ToolActivity[]
  lastEventType?: string
  agentStatus: AgentStatus
}

const initialUiState: UiState = {
  cursor: 0,
  messages: [],
  activities: [],
  lastEventType: undefined,
  agentStatus: 'Idle',
}

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

function reduceEnvelope(
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

  const next: UiState = {
    ...state,
    cursor,
    lastEventType: event.source === 'agent' ? event.type : state.lastEventType,
  }

  const agentEvent = coerceAgentEvent(event)
  if (!agentEvent) {
    return next
  }

  const payload = agentEvent.payload
  const t = payload.type

  const activities = updateActivityFromEvent(next.activities, agentEvent)

  let messages = next.messages

  if (t === 'message_start' || t === 'message_update' || t === 'message_end') {
    const message = (payload as any).message
    const { role, text, thinking, toolCalls, timestamp } = extractMessageParts(
      message,
    )

    let status: UiMessage['status'] = 'streaming'
    if (t === 'message_end') status = 'complete'

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

async function fetchSandbox(apiUrl: string, id: string) {
  const response = await fetch(`${apiUrl}/sandboxes/${id}`)
  if (!response.ok) {
    throw new Response('Sandbox not found', { status: 404 })
  }
  const data = await response.json()
  return data.sandbox
}

export async function loader({ params }: Route.LoaderArgs) {
  const apiUrl = Deno.env.get('API_URL')
  if (!apiUrl) {
    throw new Response('API_URL environment variable is not configured', {
      status: 500,
    })
  }
  const id = params.id
  if (!id) {
    throw new Response('Sandbox id is required', { status: 400 })
  }
  const sandbox = await fetchSandbox(apiUrl, id)
  return { sandbox }
}

export async function action({ params, request }: Route.ActionArgs) {
  const apiUrl = Deno.env.get('API_URL')
  if (!apiUrl) {
    throw new Response('API_URL environment variable is not configured', {
      status: 500,
    })
  }
  const id = params.id
  if (!id) {
    throw new Response('Sandbox id is required', { status: 400 })
  }

  const formData = await request.formData()
  const actionType = String(formData.get('_action') ?? '')

  if (actionType === 'kill') {
    await fetch(`${apiUrl}/sandboxes/${id}/kill`, { method: 'POST' })
    return redirect('/')
  }

  if (actionType === 'prompt') {
    const message = String(formData.get('message') ?? '').trim()
    if (!message) {
      return new Response('Prompt message is required', { status: 400 })
    }
    const sandbox = await fetchSandbox(apiUrl, id)
    if (!sandbox?.podIp || !sandbox?.daemonPort) {
      return new Response('Sandbox pod not ready', { status: 503 })
    }
    const response = await fetch(
      `http://${sandbox.podIp}:${sandbox.daemonPort}/prompt`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          message,
          streamingBehavior: 'followUp',
        }),
      },
    )
    if (!response.ok) {
      const errorText = await response.text()
      return new Response(errorText || 'Prompt failed', { status: 500 })
    }
    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'content-type': 'application/json' },
    })
  }

  if (actionType === 'abort') {
    const sandbox = await fetchSandbox(apiUrl, id)
    if (!sandbox?.podIp || !sandbox?.daemonPort) {
      return new Response('Sandbox pod not ready', { status: 503 })
    }
    const response = await fetch(
      `http://${sandbox.podIp}:${sandbox.daemonPort}/abort`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ reason: 'user_abort' }),
      },
    )
    if (!response.ok) {
      const errorText = await response.text()
      return new Response(errorText || 'Abort failed', { status: 500 })
    }
    return new Response(JSON.stringify({ ok: true }), {
      headers: { 'content-type': 'application/json' },
    })
  }

  return null
}

export default function SandboxDetail() {
  const { sandbox } = useLoaderData<typeof loader>()
  const fetcher = useFetcher()
  const revalidator = useRevalidator()
  const sandboxReady = sandbox.status === 'running' && Boolean(sandbox.podIp) &&
    Boolean(sandbox.daemonPort)
  const [prompt, setPrompt] = useState('')
  const [connectionStatus, setConnectionStatus] = useState(
    () => (sandboxReady ? 'Disconnected' : 'Waiting for sandbox...'),
  )
  const [streaming, setStreaming] = useState(false)
  const sandboxReadyRef = useRef(sandboxReady)

  const [state, dispatchEnvelope] = useReducer(
    (s: UiState, env: StreamEnvelope<SandboxDaemonEvent>) =>
      reduceEnvelope(s, env),
    initialUiState,
  )

  const streamAbortRef = useRef<AbortController | null>(null)
  const retryRef = useRef<number | null>(null)
  const logRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    sandboxReadyRef.current = sandboxReady
  }, [sandboxReady])

  useEffect(() => {
    return () => {
      if (retryRef.current) {
        clearTimeout(retryRef.current)
        retryRef.current = null
      }
    }
  }, [])

  useEffect(() => {
    if (!logRef.current) return
    logRef.current.scrollTop = logRef.current.scrollHeight
  }, [state.messages])

  const streamUrl = `/sandboxes/${sandbox.id}/stream`

  const startStream = async () => {
    if (streaming) return
    if (!sandboxReady) {
      setConnectionStatus('Waiting for sandbox...')
      return
    }
    setConnectionStatus('Connecting...')
    setStreaming(true)
    const controller = new AbortController()
    streamAbortRef.current = controller
    let hadError = false
    let finalStatus: string | null = null

    try {
      const res = await fetch(
        `${streamUrl}?cursor=${state.cursor}&follow=1`,
        {
          method: 'GET',
          signal: controller.signal,
        },
      )
      if (!res.ok || !res.body) {
        const text = await res.text()
        const error = new Error(`Stream failed (${res.status}): ${text}`)
        ;(error as { status?: number }).status = res.status
        throw error
      }

      setConnectionStatus('Connected')
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buffer = ''

      while (true) {
        const { value, done } = await reader.read()
        if (done) break
        buffer += decoder.decode(value, { stream: true })
        const parts = buffer.split(/\r?\n\r?\n/)
        buffer = parts.pop() || ''

        for (const part of parts) {
          if (!part.trim()) continue
          const parsed = parseSseChunk(part)
          if (!parsed.data) continue
          try {
            const envelope = JSON.parse(
              parsed.data,
            ) as StreamEnvelope<SandboxDaemonEvent>
            if (
              typeof envelope.cursor === 'number' &&
              envelope.event &&
              typeof envelope.event === 'object'
            ) {
              dispatchEnvelope(envelope)
            }
          } catch {
            // ignore malformed chunks
          }
        }
      }
    } catch (err) {
      const isAbort = err && typeof err === 'object' &&
        (err as { name?: string }).name === 'AbortError'
      if (!isAbort) {
        const status = err && typeof err === 'object'
          ? (err as { status?: number }).status
          : undefined
        const message = err instanceof Error ? err.message : String(err)
        const lower = message.toLowerCase()
        const transient = status === 502 || status === 503 ||
          lower.includes('connection refused') ||
          lower.includes('failed to fetch')
        if (transient) {
          finalStatus = 'Waiting for sandbox...'
          if (!retryRef.current) {
            retryRef.current = setTimeout(() => {
              retryRef.current = null
              if (sandboxReadyRef.current) {
                void startStream()
              }
            }, 2000) as unknown as number
          }
        } else {
          hadError = true
          finalStatus = 'Stream error'
          console.error('Stream error', message)
        }
      }
    } finally {
      setStreaming(false)
      streamAbortRef.current = null
      if (finalStatus) {
        setConnectionStatus(finalStatus)
      } else if (!hadError) {
        setConnectionStatus(
          sandboxReadyRef.current ? 'Disconnected' : 'Waiting for sandbox...',
        )
      }
    }
  }

  const stopStream = () => {
    if (streamAbortRef.current) {
      streamAbortRef.current.abort()
    }
  }

  useEffect(() => {
    if (sandboxReady) {
      void startStream()
    } else {
      setConnectionStatus('Waiting for sandbox...')
      stopStream()
    }
    return () => {
      stopStream()
    }
  }, [streamUrl, sandboxReady])

  useEffect(() => {
    if (sandboxReady) return
    const interval = setInterval(() => {
      revalidator.revalidate()
    }, 3000)
    return () => clearInterval(interval)
  }, [revalidator, sandboxReady])

  const handleSendPrompt = async () => {
    const text = prompt.trim()
    if (!text) return

    if (!streaming) {
      void startStream()
    }

    setPrompt('')

    fetcher.submit(
      { _action: 'prompt', message: text },
      { method: 'post' },
    )
  }

  const handleAbort = () => {
    fetcher.submit({ _action: 'abort' }, { method: 'post' })
  }

  const clearConversation = () => {
    dispatchEnvelope({
      cursor: 0,
      event: {
        source: 'daemon',
        type: 'reset',
      } as SandboxDaemonEvent,
    })
  }

  const clearActivities = () => {
    dispatchEnvelope({
      cursor: state.cursor,
      event: {
        source: 'daemon',
        type: 'clear_activities',
      } as SandboxDaemonEvent,
    })
  }

  const handlePromptKeyDown = (
    event: KeyboardEvent<HTMLTextAreaElement>,
  ) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      void handleSendPrompt()
    }
  }

  return (
    <div className='app'>
      <Link to='/'>← Back</Link>
      <header className='hero' style={{ marginTop: '16px' }}>
        <div className='hero__text'>
          <p className='eyebrow'>Wuhu Sandbox</p>
          <h1>{sandbox.name || sandbox.id}</h1>
          <p className='subtext'>
            Repo: <strong>{sandbox.repoFullName ?? 'None'}</strong>
          </p>
          <p className='subtext'>
            Preview:{' '}
            <a href={sandbox.previewUrl} target='_blank' rel='noreferrer'>
              {sandbox.previewUrl}
            </a>
          </p>
        </div>
        <div className='status'>
          <div className='status__label'>Connection</div>
          <div className='status__value'>{connectionStatus}</div>
          <div className='status__meta'>Agent: {state.agentStatus}</div>
          <div className='status__meta'>Cursor: {state.cursor}</div>
          <div className='status__meta'>
            Last agent event: {state.lastEventType || 'None'}
          </div>
        </div>
      </header>

      <section className='panel grid'>
        <div className='panel__block'>
          <label>Sandbox Status</label>
          <div>
            <strong>{sandbox.status}</strong>
          </div>
          <div className='helper'>Namespace: {sandbox.namespace}</div>
          <div className='helper'>Job: {sandbox.jobName}</div>
          <div className='helper'>Pod: {sandbox.podName ?? 'Pending'}</div>
          <div className='helper'>Pod IP: {sandbox.podIp ?? 'Pending'}</div>
        </div>
        <div className='panel__block panel__actions'>
          <label>Connection controls</label>
          <div className='actions'>
            <button
              type='button'
              onClick={startStream}
              disabled={streaming || !sandboxReady}
            >
              Connect
            </button>
            <button
              type='button'
              className='ghost'
              onClick={stopStream}
              disabled={!streaming}
            >
              Disconnect
            </button>
          </div>
          <p className='helper'>Status: {connectionStatus}</p>
        </div>
        <div className='panel__block panel__actions'>
          <label>Sandbox actions</label>
          <div className='actions'>
            <Form method='post'>
              <button type='submit' name='_action' value='kill'>
                Kill Sandbox
              </button>
            </Form>
          </div>
          <p className='helper'>Kill stops the job and clears the pod.</p>
        </div>
      </section>

      <section className='workspace'>
        <div className='panel chat'>
          <div className='panel__header chat__header'>
            <div>
              <h2>Agent Thread</h2>
              <p className='subtext small'>
                Messages stream from the agent. Use Shift+Enter for a new line.
              </p>
            </div>
            <div className='controls'>
              <button
                type='button'
                className='ghost'
                onClick={handleAbort}
                disabled={!streaming}
              >
                Abort
              </button>
              <button type='button' onClick={clearConversation}>
                Clear
              </button>
            </div>
          </div>

          <div className='chat__log' ref={logRef}>
            {!sandboxReady
              ? (
                <div className='chat__empty'>
                  Waiting for the sandbox to start.
                </div>
              )
              : state.messages.length === 0
              ? (
                <div className='chat__empty'>
                  No messages yet. Send a prompt to begin.
                </div>
              )
              : (
                state.messages.map((message) => (
                  <div
                    key={message.id}
                    className={`message message--${message.role} ${
                      message.status === 'streaming' ? 'message--streaming' : ''
                    }`}
                  >
                    <div className='message__meta'>
                      <span>{message.title || message.role}</span>
                      {message.status === 'streaming'
                        ? <span className='message__status'>typing</span>
                        : null}
                      {message.timestamp
                        ? <span>{message.timestamp}</span>
                        : null}
                    </div>
                    <div className='message__bubble'>
                      {message.title &&
                          (message.role === 'system' || message.role === 'tool')
                        ? <div className='message__title'>{message.title}</div>
                        : null}
                      <div className='message__text'>
                        {message.text ||
                          (message.status === 'streaming' ? '...' : '')}
                      </div>
                      {message.toolCalls && message.toolCalls.length
                        ? (
                          <div className='message__tools'>
                            {message.toolCalls.map((tool) => (
                              <span
                                key={tool.id || tool.name}
                                className='tool-chip'
                              >
                                {tool.name}
                              </span>
                            ))}
                          </div>
                        )
                        : null}
                      {message.thinking
                        ? (
                          <details className='message__thinking'>
                            <summary>Reasoning</summary>
                            <pre>{message.thinking}</pre>
                          </details>
                        )
                        : null}
                    </div>
                  </div>
                ))
              )}
          </div>

          <form
            className='composer'
            onSubmit={(event) => {
              event.preventDefault()
              void handleSendPrompt()
            }}
          >
            <textarea
              rows={3}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={handlePromptKeyDown}
              placeholder='Describe the coding task you want the agent to do...'
              disabled={!sandboxReady}
            />
            <div className='composer__actions'>
              <span className='composer__hint'>Shift+Enter for new line</span>
              <button
                type='submit'
                className='primary'
                disabled={!prompt.trim() || !sandboxReady}
              >
                Send
              </button>
            </div>
          </form>
        </div>

        <aside className='panel side'>
          <div className='panel__header'>
            <h2>Activity</h2>
            <button
              type='button'
              className='ghost'
              onClick={clearActivities}
              disabled={state.activities.length === 0}
            >
              Clear
            </button>
          </div>
          <div className='activity'>
            {state.activities.length === 0
              ? (
                <div className='activity__empty'>
                  No tool activity yet.
                </div>
              )
              : (
                state.activities.map((item) => (
                  <div key={item.id} className='activity__card'>
                    <div className='activity__meta'>
                      <span
                        className={`activity__status activity__status--${item.status}`}
                      >
                        {item.status}
                      </span>
                      <span>{item.toolName}</span>
                      <span>{item.updatedAt}</span>
                    </div>
                    {item.output
                      ? (
                        <pre className='activity__output'>
                          {item.output}
                        </pre>
                      )
                      : null}
                  </div>
                ))
              )}
          </div>
          <div className='side__footer'>
            <div className='side__tip'>
              Tip: keep the stream connected so the agent replies land here.
            </div>
          </div>
        </aside>
      </section>
    </div>
  )
}
