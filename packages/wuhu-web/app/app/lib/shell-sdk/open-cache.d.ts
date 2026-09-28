export type CacheKind =
  | 'page'
  | 'query'
  | 'document'
  | 'conversation'
  | 'transcript'
  | 'meta'

export type CacheBudgets = Readonly<Partial<Record<CacheKind, number>>>

export const appCacheBudgets: CacheBudgets
export const pageCacheBudgets: CacheBudgets

export const sharedGroup: 'shared'

export interface CacheScope {
  space: string
  group: string
  viewer: string
}

export interface CacheMeta {
  id: string
  scope: string
  kind: CacheKind
  bytes: number
  used: number
}

export interface OpenCache {
  get<Value>(
    scope: CacheScope,
    kind: CacheKind,
    key: string,
  ): Promise<Value | undefined>
  put(
    scope: CacheScope,
    kind: CacheKind,
    key: string,
    value: unknown,
    bytes: number,
  ): Promise<void>
  // With a kind, only that kind's entries go.
  purge(scope: CacheScope, kind?: CacheKind): Promise<void>
}

export interface SSEMessage {
  // The `event:` field, `message` when the record names none.
  event: string
  data: string
}

export interface SSEParser {
  push(chunk: string): SSEMessage[]
}

export function scopeKey(scope: CacheScope): string
export function normalizeSQL(sql: string): string
export function byteLength(text: string): number
export function evictions(
  entries: readonly Pick<CacheMeta, 'id' | 'bytes' | 'used'>[],
  incoming: Pick<CacheMeta, 'id' | 'bytes'>,
  budget: number | undefined,
): string[] | null
export function sseParser(): SSEParser
export function openCache(options: {
  budgets: CacheBudgets
  name?: string
  now?: () => number
}): OpenCache
