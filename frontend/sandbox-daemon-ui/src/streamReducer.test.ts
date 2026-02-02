import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import type { SandboxDaemonEvent, StreamEnvelope } from './types'
import { initialUiState } from './types'
import { reduceEnvelope, reduceEnvelopes } from './streamReducer'

function parseFixture(): Array<StreamEnvelope<SandboxDaemonEvent>> {
  const path = resolve(__dirname, 'fixtures', 'sample-stream.sse')
  const raw = readFileSync(path, 'utf8')
  const blocks = raw.split(/\r?\n\r?\n/)

  const envelopes: Array<StreamEnvelope<SandboxDaemonEvent>> = []
  for (const block of blocks) {
    const lines = block.split(/\r?\n/)
    const dataLines: string[] = []
    for (const line of lines) {
      if (!line.startsWith('data:')) continue
      dataLines.push(line.slice('data:'.length).trimStart())
    }
    if (!dataLines.length) continue
    const json = dataLines.join('\n')
    try {
      const env = JSON.parse(json) as StreamEnvelope<SandboxDaemonEvent>
      if (typeof env.cursor === 'number' && env.event) {
        envelopes.push(env)
      }
    } catch {
      // ignore malformed lines
    }
  }
  return envelopes
}

describe('streamReducer', () => {
  const envelopes = parseFixture()

  it('produces messages in chronological order with no streaming leftovers', () => {
    const state = reduceEnvelopes(envelopes)
    // No message should remain in 'streaming' state at the end of the log.
    expect(state.messages.every((m) => m.status !== 'streaming')).toBe(true)

    const userIndex = state.messages.findIndex((m) =>
      m.role === 'user' && m.text.includes('pwd')
    )
    const assistantIndex = state.messages.findIndex((m) =>
      m.role === 'assistant' && m.text.includes('Working directory')
    )

    expect(userIndex).toBeGreaterThanOrEqual(0)
    expect(assistantIndex).toBeGreaterThan(userIndex)
  })

  it('does not duplicate tool calls/results for the same toolCallId', () => {
    const state = reduceEnvelopes(envelopes)
    const toolMessages = state.messages.filter((m) => m.role === 'tool')
    const ids = toolMessages.map((m) => m.id)
    const uniqueIds = new Set(ids)
    expect(uniqueIds.size).toBe(ids.length)
  })

  it('supports clearing UI state via daemon reset event', () => {
    const base = reduceEnvelopes(envelopes)
    expect(base.messages.length).toBeGreaterThan(0)

    const reset = reduceEnvelope(base, {
      cursor: 0,
      event: { source: 'daemon', type: 'reset' },
    })

    expect(reset).toEqual(initialUiState)
  })

  it('supports clearing activity without touching messages', () => {
    const base = reduceEnvelopes(envelopes)
    const env: StreamEnvelope<SandboxDaemonEvent> = {
      cursor: base.cursor,
      event: { source: 'daemon', type: 'clear_activities' },
    }

    const next = reduceEnvelope(base, env)
    expect(next.messages).toEqual(base.messages)
    expect(next.activities).toEqual([])
    expect(next.cursor).toBe(base.cursor)
    expect(next.lastEventType).toBe(base.lastEventType)
  })
})
