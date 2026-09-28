import type { Liveness } from '~/sdk/observe'

export function ReconnectingBadge({ liveness }: { liveness: Liveness }) {
  if (liveness === 'live') return null
  return (
    <span className='inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-950 dark:text-amber-300'>
      <span className='h-1.5 w-1.5 animate-pulse rounded-full bg-amber-500' />
      reconnecting…
    </span>
  )
}
