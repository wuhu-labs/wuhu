import type { ScriptHostCalls, ScriptRun } from './engine.ts'

// The page side of scripts: it runs a script, answers its queries and
// fetches, remembers what each run read, and runs it again when that goes
// out of date: a query when its rows change, a fetch with `every` when its
// time is up. Off screen a script still reruns on its queries, but a run
// that needs the network stops there, keeps what it last drew, and runs
// again once on screen.

export interface QueryResult {
  columns: string[]
  rows: unknown[][]
}

export interface FetchRequest {
  url: string
  method: string
  headers: Record<string, string>
  body: string | null
  every: string | null
}

export interface FetchAnswer {
  status: number
  statusText: string
  headers: [string, string][]
  body: string
}

export type Params = (string | number | null)[]

export interface HostIO {
  // One read, only to learn why a live query was refused.
  query(sql: string, params: Params): Promise<QueryResult>
  // A live query; each change delivers its whole result.
  observe(
    sql: string,
    params: Params,
    receive: (result: QueryResult) => void,
    refused: () => void,
  ): () => void
  // The proxied fetch, signed with `page` as the page claim; a refusal throws
  // its message.
  fetch(page: string, request: FetchRequest): Promise<FetchAnswer>
  run(
    file: string,
    code: string,
    props: unknown,
    calls: ScriptHostCalls,
  ): { done: Promise<ScriptRun>; cancel(): void }
  now(): number
  schedule(delayMs: number, run: () => void): () => void
}

export type ScriptResult =
  | { ok: true; value: unknown; sizes: unknown }
  | { ok: false; message: string }

export interface Watching {
  setActive(active: boolean): void
  stop(): void
}

const units: Record<string, number> = { s: 1_000, m: 60_000, h: 3_600_000 }
export const everyFloorMs = 30_000

// `every: "1m"`: how long a fetch result stays fresh, never under 30 s.
export function everyMs(every: string | null): number | null {
  if (every == null) return null
  const match = /^(\d+(?:\.\d+)?)\s*(s|m|h)$/.exec(every.trim())
  if (match == null) {
    throw new Error(
      `every is a duration like "30s", "1m" or "2h", not "${every}"`,
    )
  }
  return Math.max(everyFloorMs, Number(match[1]) * units[match[2]!]!)
}

export function rowObjects(result: QueryResult): Record<string, unknown>[] {
  return result.rows.map((row) =>
    Object.fromEntries(result.columns.map((column, at) => [column, row[at]]))
  )
}

// FNV-1a: which version of a script a kept fetch belongs to.
function version(code: string): string {
  let hash = 0x811c9dc5
  for (let at = 0; at < code.length; at++) {
    hash = Math.imul(hash ^ code.charCodeAt(at), 0x01000193)
  }
  return `${code.length}:${(hash >>> 0).toString(36)}`
}

const failed = (message: string) => JSON.stringify({ error: message })

interface LiveQuery {
  rows: string | null
  first: Promise<string>
  stop: () => void
  watchers: Set<Watch>
  // Refused after it answered: `first` says why, to every run that asks.
  refused: boolean
}

interface Answer {
  text: string
  at: number
  ok: boolean
}

interface Kept {
  text: string
  at: number
  watchers: Set<Watch>
}

export class ScriptHost {
  private readonly queries = new Map<string, LiveQuery>()
  private readonly kept = new Map<string, Kept>()
  private readonly fetching = new Map<string, Promise<Answer>>()

  constructor(private readonly io: HostIO) {}

  watch(
    script: { file: string; code: string; props: unknown; active: boolean },
    receive: (result: ScriptResult) => void,
  ): Watching {
    const watch = new Watch(this, this.io, script, receive)
    void watch.rerun()
    return {
      setActive: (active) => watch.setActive(active),
      stop: () => watch.stop(),
    }
  }

  // Live rows; `watch` holds the query from the moment it asks.
  rows(
    watch: Watch,
    sql: string,
    params: Params,
  ): { key: string; rows: Promise<string> } {
    const key = JSON.stringify([sql, params])
    const live = this.queries.get(key) ?? this.open(key, sql, params)
    live.watchers.add(watch)
    return {
      key,
      rows: live.rows == null ? live.first : Promise.resolve(live.rows),
    }
  }

