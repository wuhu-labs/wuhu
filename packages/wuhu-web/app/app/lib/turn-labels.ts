import type { Outgoing, ToolState, Wake } from './turns.ts'

export interface Names {
  session(id: string): string | undefined
  principal(id: string): string
}

export function noticeLabel(kind: string): string {
  switch (kind) {
    case 'timer':
      return 'Timer'
    case 'spaceObservation':
      return 'Observation'
    case 'script':
      return 'Script update'
    case 'owedReply':
      return 'Owed reply'
    case 'parkReminder':
      return 'Park reminder'
    case 'childFailed':
      return 'Child failed'
    case 'requestDeadline':
      return 'Request deadline'
    case 'compactRequest':
      return 'Compaction request'
    case 'context':
      return 'Context notice'
    case 'restart':
      return 'Started over'
    case '':
      return 'Notification'
    default:
      return kind.slice(0, 1).toUpperCase() + kind.slice(1)
  }
}

export interface WakeLabel {
  tag: string | null
  tone: 'report' | 'request' | 'system'
  name: string | null
  timestamp: Date | null
}

// A request or report is tagged the same wherever a message shows.
export function kindTag(
  kind: string,
): { tag: string; tone: 'report' | 'request' } | null {
  switch (kind) {
    case 'final':
    case 'progress':
      return { tag: `Report · ${kind}`, tone: 'report' }
    case 'request':
      return { tag: 'Request', tone: 'request' }
    default:
      return null
  }
}

export function wakeLabel(wake: Wake, names: Names): WakeLabel {
  const { timestamp } = wake
  if (wake.source.kind === 'notice') {
    return {
      tag: noticeLabel(wake.source.notice.kind),
      tone: 'system',
      name: null,
      timestamp,
    }
  }
  const input = wake.source.input
  const session = input.senderSession === null
    ? undefined
    : names.session(input.senderSession)
  const name = session ??
    (input.sender === '' ? 'Input' : names.principal(input.sender))
  const tagged = kindTag(input.kind)
  return tagged === null
    ? { tag: null, tone: 'system', name, timestamp }
    : { ...tagged, name, timestamp }
}

export function sendTarget(sent: Outgoing, names: Names): string {
  const target = sent.target
  switch (target.kind) {
    case 'box':
      return '→ box'
    case 'session':
      return `→ DM ${names.session(target.id) ?? target.id}`
    case 'user':
      return `→ DM ${names.principal(target.id)}`
    case 'conversation':
      return `→ ${target.id}`
    case 'report':
      return target.report === 'progress' ? 'progress' : 'final report'
  }
}

export const toolStateLabel: Record<ToolState, string> = {
  running: 'Running',
  done: 'Done',
  failed: 'Failed',
}

export function durationText(seconds: number): string {
  const whole = Math.round(seconds)
  if (whole < 60) return `${whole}s`
  const minutes = Math.floor(whole / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  return minutes % 60 === 0 ? `${hours}h` : `${hours}h ${minutes % 60}m`
}

export function summaryText(tools: number, duration: number | null): string {
  const count = tools === 0
    ? 'no tools'
    : tools === 1
    ? '1 tool'
    : `${tools} tools`
  return duration === null ? count : `${count} · ${durationText(duration)}`
}

// The reader's locale and time zone unless a test pins them; the date shows
// only when the wake-up was not today.
export function wakeTime(
  date: Date,
  now: Date,
  locale?: string,
  timeZone?: string,
): string {
  const day = new Intl.DateTimeFormat(locale, {
    timeZone,
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  })
  const today = day.format(date) === day.format(now)
  return new Intl.DateTimeFormat(locale, {
    timeZone,
    ...(today ? {} : { month: 'short', day: 'numeric' }),
    hour: 'numeric',
    minute: '2-digit',
  }).format(date)
}

// Paragraph breaks cost a whole line each in a preview clamped to a few.
export function preview(text: string): string {
  return text.split(/\r?\n/).map((line) => line.trim())
    .filter((line) => line !== '').join('\n')
}

export function firstLine(text: string): string {
  return text.split(/\r?\n/).find((line) => line.trim() !== '')?.trim() ?? ''
}

export function turnStatus(
  empty: boolean,
  live: boolean,
  working: boolean,
): string | null {
  if (!live) return empty ? 'Loading…' : 'Reconnecting…'
  return empty && !working ? 'No activity yet.' : null
}
