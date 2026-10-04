import { byteLength, type CacheKind } from '~/lib/shell-sdk/open-cache.js'
import type { ViewerCache } from './open-cache'
import {
  type HistoryEdge,
  type HistorySubscription,
  pagedObserveStore,
} from './paged-observe'

export type Liveness = 'live' | 'reconnecting'

export interface Snapshot<Data> {
  readonly data: Data
  readonly liveness: Liveness
  readonly history?: HistoryEdge
  readonly origins?: readonly unknown[]
}

export type Fold<Data, Event> = (data: Data, event: Event) => Data

export interface Subscription<Event> {
  readonly from: number | null
  readonly history?: HistorySubscription<Event>
  url(cursor: number | null): string | null
  cursorOf(event: Event): number | null
  readonly retention?: Retention<Event>
}

// The events a reopen replays, before connecting, to paint what was last
// seen; retain may reuse kept, which belongs to the store alone. Past
// maxBytes, the oldest events after the first `pinned` go first.
export interface Retention<Event> {
  readonly kind: CacheKind
  readonly key: string
  retain(kept: Event[], event: Event): Event[]
  readonly maxBytes?: number
  readonly pinned?: number
}

// Sizes each event as its share of the stored JSON array.
export function bounded<Event>(
  events: Event[],
  { maxBytes, pinned = 0 }: Retention<Event>,
): Event[] {
  if (maxBytes === undefined) return events
  const sizes = events.map((event) => byteLength(JSON.stringify(event)) + 1)
  let total = sizes.reduce((sum, size) => sum + size, 1)
  let dropped = 0
  while (total > maxBytes && pinned + dropped < events.length) {
    total -= sizes[pinned + dropped]!
    dropped++
  }
  if (dropped === 0) return events
  return [...events.slice(0, pinned), ...events.slice(pinned + dropped)]
}

export interface Network {
  online(): boolean
  onChange(handler: () => void): () => void
}

export interface ObserveStore<Data> {
  subscribe(onChange: () => void): () => void
  getSnapshot(): Snapshot<Data>
  close(): void
}

export interface EventStream {
  onOpen(handler: () => void): void
  onMessage(handler: (data: string) => void): void
  // Fires on every received chunk, including heartbeat comments that decode
  // to no message — the liveness signal a quiet stream still carries.
  onActivity(handler: () => void): void
  onError(handler: () => void): void
  close(): void
}

export type OpenStream = (url: string) => EventStream

export interface Timer {
  schedule(delayMs: number, run: () => void): () => void
}

export interface StoreConfig<Data, Event> {
  subscription: Subscription<Event>
  fold: Fold<Data, Event>
  initial: Data
  open: OpenStream
  timer: Timer
  backoff?: readonly number[]
  openTimeoutMs?: number
  staleTimeoutMs?: number
  cache?: ViewerCache | null
  network?: Network
  saveDelayMs?: number
}

const defaultBackoff: readonly number[] = [250, 500, 1000, 2000, 4000, 8000]
const defaultOpenTimeoutMs = 10_000
// The server heartbeats every 15s; three missed beats means the connection
// is dead even though fetch reports nothing.
const defaultStaleTimeoutMs = 45_000
const defaultSaveDelayMs = 1_000
const alwaysOnline: Network = { online: () => true, onChange: () => () => {} }

