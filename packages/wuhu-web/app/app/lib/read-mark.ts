import type { MessageMap } from './conversation.ts'

// The newest ordinal a conversation shows, or 0 while it is empty: an empty
// conversation still clears whatever the sidebar thinks is unread.
export function latestOrdinal(messages: MessageMap): number {
  let latest = 0
  for (const message of messages.values()) latest = Math.max(latest, message.n)
  return latest
}

// What a conversation view has marked read. It marks once when a live
// snapshot is first read and again whenever a newer message arrives while the
// page stays read; a hidden or unfocused tab and a reconnecting stream mark
// nothing. Regaining focus forgets the mark, so a watermark POST that failed
// gets its retry then.
export class ReadMark {
  private through = -1
  private reading = false

  advance(latest: number, reading: boolean, live: boolean): boolean {
    if (reading && !this.reading) this.through = -1
    this.reading = reading
    if (!reading || !live || latest <= this.through) return false
    this.through = latest
    return true
  }
}
