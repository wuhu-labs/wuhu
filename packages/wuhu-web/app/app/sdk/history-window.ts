import { byteLength } from '~/lib/shell-sdk/open-cache.js'

export interface HistoryRange {
  low: number
  high: number
  hasEarlier: boolean
}

export interface HistoryPage<Event> {
  generation: number
  historyEpoch: string | null
  entries: { position: number; event: Event }[]
  origins: { position: number; event: Event }[]
  before: number | null
  hasEarlier: boolean
  headPosition: number
}

export interface HistoryWindow<Event> {
  version: 1
  generation: number
  historyEpoch: string | null
  entries: { position: number; event: Event }[]
  origins: { position: number; event: Event }[]
  ranges: HistoryRange[]
  headPosition: number
}

export function emptyWindow<Event>(generation = 0): HistoryWindow<Event> {
  return {
    version: 1,
    generation,
    historyEpoch: null,
    entries: [],
    origins: [],
    ranges: [],
    headPosition: -1,
  }
}

function mergeEntries<Event>(
  kept: HistoryWindow<Event>['entries'],
  incoming: HistoryWindow<Event>['entries'],
): HistoryWindow<Event>['entries'] {
  const entries = new Map(kept.map((entry) => [entry.position, entry]))
  for (const entry of incoming) {
    entries.set(entry.position, entry)
  }
  return [...entries.values()].sort((a, b) => a.position - b.position)
}

function joinedRanges(ranges: HistoryRange[]): HistoryRange[] {
  const joined: HistoryRange[] = []
  for (const range of ranges.sort((a, b) => a.low - b.low)) {
    const prior = joined.at(-1)
    if (prior && range.low <= prior.high) {
      if (range.low === prior.low) prior.hasEarlier &&= range.hasEarlier
      prior.high = Math.max(prior.high, range.high)
    } else joined.push({ ...range })
  }
  return joined
}

export function mergePage<Event>(
  previous: HistoryWindow<Event>,
  page: HistoryPage<Event>,
  requestedBefore: number | null,
): HistoryWindow<Event> {
  const kept = previous.generation === page.generation &&
      previous.historyEpoch === page.historyEpoch
    ? previous
    : emptyWindow<Event>(page.generation)
  const low = page.before ?? requestedBefore ?? page.headPosition + 1
  const range = {
    low,
    high: requestedBefore ?? page.headPosition,
    hasEarlier: page.hasEarlier,
  }
  return {
    ...kept,
    historyEpoch: page.historyEpoch,
    entries: mergeEntries(kept.entries, page.entries),
    origins: mergeEntries(kept.origins, page.origins),
    ranges: joinedRanges([...kept.ranges, range]),
    headPosition: requestedBefore === null
      ? page.headPosition
      : kept.headPosition,
  }
}

export function appendHistory<Event>(
  window: HistoryWindow<Event>,
  position: number,
  event: Event,
): HistoryWindow<Event> {
  const ranges = window.ranges.map((range) => ({ ...range }))
  const tail = ranges.at(-1)
  if (tail) {
    if (tail.low > tail.high) tail.low = position
    tail.high = Math.max(tail.high, position)
  } else ranges.push({ low: position, high: position, hasEarlier: false })
  return {
    ...window,
    ranges,
    entries: mergeEntries(window.entries, [{ position, event }]),
    headPosition: Math.max(window.headPosition, position),
  }
}

export function visibleHistory<Event>(
  window: HistoryWindow<Event>,
): HistoryWindow<Event>['entries'] {
  const tail = window.ranges.at(-1)
  return tail
    ? window.entries.filter((entry) =>
      entry.position >= tail.low && entry.position <= tail.high
    )
    : []
}

export function boundHistory<Event>(
  window: HistoryWindow<Event>,
  maxBytes: number,
): HistoryWindow<Event> {
  let entries = window.entries
  let origins = window.origins
  let ranges = window.ranges
  const size = () =>
    byteLength(JSON.stringify({ ...window, entries, origins, ranges }))
  while (size() > maxBytes && (entries.length > 0 || origins.length > 0)) {
    if (entries.length === 0) origins = origins.slice(1)
    else {
      entries = entries.slice(1)
      ranges = ranges.flatMap((range) => {
        const first = entries.find((entry) =>
          entry.position >= range.low && entry.position <= range.high
        )
        return first
          ? [{
            ...range,
            low: first.position,
            hasEarlier: range.hasEarlier || first.position > range.low,
          }]
          : []
      })
    }
  }
  return { ...window, entries, origins, ranges }
}
