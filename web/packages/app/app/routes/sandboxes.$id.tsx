import { Form, Link, redirect, useLoaderData } from 'react-router'
import { useEffect, useMemo, useState } from 'react'
import type { Route } from './+types/sandboxes.$id.ts'
import {
  abortSandbox,
  sendSandboxPrompt,
  useSandboxStreams,
} from '~/lib/sandbox/use-sandbox.ts'
import type { UiMessage } from '~/lib/sandbox/types.ts'
import { queuedPromptIsRecordedInCoding } from '~/lib/sandbox/dedup.ts'

function formatTimestamp(value?: number): string {
  const date = value ? new Date(value) : new Date()
  return date.toLocaleTimeString([], { hour12: false })
}

export async function loader({ params }: Route.LoaderArgs) {
  const apiUrl = Deno.env.get('API_URL')
  if (!apiUrl) {
    throw new Response('API_URL environment variable is not configured', {
      status: 500,
    })
  }
  const response = await fetch(`${apiUrl}/sandboxes/${params.id}`)
  if (!response.ok) {
    throw new Response('Sandbox not found', { status: 404 })
  }
  const data = await response.json()
  return { sandbox: data.sandbox }
}

export async function action({ params, request }: Route.ActionArgs) {
  const apiUrl = Deno.env.get('API_URL')
  if (!apiUrl) {
    throw new Response('API_URL environment variable is not configured', {
      status: 500,
    })
  }

  const formData = await request.formData()
  const actionType = String(formData.get('_action') ?? '')

  if (actionType === 'kill') {
    await fetch(`${apiUrl}/sandboxes/${params.id}/kill`, { method: 'POST' })
    return redirect('/')
  }

  return null
}

