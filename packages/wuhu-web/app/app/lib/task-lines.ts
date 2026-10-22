import type { ChatEntry } from './chat.ts'
import { eventKey, type WorkEvent } from './work-events.ts'

export interface TaskLine extends ChatEntry {
  text: string
}

// The tools a task speaks through; their text is what it said.
const spoken: Record<string, string> = {
  send_message: 'message',
  report: 'content',
}

function spokenText(name: string, args: unknown): string | null {
  const key = spoken[name]
  if (key === undefined || args == null || typeof args !== 'object') {
    return null
  }
  const value = (args as Record<string, unknown>)[key]
  return typeof value === 'string' && value.trim() !== '' ? value : null
}

// A task's transcript as chat lines: every message it was handed is the
// sender's (the brief is its parent's), on the reader's side; its own text
// and what it sent or reported are its own. Reasoning, tool calls and their
// results, notices and bookmarks are not drawn. An event without a time takes
// the last known one, so a streaming reply sits after what it answers.
export function taskLines(events: readonly WorkEvent[]): TaskLine[] {
  const lines: TaskLine[] = []
  let at = new Date(0)
  for (const event of events) {
    if (event.timestamp !== null) at = event.timestamp
    const key = eventKey(event.id)
    if (event.kind === 'input' && event.input.text.trim() !== '') {
      lines.push({
        key,
        sender: event.input.sender,
        own: true,
        at,
        text: event.input.text,
      })
    } else if (event.kind === 'assistantText' && event.text.trim() !== '') {
      lines.push({ key, sender: 'task', own: false, at, text: event.text })
    } else if (event.kind === 'toolCall') {
      const text = spokenText(event.call.name, event.call.arguments)
      if (text !== null) {
        lines.push({ key, sender: 'task', own: false, at, text })
      }
    }
  }
  return lines
}
