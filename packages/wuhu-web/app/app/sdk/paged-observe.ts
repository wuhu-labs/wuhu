import type { ObserveStore, Snapshot, StoreConfig } from './observe'
import { ApiError, errorMessage } from './errors'
import {
  appendHistory,
  boundHistory,
  emptyWindow,
  type HistoryPage,
  type HistoryWindow,
  mergePage,
  visibleHistory,
} from './history-window'

export interface HistorySubscription<Event> {
  page(
    before: number | null,
    generation: number | null,
    signal: AbortSignal,
    historyEpoch: string | null,
  ): Promise<HistoryPage<Event>>
  url(generation: number, position: number, historyEpoch: string | null): string
  position(event: Event): number | null
  generation(event: Event): number | null
  reset(generation: number): Event | null
  isReset(event: Event): boolean
}

export interface HistoryEdge {
  status: 'loading' | 'preparing' | 'ready' | 'error'
  error: string | null
  hasEarlier: boolean
  gap: boolean
  generation: number
  revision: number
  historyEpoch?: string | null
  resetVersion?: number
  loadOlder(): void
  retry(): void
}

export function pagedObserveStore<Data, Event>(
  config: StoreConfig<Data, Event>,
): ObserveStore<Data> {
  const { subscription, fold, initial, open, timer, cache } = config
  const history = subscription.history!
  const retention = subscription.retention!
  const network = config.network ??
    { online: () => true, onChange: () => () => {} }
  const backoff = config.backoff ?? [250, 500, 1000, 2000, 4000, 8000]
  let window = emptyWindow<Event>()
  let data = initial
  let status: HistoryEdge['status'] = 'loading'
  let error: string | null = null
  let liveness: Snapshot<Data>['liveness'] = 'reconnecting'
  let revision = 0
  let resetVersion = 0
  let snapshot: Snapshot<Data>
  let closed = false
  let restored = false
  let attempt = 0
  let epoch = 0
  let request: AbortController | null = null
  let stream: ReturnType<typeof open> | null = null
  let cancelRetry: (() => void) | null = null
  let cancelDeadline: (() => void) | null = null
  let cancelSave: (() => void) | null = null
  let unlisten: (() => void) | null = null
  let restore: Promise<void> | null = null
  const listeners = new Set<() => void>()

  function emit() {
    const tail = window.ranges.at(-1)
    snapshot = {
      data,
      liveness,
      origins: window.origins.map((entry) => entry.event),
      history: {
        status,
        error,
        hasEarlier: tail?.hasEarlier ?? false,
        gap: window.ranges.length > 1,
        generation: window.generation,
        revision,
        historyEpoch: window.historyEpoch,
        resetVersion,
        loadOlder,
        retry,
      },
    }
    for (const listener of listeners) listener()
  }

  function project() {
    data = initial
    const reset = history.reset(window.generation)
    if (reset !== null) data = fold(data, reset)
    for (const entry of visibleHistory(window)) data = fold(data, entry.event)
  }

  function save() {
    if (!cache || cancelSave) return
    cancelSave = timer.schedule(config.saveDelayMs ?? 1000, () => {
      cancelSave = null
      // Disk eviction never shrinks the active reading viewport.
      void cache.put(
        retention.kind,
        retention.key,
        boundHistory(window, retention.maxBytes!),
      )
    })
  }

  function stopStream() {
    stream?.close()
    stream = null
    cancelDeadline?.()
    cancelDeadline = null
  }

  function stop() {
    epoch++
    request?.abort()
    request = null
    stopStream()
    cancelRetry?.()
    cancelRetry = null
  }

  function schedule(preparingBefore?: number | null) {
    if (closed || listeners.size === 0 || !network.online()) return
    cancelRetry?.()
    cancelRetry = timer.schedule(
      preparingBefore !== undefined
        ? 250
        : backoff[Math.min(attempt++, backoff.length - 1)]!,
      () => {
        cancelRetry = null
        if (preparingBefore !== undefined) void fetchPage(preparingBefore)
        else void bootstrap()
      },
    )
  }

  function connect() {
    if (closed || listeners.size === 0 || !network.online()) return
    const opened = open(
      history.url(window.generation, window.headPosition, window.historyEpoch),
    )
    stream = opened
    const arm = (delay: number) => {
      cancelDeadline?.()
      cancelDeadline = timer.schedule(delay, () => {
        if (stream !== opened) return
        stopStream()
        epoch++
        request?.abort()
        request = null
        liveness = 'reconnecting'
        emit()
        schedule()
      })
    }
    arm(config.openTimeoutMs ?? 10000)
    opened.onOpen(() => {
      if (stream !== opened) return
      attempt = 0
      liveness = 'live'
      emit()
      arm(config.staleTimeoutMs ?? 45000)
    })
    opened.onActivity(() => {
      if (stream === opened) arm(config.staleTimeoutMs ?? 45000)
    })
    opened.onMessage((raw) => {
      if (stream !== opened) return
      const event = JSON.parse(raw) as Event
      if (history.isReset(event)) {
        const generation = history.generation(event)!
        stop()
        // Even same-generation reset means a bounded lag re-bootstrap, not replay.
        window = emptyWindow(generation)
        resetVersion++
        project()
        revision++
        void cache?.put(retention.kind, retention.key, window)
        liveness = 'reconnecting'
        emit()
        void bootstrap()
        return
      }
      const generation = history.generation(event)
      if (generation !== null && generation !== window.generation) return
      const position = history.position(event)
      if (position !== null) {
        if (position <= window.headPosition) return
        window = appendHistory(window, position, event)
        data = fold(data, event)
        save()
      } else data = fold(data, event)
      emit()
    })
    opened.onError(() => {
      if (stream !== opened) return
      stopStream()
      // A tail refresh owns the only request slot; abort any backfill first.
      epoch++
      request?.abort()
      request = null
      liveness = 'reconnecting'
      emit()
      schedule()
    })
  }

  async function fetchPage(before: number | null) {
    if (closed || request || !network.online() || listeners.size === 0) return
    const token = epoch
    const controller = new AbortController()
    request = controller
    status = 'loading'
    error = null
    emit()
    const cancelTimeout = timer.schedule(
      config.openTimeoutMs ?? 10000,
      () => controller.abort(),
    )
    try {
      const page = await history.page(
        before,
        before === null ? null : window.generation,
        controller.signal,
        window.historyEpoch,
      )
      if (controller.signal.aborted || closed || token !== epoch) return
      if (
        before !== null &&
        (page.generation !== window.generation ||
          page.historyEpoch !== window.historyEpoch)
      ) {
        throw new ApiError(409, {
          code: 'generationChanged',
          message: 'Transcript generation changed',
        })
      }
      if (
        page.generation !== window.generation ||
        page.historyEpoch !== window.historyEpoch
      ) resetVersion++
      window = mergePage(window, page, before)
      if (before === null) {
        project()
      } else {
        for (const entry of visibleHistory(window)) {
          data = fold(data, entry.event)
        }
      }
      revision++
      status = 'ready'
      attempt = before === null ? attempt : 0
      save()
      if (before === null) connect()
    } catch (failure) {
      if (closed || token !== epoch) return
      if (failure instanceof ApiError && failure.code === 'generationChanged') {
        stop()
        window = emptyWindow()
        resetVersion++
        void cache?.put(retention.kind, retention.key, window)
        project()
        revision++
        liveness = 'reconnecting'
        void bootstrap()
        return
      }
      status =
        failure instanceof ApiError && failure.code === 'transcriptPreparing'
          ? 'preparing'
          : 'error'
      error = errorMessage(failure)
      if (status === 'preparing') schedule(before)
      else if (before === null) schedule()
    } finally {
      cancelTimeout()
      if (request === controller) request = null
      if (token === epoch && !closed) emit()
    }
  }

  async function bootstrap() {
    if (request || closed) return
    stopStream()
    liveness = 'reconnecting'
    await fetchPage(null)
  }

  function loadOlder() {
    const tail = window.ranges.at(-1)
    if (
      !tail?.hasEarlier || request || status === 'loading' ||
      status === 'preparing'
    ) return
    void fetchPage(tail.low)
  }

  function retry() {
    cancelRetry?.()
    cancelRetry = null
    if (stream && window.ranges.length > 0) loadOlder()
    else void bootstrap()
  }

  function start() {
    unlisten ??= network.onChange(() => {
      stop()
      liveness = 'reconnecting'
      emit()
      if (network.online() && restored) void bootstrap()
    })
    if (restored) {
      void bootstrap()
      return
    }
    restore ??= (async () => {
      const cached = await cache?.get<HistoryWindow<Event>>(
        retention.kind,
        retention.key,
      )
      if (!closed && cached?.version === 1 && Array.isArray(cached.ranges)) {
        window = cached
        project()
        status = 'ready'
        revision++
        emit()
      }
      restored = true
    })()
    void restore.then(() => {
      if (!closed && listeners.size > 0) void bootstrap()
    })
  }

  emit()
  return {
    subscribe(listener) {
      listeners.add(listener)
      if (listeners.size === 1) start()
      return () => {
        listeners.delete(listener)
        if (listeners.size > 0) return
        stop()
        unlisten?.()
        unlisten = null
      }
    },
    getSnapshot: () => snapshot,
    close() {
      closed = true
      stop()
      cancelSave?.()
      cancelSave = null
      unlisten?.()
      listeners.clear()
    },
  }
}
