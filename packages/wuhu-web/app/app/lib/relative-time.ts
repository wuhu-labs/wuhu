export function relativeTime(iso: string, now: Date): string {
  const then = new Date(iso)
  const seconds = Math.round((now.getTime() - then.getTime()) / 1000)
  if (Number.isNaN(seconds)) return iso
  if (seconds < 60) return 'just now'
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`
  if (seconds < 7 * 86400) return `${Math.floor(seconds / 86400)}d ago`
  const sameYear = then.getFullYear() === now.getFullYear()
  return then.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: sameYear ? undefined : 'numeric',
  })
}

const spans: [Intl.RelativeTimeFormatUnit, number][] = [
  ['day', 86400],
  ['hour', 3600],
  ['minute', 60],
]

export function relativeSpan(date: Date, now: Date): string {
  const seconds = (date.getTime() - now.getTime()) / 1000
  const format = new Intl.RelativeTimeFormat('en', { numeric: 'auto' })
  for (const [unit, size] of spans) {
    if (Math.abs(seconds) >= size) {
      return format.format(Math.round(seconds / size), unit)
    }
  }
  return format.format(0, 'minute')
}
