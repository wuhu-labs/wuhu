export type Row = Record<string, unknown>

export type WireCell =
  | string
  | number
  | boolean
  | null
  | { blob: string }
  | { json: unknown }

export interface Snapshot {
  columns: string[]
  rows: WireCell[][]
}

export interface FileEvent {
  kind: 'write' | 'delete' | 'move'
  path: string
  to?: string
  rev: number
  entry?: unknown
}

export type WireRowOp =
  | { insert: Record<string, WireCell> }
  | { update: number; set: Record<string, WireCell> }
  | { delete: number }

export type RowOp =
  | { insert: Record<string, unknown> }
  | { update: number | bigint; set: Record<string, unknown> }
  | { delete: number | bigint }

export interface AttributePatch {
  set: Record<string, unknown>
  remove: string[]
  ifMatch: string
}

export interface Search {
  glob?: string
  pattern?: string
  path?: string
  matchLimit?: number
  hidden?: boolean
  noIgnore?: boolean
  step?: string
}

export interface SearchOptions {
  path?: string | null
  limit?: number | bigint | null
  // Search hidden entries too: dot-names, `/_` and `/users` at a space root.
  hidden?: boolean | null
  // Search what `.gitignore` files exclude too.
  noIgnore?: boolean | null
  step?: string | null
}

export interface GrepMatch {
  path: string
  line: number
  text: string
}

// Why a search passed an entry over; `ignored` is a `.gitignore` exclusion,
// `longLine` a file with a line over 64 KiB.
export type SearchSkipReason =
  | 'hidden'
  | 'ignored'
  | 'binary'
  | 'longLine'
  | 'unreadable'

// Entries a search passed over for one reason: how many, and the first.
export interface SearchSkipped {
  reason: SearchSkipReason
  count: number
  example: string
}

export interface Stream<T> {
  next(): Promise<T | null>
  close(): void
}

export interface Transport {
  query(sql: string, params: unknown[]): Promise<Snapshot>
  observe(sql: string, params: unknown[]): Stream<Snapshot>
  watch(glob: string, from: number | null): Stream<FileEvent>
  mutateRows(
    path: string,
    ops: WireRowOp[],
  ): Promise<{ rev: number; ids: number[] }>
  readAttributes(
    path: string,
  ): Promise<{ attributes: Record<string, unknown>; token: string }>
  patchAttributes(
    path: string,
    patch: AttributePatch,
  ): Promise<{ token: string }>
  find(search: Search): Promise<{
    paths: string[]
    cursor?: string | null
    scanned: number
    skipped: SearchSkipped[]
  }>
  grep(
    search: Search,
  ): Promise<{
    matches: GrepMatch[]
    cursor?: string | null
    scanned: number
    skipped: SearchSkipped[]
  }>
}

export interface Space {
  query(strings: TemplateStringsArray, ...values: unknown[]): Promise<Row[]>
  query(sql: string, params?: unknown[]): Promise<Row[]>
  observe(
    strings: TemplateStringsArray,
    ...values: unknown[]
  ): AsyncIterable<Row[]>
  observe(sql: string, params?: unknown[]): AsyncIterable<Row[]>
  watch(
    glob: string,
    options?: { from?: number | bigint | null },
  ): AsyncIterable<FileEvent>
  mutateRows(
    path: string,
    ops: RowOp[],
  ): Promise<{ rev: number; ids: number[] }>
  readAttributes(
    path: string,
  ): Promise<{ attributes: Record<string, unknown>; token: string }>
  patchAttributes(
    path: string,
    patch: {
      set?: Record<string, unknown>
      remove?: string[]
      ifMatch: string
    },
  ): Promise<{ token: string }>
  find(
    glob: string,
    options?: SearchOptions,
  ): Promise<
    {
      paths: string[]
      step: string | null
      scanned: number
      skipped: SearchSkipped[]
    }
  >
  grep(
    pattern: string,
    options?: SearchOptions,
  ): Promise<
    {
      matches: GrepMatch[]
      step: string | null
      scanned: number
      skipped: SearchSkipped[]
    }
  >
}

export class SpaceError extends Error {
  constructor(
    code: string,
    message: string,
    details?: { hint?: string; token?: string; id?: string },
  )
  code: string
  hint?: string
  token?: string
  /** The session an `incompleteSession` create made. */
  id?: string
}

export function failure(body: unknown, fallback?: string): SpaceError
export function base64Of(bytes: Uint8Array): string
export function bytesOf(base64: string): Uint8Array
export function parameter(value: unknown, what?: string): WireCell
export function cell(value: WireCell): unknown
export function rows(snapshot: Snapshot): Row[]
export function field(value: unknown, what: string): WireCell
export function rowOp(op: unknown, index?: number): WireRowOp
export function statement(
  first: unknown,
  rest: unknown[],
): { sql: string; params: WireCell[] }
export function attributePatch(options: unknown): AttributePatch
export function createSpace(transport: Transport): Space
