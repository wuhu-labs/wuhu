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
}

export class SpaceError extends Error {
  constructor(
    code: string,
    message: string,
    details?: { hint?: string; token?: string },
  )
  code: string
  hint?: string
  token?: string
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