  private open(key: string, sql: string, params: Params): LiveQuery {
    let resolve!: (rows: string) => void
    let reject!: (error: Error) => void
    const entry: LiveQuery = {
      rows: null,
      first: new Promise((yes, no) => {
        resolve = yes
        reject = no
      }),
      stop: () => {},
      watchers: new Set(),
      refused: false,
    }
    this.queries.set(key, entry)
    entry.stop = this.io.observe(sql, params, (result) => {
      const rows = JSON.stringify(rowObjects(result))
      if (rows === entry.rows) return
      const first = entry.rows == null
      entry.rows = rows
      if (first) resolve(rows)
      else for (const watch of entry.watchers) watch.changed(key, rows)
    }, () => {
      entry.stop()
      entry.stop = () => {}
      if (this.queries.get(key) !== entry) return
      const why = this.io.query(sql, params).then(
        () => Promise.reject(new Error('the query was refused')),
        (error: unknown) =>
          Promise.reject(
            error instanceof Error ? error : new Error(String(error)),
          ),
      )
      if (entry.rows == null) {
        this.queries.delete(key)
        why.catch(reject)
        return
      }
      // Refused after it answered, as on a reconnect: every script holding
      // it runs again and fails with why, instead of keeping old rows.
      why.catch(() => {})
      entry.rows = null
      entry.first = why
      entry.refused = true
      for (const watch of entry.watchers) void watch.rerun()
    })
    return entry
  }

  // A kept answer still fresh for `every`; `watch` holds it.
  fresh(watch: Watch, key: string, every: number): Kept | null {
    const entry = this.kept.get(key)
    if (entry == null || this.io.now() - entry.at >= every) return null
    entry.watchers.add(watch)
    return entry
  }

  // One network call per key at a time.
  fetch(key: string, page: string, request: FetchRequest): Promise<Answer> {
    let waiting = this.fetching.get(key)
    if (waiting == null) {
      waiting = this.io.fetch(page, request).then(
        (answer) => ({
          text: JSON.stringify(answer),
          at: this.io.now(),
          ok: true,
        }),
        (error: unknown) => ({
          text: failed(error instanceof Error ? error.message : String(error)),
          at: this.io.now(),
          ok: false,
        }),
      ).finally(() => this.fetching.delete(key))
      this.fetching.set(key, waiting)
    }
    return waiting
  }

  // An answer kept for `every`, held by `watch`.
  keep(watch: Watch, key: string, answer: Answer) {
    const entry = this.kept.get(key)
    if (entry == null || entry.at < answer.at) {
      this.kept.set(key, {
        text: answer.text,
        at: answer.at,
        watchers: new Set([...(entry?.watchers ?? []), watch]),
      })
    } else {
      entry.watchers.add(watch)
    }
  }

  // Queries and kept answers live while some script holds them.
  release(watch: Watch, queries: Iterable<string>, fetches: Iterable<string>) {
    for (const key of queries) {
      const live = this.queries.get(key)
      if (live == null) continue
      live.watchers.delete(watch)
      if (live.watchers.size === 0) {
        live.stop()
        this.queries.delete(key)
      }
    }
    for (const key of fetches) {
      const entry = this.kept.get(key)
      if (entry == null) continue
      entry.watchers.delete(watch)
      if (entry.watchers.size === 0) this.kept.delete(key)
    }
  }

  current(key: string): string | null {
    return this.queries.get(key)?.rows ?? null
  }
}

class Watch {
  // The last finished run: rows it read, queries and kept answers it holds,
  // and when each of its `every` answers goes stale.
  private read = new Map<string, string>()
  private held = new Set<string>()
  private used = new Set<string>()
  private due = new Map<string, number>()
  // The run in flight holds these too.
  private asked = new Set<string>()
  private keeping = new Set<string>()
  private running: { cancel(): void } | null = null
  private dirty = false
  private stopped = false
  private stale = false
  private parked = false
  private last: string | undefined
  private cancelTimer: (() => void) | null = null
  private readonly version: string

  constructor(
    private readonly host: ScriptHost,
    private readonly io: HostIO,
    private readonly script: {
      file: string
      code: string
      props: unknown
      active: boolean
    },
    private readonly receive: (result: ScriptResult) => void,
  ) {
    this.version = version(script.code)
  }

  setActive(active: boolean) {
    this.script.active = active
    if (active && this.stale) {
      this.stale = false
      void this.rerun()
    }
  }