export default function SandboxDetail() {
  const { sandbox } = useLoaderData<typeof loader>()
  const { coding, control, connectionStatus } = useSandboxStreams(sandbox.id)
  const [prompt, setPrompt] = useState('')
  const [pendingPrompts, setPendingPrompts] = useState<UiMessage[]>([])
  const [sendError, setSendError] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const [aborting, setAborting] = useState(false)

  const statusColor = useMemo(() => {
    if (
      control.statusLabel === 'Ready' || control.statusLabel === 'Initialized'
    ) {
      return '#0ea5e9'
    }
    if (control.statusLabel.includes('error')) return '#ef4444'
    if (control.statusLabel === 'Terminated') return '#6b7280'
    return '#a855f7'
  }, [control.statusLabel])

  const handleSend = async () => {
    const text = prompt.trim()
    if (!text || sending) return
    setSendError(null)
    setSending(true)
    setPrompt('')
    const localPrompt: UiMessage = {
      id: `local-prompt-${Date.now()}`,
      role: 'user',
      title: 'You',
      text,
      status: 'complete',
      timestamp: formatTimestamp(),
    }
    setPendingPrompts((prev) => [...prev, localPrompt].slice(-20))
    try {
      await sendSandboxPrompt({ sandboxId: sandbox.id, message: text })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setSendError(message)
    } finally {
      setSending(false)
    }
  }

  useEffect(() => {
    if (!pendingPrompts.length) return
    const queuedMessages = new Set(control.prompts.map((p) => p.message))
    setPendingPrompts((prev) => prev.filter((m) => !queuedMessages.has(m.text)))
  }, [control.prompts, pendingPrompts.length])

  const displayMessages = useMemo(() => {
    const controlMessages: UiMessage[] = control.prompts
      .filter((p) => {
        // The daemon emits `prompt_queued` (control stream) and the agent later
        // replays the same user message in the coding stream. Hide the queued
        // prompt once we see a matching user message at/after that cursor.
        return !queuedPromptIsRecordedInCoding(p, coding.messages)
      })
      .map((p) => ({
        id: `queued-prompt-${p.cursor}`,
        role: 'user',
        title: 'You',
        text: p.message,
        status: 'pending',
        cursor: p.cursor,
        timestamp: formatTimestamp(p.timestamp),
      }))

    const all = [...controlMessages, ...coding.messages, ...pendingPrompts]
    const byId = new Map<string, UiMessage>()
    for (const m of all) {
      if (!byId.has(m.id)) byId.set(m.id, m)
    }
    return [...byId.values()].sort((a, b) => {
      const aCursor = a.cursor ?? Number.POSITIVE_INFINITY
      const bCursor = b.cursor ?? Number.POSITIVE_INFINITY
      if (aCursor !== bCursor) return aCursor - bCursor
      return a.id.localeCompare(b.id)
    })
  }, [coding.messages, control.prompts, pendingPrompts])

  const handleAbort = async () => {
    if (aborting) return
    setAborting(true)
    try {
      await abortSandbox({ sandboxId: sandbox.id })
    } finally {
      setAborting(false)
    }
  }

  return (
    <div style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem' }}>
      <Link to='/'>← Back</Link>
      <div
        style={{
          display: 'flex',
          alignItems: 'baseline',
          justifyContent: 'space-between',
          gap: '1rem',
        }}
      >
        <h1 style={{ marginBottom: '0.5rem' }}>{sandbox.name || sandbox.id}</h1>
        <div style={{ display: 'flex', gap: '0.5rem', alignItems: 'center' }}>
          <span
            style={{
              fontSize: '0.875rem',
              padding: '0.25rem 0.5rem',
              borderRadius: '999px',
              border: `1px solid ${statusColor}`,
              color: statusColor,
              background: 'rgba(2, 132, 199, 0.08)',
              whiteSpace: 'nowrap',
            }}
          >
            {control.statusLabel}
          </span>
          <span style={{ color: '#6b7280', fontSize: '0.875rem' }}>
            {connectionStatus}
          </span>
        </div>
      </div>

      <p style={{ marginTop: 0 }}>
        Pod status: <strong>{sandbox.status}</strong>
      </p>
      <p>
        Repo: <strong>{sandbox.repoFullName ?? 'None'}</strong>
      </p>
      <p>
        Preview:{' '}
        <a href={sandbox.previewUrl} target='_blank' rel='noreferrer'>
          {sandbox.previewUrl}
        </a>
      </p>
      <p>Namespace: {sandbox.namespace}</p>
      <p>Job: {sandbox.jobName}</p>
      <p>Pod: {sandbox.podName ?? 'Pending'}</p>
      <p>Pod IP: {sandbox.podIp ?? 'Pending'}</p>

      {control.error
        ? (
          <div style={{ color: '#ef4444', margin: '0.5rem 0' }}>
            {control.error}
          </div>
        )
        : null}

      <section style={{ marginTop: '1.5rem' }}>
        <h2 style={{ marginBottom: '0.5rem' }}>Agent Chat</h2>
        <div
          style={{
            border: '1px solid #e5e7eb',
            borderRadius: 8,
            padding: '1rem',
            background: '#fff',
          }}
        >
          <div
            style={{ display: 'flex', gap: '0.5rem', marginBottom: '0.75rem' }}
          >
            <button type='button' onClick={handleAbort} disabled={aborting}>
              Abort
            </button>
            <Form method='post'>
              <button type='submit' name='_action' value='kill'>
                Kill Sandbox
              </button>
            </Form>
            <div
              style={{
                marginLeft: 'auto',
                color: '#6b7280',
                fontSize: '0.875rem',
              }}
            >
              Agent: {coding.agentStatus} · Cursor: {coding.cursor}
            </div>
          </div>

          <div
            style={{
              border: '1px solid #f3f4f6',
              borderRadius: 8,
              padding: '0.75rem',
              height: 360,
              overflow: 'auto',
              background: '#fafafa',
            }}
          >
            {displayMessages.length === 0
              ? <div style={{ color: '#6b7280' }}>Waiting for messages…</div>
              : (
                <div style={{ display: 'grid', gap: '0.75rem' }}>
                  {displayMessages.map((message) => (
                    <div
                      key={message.id}
                      style={{
                        border: '1px solid #e5e7eb',
                        borderRadius: 8,
                        padding: '0.75rem',
                        background: '#fff',
                      }}
                    >
                      <div
                        style={{
                          display: 'flex',
                          gap: '0.5rem',
                          justifyContent: 'space-between',
                          color: '#6b7280',
                          fontSize: '0.875rem',
                          marginBottom: '0.25rem',
                        }}
                      >
                        <span>
                          {message.title || message.role}
                          {message.status === 'streaming' ? ' (typing)' : ''}
                        </span>
                        <span>{message.timestamp ?? ''}</span>
                      </div>
                      <pre
                        style={{
                          margin: 0,
                          whiteSpace: 'pre-wrap',
                          wordBreak: 'break-word',
                          fontFamily:
                            'ui-monospace, SFMono-Regular, Menlo, monospace',
                          fontSize: '0.95rem',
                        }}
                      >
                        {message.text || (message.status === 'streaming' ? '...' : '')}
                      </pre>
                      {message.toolCalls?.length
                        ? (
                          <div
                            style={{
                              display: 'flex',
                              flexWrap: 'wrap',
                              gap: '0.25rem',
                              marginTop: '0.5rem',
                            }}
                          >
                            {message.toolCalls.map((tool) => (
                              <span
                                key={tool.id || tool.name}
                                style={{
                                  border: '1px solid #e5e7eb',
                                  borderRadius: 999,
                                  padding: '0.125rem 0.5rem',
                                  fontSize: '0.75rem',
                                  color: '#374151',
                                  background: '#f9fafb',
                                }}
                              >
                                {tool.name}
                              </span>
                            ))}
                          </div>
                        )
                        : null}
                      {message.thinking
                        ? (
                          <details style={{ marginTop: '0.5rem' }}>
                            <summary style={{ cursor: 'pointer' }}>
                              Reasoning
                            </summary>
                            <pre
                              style={{
                                margin: '0.5rem 0 0',
                                whiteSpace: 'pre-wrap',
                                wordBreak: 'break-word',
                                fontFamily:
                                  'ui-monospace, SFMono-Regular, Menlo, monospace',
                                fontSize: '0.85rem',
                                color: '#6b7280',
                              }}
                            >
                              {message.thinking}
                            </pre>
                          </details>
                        )
                        : null}
                    </div>
                  ))}
                </div>
              )}
          </div>

          <div style={{ marginTop: '0.75rem' }}>
            <textarea
              rows={3}
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder='Send a follow-up prompt…'
              style={{
                width: '100%',
                padding: '0.5rem',
                borderRadius: 8,
                border: '1px solid #e5e7eb',
              }}
            />
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                marginTop: '0.5rem',
              }}
            >
              <div style={{ color: '#6b7280', fontSize: '0.875rem' }}>
                Shift+Enter for a new line.
              </div>
              <button
                type='button'
                onClick={handleSend}
                disabled={!prompt.trim() || sending}
              >
                Send
              </button>
            </div>
            {sendError
              ? <div style={{ color: '#ef4444' }}>{sendError}</div>
              : null}
          </div>
        </div>
      </section>
    </div>
  )
}