export function observeStore<Data, Event>(
  config: StoreConfig<Data, Event>,
): ObserveStore<Data> {
  if (config.subscription.history) return pagedObserveStore(config)
  const { subscription, fold, initial, open, timer } = config
  const backoff = config.backoff ?? defaultBackoff
  const openTimeoutMs = config.openTimeoutMs ?? defaultOpenTimeoutMs
  const staleTimeoutMs = config.staleTimeoutMs ?? defaultStaleTimeoutMs
  const network = config.network ?? alwaysOnline
  const saveDelayMs = config.saveDelayMs ?? defaultSaveDelayMs
  const retention = config.cache == null ? null : subscription.retention
  const cache = config.cache

  let data = initial
  let liveness: Liveness = 'reconnecting'
  let snapshot: Snapshot<Data> = { data, liveness }
  let cursor = subscription.from
  let attempt = 0
  let stream: EventStream | null = null
  let cancelTimer: (() => void) | null = null
  let cancelOpenDeadline: (() => void) | null = null
  let cancelStaleDeadline: (() => void) | null = null
  let closed = false
  let restoring: Promise<void> | null = null
  let restored = retention == null
  let kept: Event[] = []
  let cancelSave: (() => void) | null = null
  let stopListening: (() => void) | null = null
  const listeners = new Set<() => void>()

  const emit = () => {
    snapshot = { data, liveness }
    for (const listener of listeners) listener()
  }

  const setLiveness = (next: Liveness) => {
    if (liveness === next) return
    liveness = next
    emit()
  }

  const apply = (event: Event): boolean => {
    const at = subscription.cursorOf(event)
    // Same-commit siblings share a cursor value (glob revs), so only a
    // strictly smaller cursor is a replay to drop; equal values are kept.
    if (at !== null && cursor !== null && at < cursor) return false
    if (at !== null) cursor = cursor === null ? at : Math.max(cursor, at)
    data = fold(data, event)
    return true
  }

  const remember = (event: Event) => {
    if (retention == null) return
    kept = retention.retain(kept, event)
    cancelSave ??= timer.schedule(saveDelayMs, () => {
      cancelSave = null
      kept = bounded(kept, retention)
      void cache!.put(retention.kind, retention.key, kept)
    })
  }

  const teardown = () => {
    cancelTimer?.()
    cancelTimer = null
    cancelOpenDeadline?.()
    cancelOpenDeadline = null
    cancelStaleDeadline?.()
    cancelStaleDeadline = null
    stream?.close()
    stream = null
  }

  const scheduleReconnect = () => {
    if (closed) return
    const delay = backoff[Math.min(attempt, backoff.length - 1)]!
    attempt += 1
    cancelTimer = timer.schedule(delay, () => {
      cancelTimer = null
      connect()
    })
  }

  const connect = () => {
    if (closed || !network.online()) return
    const url = subscription.url(cursor)
    if (url === null) return
    const opened = open(url)
    stream = opened
    // A connection attempt that never resolves fires no error — a network
    // that changed under a sleeping tab leaves fetch pending forever. The
    // open deadline turns that silent wedge into a normal reconnect.
    cancelOpenDeadline = timer.schedule(openTimeoutMs, () => {
      cancelOpenDeadline = null
      if (stream !== opened) return
      stream = null
      opened.close()
      setLiveness('reconnecting')
      scheduleReconnect()
    })
    const armStaleDeadline = () => {
      if (stream !== opened) return
      cancelStaleDeadline?.()
      cancelStaleDeadline = timer.schedule(staleTimeoutMs, () => {
        cancelStaleDeadline = null
        if (stream !== opened) return
        stream = null
        opened.close()
        setLiveness('reconnecting')
        scheduleReconnect()
      })
    }
    opened.onOpen(() => {
      cancelOpenDeadline?.()
      cancelOpenDeadline = null
      attempt = 0
      setLiveness('live')
      armStaleDeadline()
    })
    opened.onActivity(armStaleDeadline)
    opened.onMessage((raw) => {
      armStaleDeadline()
      const event = JSON.parse(raw) as Event
      if (!apply(event)) return
      remember(event)
      emit()
    })
    opened.onError(() => {
      if (stream !== opened) return
      stream = null
      cancelOpenDeadline?.()
      cancelOpenDeadline = null
      cancelStaleDeadline?.()
      cancelStaleDeadline = null
      opened.close()
      setLiveness('reconnecting')
      scheduleReconnect()
    })
  }

  const idle = () =>
    listeners.size > 0 && !closed && stream === null && cancelTimer === null

  // Offline there is nothing to wait for: the pill shows at once, and the
  // connection is retried the moment the browser is back.
  const networkChanged = () => {
    if (!network.online()) {
      teardown()
      setLiveness('reconnecting')
      return
    }
    cancelTimer?.()
    cancelTimer = null
    attempt = 0
    if (restored && idle()) connect()
  }

  // Replays what was retained, once per store, before the first connect.
  const restore = (): Promise<void> =>
    restoring ??= cache!.get<Event[]>(retention!.kind, retention!.key).then(
      (events) => {
        if (events === undefined) return
        for (const event of events) apply(event)
        kept = events
        emit()
      },
    )

  const start = () => {
    stopListening ??= network.onChange(networkChanged)
    if (restored) {
      connect()
      return
    }
    void restore().then(() => {
      restored = true
      if (idle()) connect()
    })
  }

  return {
    subscribe(onChange) {
      listeners.add(onChange)
      if (listeners.size === 1 && idle()) start()
      return () => {
        listeners.delete(onChange)
        if (listeners.size > 0) return
        teardown()
        stopListening?.()
        stopListening = null
      }
    },
    getSnapshot() {
      return snapshot
    },
    close() {
      closed = true
      teardown()
      stopListening?.()
      stopListening = null
      listeners.clear()
    },
  }
}

export const browserNetwork: Network = {
  online: () => navigator.onLine,
  onChange(handler) {
    addEventListener('online', handler)
    addEventListener('offline', handler)
    return () => {
      removeEventListener('online', handler)
      removeEventListener('offline', handler)
    }
  },
}

export const realTimer: Timer = {
  schedule(delayMs, run) {
    const id = setTimeout(run, delayMs)
    return () => clearTimeout(id)
  },
}