  stop() {
    this.stopped = true
    this.running?.cancel()
    this.cancelTimer?.()
    this.host.release(
      this,
      [...this.held, ...this.asked],
      [...this.used, ...this.keeping],
    )
  }

  changed(key: string, rows: string) {
    if (this.read.get(key) === rows) return
    void this.rerun()
  }

  async rerun(): Promise<void> {
    if (this.stopped) return
    if (this.running != null) {
      this.dirty = true
      return
    }
    this.dirty = false
    this.parked = false
    this.cancelTimer?.()
    this.cancelTimer = null
    const read = new Map<string, string>()
    const asked = new Set<string>()
    const keeping = new Set<string>()
    const due = new Map<string, number>()
    // This run's answers that are not kept: those without `every`, and
    // failures, which never outlive the run that saw them.
    const once = new Map<string, Promise<string>>()
    this.asked = asked
    this.keeping = keeping
    const { file } = this.script
    const run = this.io.run(file, this.script.code, this.script.props, {
      query: async (sql, params) => {
        if (this.stopped) throw new Error('stopped')
        const { key, rows } = this.host.rows(
          this,
          sql,
          (JSON.parse(params) as unknown[]).map((value) =>
            typeof value === 'boolean' ? (value ? 1 : 0) : value as string
          ),
        )
        asked.add(key)
        let text: string
        try {
          text = await rows
        } catch (error) {
          // Nobody holds a refused query, so the next run asks afresh.
          asked.delete(key)
          this.host.release(this, [key], [])
          throw error
        }
        read.set(key, text)
        return text
      },
      fetch: async (text) => {
        if (this.stopped) throw new Error('stopped')
        const given = JSON.parse(text) as FetchRequest
        const method = given.method.toUpperCase()
        if (method !== 'GET' && method !== 'HEAD') {
          return failed(`fetch is GET or HEAD only, not ${given.method}`)
        }
        const request = { ...given, method }
        let every: number | null
        try {
          every = everyMs(request.every)
        } catch (error) {
          return failed((error as Error).message)
        }
        const key = JSON.stringify([
          file,
          this.version,
          request.url,
          method,
          request.headers,
          request.body,
        ])
        if (every != null) {
          const kept = this.host.fresh(this, key, every)
          if (kept != null) {
            keeping.add(key)
            due.set(key, kept.at + every)
            return kept.text
          }
        }
        const earlier = once.get(key)
        if (earlier != null) return earlier
        if (!this.script.active) {
          this.parked = true
          run.cancel()
          return failed('off screen')
        }
        const answering = this.host.fetch(key, file, request)
        once.set(key, answering.then((answer) => answer.text))
        const answer = await answering
        if (every != null && answer.ok && !this.stopped) {
          this.host.keep(this, key, answer)
          keeping.add(key)
          due.set(key, answer.at + every)
          once.delete(key)
        }
        return answer.text
      },
    })
    this.running = run
    let result: ScriptResult
    try {
      const done = await run.done
      result = { ok: true, value: JSON.parse(done.value), sizes: done.sizes }
    } catch (error) {
      result = {
        ok: false,
        message: error instanceof Error ? error.message : String(error),
      }
    }
    this.running = null
    if (this.stopped) return
    this.asked = new Set()
    this.keeping = new Set()
    if (this.parked) {
      this.host.release(
        this,
        [...asked].filter((key) => !this.held.has(key)),
        [...keeping].filter((key) => !this.used.has(key)),
      )
      if (this.script.active) return this.rerun()
      this.stale = true
      return
    }
    this.host.release(
      this,
      [...this.held].filter((key) => !asked.has(key)),
      [...this.used].filter((key) => !keeping.has(key)),
    )
    this.read = read
    this.held = asked
    this.used = keeping
    this.due = due
    const encoded = JSON.stringify(result)
    if (encoded !== this.last) {
      this.last = encoded
      this.receive(result)
    }
    // Rows that moved while it ran, or a change that came in meanwhile.
    const moved = [...read].some(([key, rows]) =>
      this.host.current(key) !== rows
    )
    if (this.dirty || moved) return this.rerun()
    this.scheduleStale()
  }

  private scheduleStale() {
    if (this.due.size === 0) return
    const due = Math.min(...this.due.values())
    this.cancelTimer = this.io.schedule(
      Math.max(0, due - this.io.now()),
      () => {
        this.cancelTimer = null
        if (this.script.active) void this.rerun()
        else this.stale = true
      },
    )
  }
}
