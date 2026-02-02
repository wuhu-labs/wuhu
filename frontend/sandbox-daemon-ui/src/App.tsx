import React, { useEffect, useMemo, useReducer, useRef, useState } from 'react'
import {
  initialUiState,
  type SandboxDaemonEvent,
  type StreamEnvelope,
  type UiState,
} from './types'
import { reduceEnvelope } from './streamReducer'

const STORAGE_KEY_BASE = 'sandbox-daemon-ui.baseUrl'
const STORAGE_KEY_TOKEN = 'sandbox-daemon-ui.jwt'

function normalizeBaseUrl(value: string): string {
  if (!value) return ''
  return value.replace(/\/+$/, '')
}

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

function formatTimestamp(value?: number | string): string {
  const now = value ? new Date(value) : new Date()
  return now.toLocaleTimeString([], { hour12: false })
}

export default function App() {
  const [baseUrl, setBaseUrl] = useState(() =>
    normalizeBaseUrl(localStorage.getItem(STORAGE_KEY_BASE) || '')
  )
  const [token, setToken] = useState(() =>
    localStorage.getItem(STORAGE_KEY_TOKEN) || ''
  )
  const [prompt, setPrompt] = useState('')
  const [connectionStatus, setConnectionStatus] = useState('Disconnected')
  const [streaming, setStreaming] = useState(false)

  const [state, dispatchEnvelope] = useReducer(
    (s: UiState, env: StreamEnvelope<SandboxDaemonEvent>) =>
      reduceEnvelope(s, env),
    initialUiState,
  )

  const streamAbortRef = useRef<AbortController | null>(null)
  const logRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY_BASE, baseUrl)
  }, [baseUrl])

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY_TOKEN, token)
  }, [token])

  useEffect(() => {
    if (!logRef.current) return
    logRef.current.scrollTop = logRef.current.scrollHeight
  }, [state.messages])

  useEffect(() => {
    if (streaming) {
      stopStream()
    }
  }, [baseUrl, token])

  const headers = useMemo(() => {
    const result: Record<string, string> = {
      'content-type': 'application/json',
    }
    const trimmed = token.trim()
    if (trimmed) {
      result.authorization = `Bearer ${trimmed}`
    }
    return result
  }, [token])

  const streamHeaders = useMemo(() => {
    const result: Record<string, string> = {}
    const trimmed = token.trim()
    if (trimmed) {
      result.authorization = `Bearer ${trimmed}`
    }
    return result
  }, [token])

  const startStream = async () => {
    if (streaming) return
    if (!baseUrl) {
      setConnectionStatus('Missing daemon URL')
      return
    }
    setConnectionStatus('Connecting...')
    setStreaming(true)
    const controller = new AbortController()
    streamAbortRef.current = controller

    try {
      const res = await fetch(
        `${baseUrl}/stream?cursor=${state.cursor}&follow=1`,
        {
          method: 'GET',
          headers: streamHeaders,
          signal: controller.signal,
        },
      )
      if (!res.ok || !res.body) {
        const text = await res.text()
        throw new Error(`Stream failed (${res.status}): ${text}`)
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
        (err as any).name === 'AbortError'
      if (!isAbort) {
        const message = err instanceof Error ? err.message : String(err)
        console.error('Stream error', message)
        setConnectionStatus('Stream error')
      }
    } finally {
      setStreaming(false)
      setConnectionStatus('Disconnected')
      streamAbortRef.current = null
    }
  }

  const stopStream = () => {
    if (streamAbortRef.current) {
      streamAbortRef.current.abort()
    }
  }

  const handleSendPrompt = async () => {
    if (!baseUrl) {
      setConnectionStatus('Missing daemon URL')
      return
    }
    const text = prompt.trim()
    if (!text) return

    if (!streaming) {
      void startStream()
    }

    setPrompt('')

    try {
      const res = await fetch(`${baseUrl}/prompt`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ message: text }),
      })
      if (!res.ok) {
        const errorText = await res.text()
        throw new Error(`Prompt failed (${res.status}): ${errorText}`)
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      console.error('Prompt error', message)
    }
  }

  const handleAbort = async () => {
    if (!baseUrl) return
    try {
      const res = await fetch(`${baseUrl}/abort`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ reason: 'user_abort' }),
      })
      if (!res.ok) {
        const errorText = await res.text()
        throw new Error(`Abort failed (${res.status}): ${errorText}`)
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      console.error('Abort failed', message)
    }
  }

  const clearConversation = () => {
    dispatchEnvelope({
      cursor: 0,
      event: {
        source: 'daemon',
        type: 'reset',
      } as any,
    })
  }

  const clearActivities = () => {
    dispatchEnvelope({
      cursor: state.cursor,
      event: {
        source: 'daemon',
        type: 'clear_activities',
      } as any,
    })
  }

  const handlePromptKeyDown = (
    event: React.KeyboardEvent<HTMLTextAreaElement>,
  ) => {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      void handleSendPrompt()
    }
  }

  return (
    <div className='app'>
      <header className='hero'>
        <div className='hero__text'>
          <p className='eyebrow'>Wuhu Sandbox</p>
          <h1>Agent Workbench</h1>
          <p className='subtext'>
            Connect to a sandbox daemon, give the agent a task, and watch it
            respond in real time.
          </p>
        </div>
        <div className='status'>
          <div className='status__label'>Connection</div>
          <div className='status__value'>{connectionStatus}</div>
          <div className='status__meta'>Agent: {state.agentStatus}</div>
          <div className='status__meta'>Cursor: {state.cursor}</div>
          <div className='status__meta'>
            Last event: {state.lastEventType || 'None'}
          </div>
        </div>
      </header>

      <section className='panel grid'>
        <div className='panel__block'>
          <label htmlFor='base-url'>Daemon base URL</label>
          <input
            id='base-url'
            type='url'
            placeholder='https://xxxx.modal.host'
            value={baseUrl}
            onChange={(e) => setBaseUrl(normalizeBaseUrl(e.target.value))}
          />
        </div>
        <div className='panel__block'>
          <label htmlFor='token'>JWT (optional)</label>
          <input
            id='token'
            type='password'
            placeholder='Bearer token for production'
            value={token}
            onChange={(e) => setToken(e.target.value)}
          />
        </div>
        <div className='panel__block panel__actions'>
          <label>Connection controls</label>
          <div className='actions'>
            <button type='button' onClick={startStream} disabled={streaming}>
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
          <p className='helper'>
            Status: {connectionStatus}
          </p>
        </div>
      </section>

      <section className='workspace'>
        <div className='panel chat'>
          <div className='panel__header chat__header'>
            <div>
              <h2>Agent Thread</h2>
              <p className='subtext small'>
                Messages stream from the daemon. Use Shift+Enter for a new line.
              </p>
            </div>
            <div className='controls'>
              <button
                type='button'
                className='ghost'
                onClick={handleAbort}
                disabled={!baseUrl}
              >
                Abort
              </button>
              <button type='button' onClick={clearConversation}>
                Clear
              </button>
            </div>
          </div>

          <div className='chat__log' ref={logRef}>
            {state.messages.length === 0
              ? (
                <div className='chat__empty'>
                  No messages yet. Connect to the daemon and send a prompt.
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
            />
            <div className='composer__actions'>
              <span className='composer__hint'>Shift+Enter for new line</span>
              <button
                type='submit'
                className='primary'
                disabled={!prompt.trim() || !baseUrl}
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
