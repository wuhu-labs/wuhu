// A chat page's layout, Messages-style: runs of one sender's messages, a run
// ending at a sender change or a gap over 15 minutes, and a time stamp
// wherever the day changes or such a gap falls.

export const runGapMs = 15 * 60 * 1000

export interface ChatEntry {
  key: string
  sender: string
  own: boolean
  at: Date
}

export type ChatItem<T extends ChatEntry> =
  | { kind: 'stamp'; key: string; at: Date }
  | { kind: 'run'; key: string; sender: string; own: boolean; entries: T[] }

function dayOf(at: Date): number {
  return new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime()
}

// Entries in display order.
export function chatItems<T extends ChatEntry>(
  entries: readonly T[],
): ChatItem<T>[] {
  const items: ChatItem<T>[] = []
  let previous: T | null = null
  let run: Extract<ChatItem<T>, { kind: 'run' }> | null = null
  for (const entry of entries) {
    if (
      previous === null || dayOf(entry.at) !== dayOf(previous.at) ||
      entry.at.getTime() - previous.at.getTime() > runGapMs
    ) {
      run = null
      items.push({ kind: 'stamp', key: `stamp:${entry.key}`, at: entry.at })
    }
    if (run !== null && run.sender === entry.sender && run.own === entry.own) {
      run.entries.push(entry)
    } else {
      run = {
        kind: 'run',
        key: entry.key,
        sender: entry.sender,
        own: entry.own,
        entries: [entry],
      }
      items.push(run)
    }
    previous = entry
  }
  return items
}

// English, like the rest of the web, whatever the browser's locale.
const clock = new Intl.DateTimeFormat('en', {
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
})
const date = new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric' })
const dateWithYear = new Intl.DateTimeFormat('en', {
  month: 'short',
  day: 'numeric',
  year: 'numeric',
})

// The stamp: Today, Yesterday or the date, then the time.
export function stampLabel(at: Date, now: Date): string {
  const days = Math.round((dayOf(now) - dayOf(at)) / 86_400_000)
  const day = days === 0
    ? 'Today'
    : days === 1
    ? 'Yesterday'
    : at.getFullYear() === now.getFullYear()
    ? date.format(at)
    : dateWithYear.format(at)
  return `${day} ${clock.format(at)}`
}
