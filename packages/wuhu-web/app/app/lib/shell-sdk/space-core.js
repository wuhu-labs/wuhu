// @ts-self-types="./space-core.d.ts"

// The one JS core of `wuhu:space`: argument normalization, row and value
// conversion, errors and op shapes. Pages (`/_/space.js`) and run_script share
// it and differ only in the transport they hand to `createSpace`.
//
// A transport speaks the wire of the `/_/space/*` routes:
//   query(sql, params)             -> Promise<snapshot>
//   observe(sql, params)           -> stream of snapshots
//   watch(glob, from)              -> stream of file events
//   mutateRows(path, ops)          -> Promise<{ rev, ids }>
//   readAttributes(path)           -> Promise<{ attributes, token }>
//   patchAttributes(path, patch)   -> Promise<{ token }>
// A snapshot is `{ columns, rows }`, each cell a scalar, `{ blob: base64 }` or
// `{ json: value }`. A stream is `{ next(): Promise<value | null>, close() }`,
// opened when iteration starts; `null` ends it. A transport rejects with a
// `SpaceError`; `failure(body)` builds one from an error body.

export class SpaceError extends Error {
  constructor(code, message, details = {}) {
    super(message)
    this.name = 'SpaceError'
    this.code = code
    if (details.hint != null) this.hint = details.hint
    if (details.token != null) this.token = details.token
  }
}

export function failure(body, fallback = 'request failed') {
  if (
    body !== null && typeof body === 'object' && typeof body.code === 'string'
  ) {
    return new SpaceError(body.code, String(body.message ?? fallback), body)
  }
  return new SpaceError('internal', fallback)
}

export function base64Of(bytes) {
  let text = ''
  for (let i = 0; i < bytes.length; i += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(text)
}

export function bytesOf(base64) {
  const text = atob(base64)
  const out = new Uint8Array(text.length)
  for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i)
  return out
}

const binary = (value) =>
  value instanceof ArrayBuffer || ArrayBuffer.isView(value)

const bytesFrom = (value) =>
  value instanceof ArrayBuffer
    ? new Uint8Array(value)
    : new Uint8Array(value.buffer, value.byteOffset, value.byteLength)

const plain = (value) => {
  if (value === null || typeof value !== 'object') return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

const number = (value, what) => {
  if (!Number.isFinite(value)) {
    throw new TypeError(`${what} must be a finite number`)
  }
  return value
}

const bigint = (value, what) => {
  if (
    value > BigInt(Number.MAX_SAFE_INTEGER) ||
    value < BigInt(Number.MIN_SAFE_INTEGER)
  ) {
    throw new TypeError(`${what} is outside the safe integer range`)
  }
  return Number(value)
}

// A bound parameter: a scalar, a Date (its ISO string) or bytes.
export function parameter(value, what = 'a query parameter') {
  if (value === undefined || value === null) return null
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return value
    case 'number':
      return number(value, what)
    case 'bigint':
      return bigint(value, what)
  }
  if (value instanceof Date) return value.toISOString()
  if (binary(value)) return { blob: base64Of(bytesFrom(value)) }
  throw new TypeError(
    `${what} must be a string, number, boolean, null, Date or bytes`,
  )
}

// A cell as a row object holds it: bytes for `{ blob }`, the value for `{ json }`.
export function cell(value) {
  if (value === null || typeof value !== 'object') return value
  if ('blob' in value) return bytesOf(value.blob)
  if ('json' in value) return value.json
  return value
}

export function rows(snapshot) {
  const { columns, rows: values } = snapshot
  return values.map((row) => {
    const out = {}
    columns.forEach((name, index) => {
      out[name] = cell(row[index])
    })
    return out
  })
}

// A written field: bytes as `{ blob }`, an object or array as `{ json }`, a
// Date as its ISO string, a scalar as itself. The server checks the value
// against the column's type.
export function field(value, what) {
  if (value === null) return null
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return value
    case 'number':
      return number(value, what)
    case 'bigint':
      return bigint(value, what)
  }
  if (value instanceof Date) return value.toISOString()
  if (binary(value)) return { blob: base64Of(bytesFrom(value)) }
  if (Array.isArray(value) || plain(value)) {
    return { json: JSON.parse(JSON.stringify(value)) }
  }
  throw new TypeError(`${what} must be a JSON value, a Date or bytes`)
}

const fields = (values, what) => {
  if (!plain(values)) {
    throw new TypeError(`${what} must be an object of column values`)
  }
  const out = {}
  for (const [name, value] of Object.entries(values)) {
    if (value === undefined) continue
    out[name] = field(value, `${what}.${name}`)
  }
  return out
}

const rowID = (value, what) => {
  const id = typeof value === 'bigint' ? bigint(value, what) : value
  if (!Number.isSafeInteger(id)) {
    throw new TypeError(`${what} must be an integer row id`)
  }
  return id
}

const shapes = {
  insert: ['insert'],
  update: ['update', 'set'],
  delete: ['delete'],
}

export function rowOp(op, index = 0) {
  const what = `ops[${index}]`
  if (!plain(op)) throw new TypeError(`${what} must be an object`)
  const kind = Object.keys(shapes).find((name) => name in op)
  if (kind === undefined) {
    throw new TypeError(
      `${what} must be { insert }, { update, set } or { delete }`,
    )
  }
  const extra = Object.keys(op).filter((key) => !shapes[kind].includes(key))
  if (extra.length > 0) {
    throw new TypeError(`${what} has unexpected keys: ${extra.join(', ')}`)
  }
  switch (kind) {
    case 'insert':
      return { insert: fields(op.insert, `${what}.insert`) }
    case 'update':
      return {
        update: rowID(op.update, `${what}.update`),
        set: fields(op.set, `${what}.set`),
      }
    default:
      return { delete: rowID(op.delete, `${what}.delete`) }
  }
}

// `query\`… ${x}\`` or `query(sql, params)`: one statement, `?` per param.
export function statement(first, rest) {
  const tagged = Array.isArray(first) && Array.isArray(first.raw)
  if (!tagged && typeof first !== 'string') {
    throw new TypeError('a statement is a tagged template or a SQL string')
  }
  const sql = tagged ? first.join('?') : first
  const values = tagged ? rest : (rest[0] ?? [])
  if (!Array.isArray(values)) {
    throw new TypeError('query parameters must be an array')
  }
  return {
    sql,
    params: values.map((value, index) =>
      parameter(value, `parameter ${index + 1}`)
    ),
  }
}

const path = (value) => {
  if (typeof value !== 'string' || value === '') {
    throw new TypeError('a path must be a non-empty string')
  }
  return value
}

const attributes = (values) => {
  if (values === undefined) return {}
  if (!plain(values)) {
    throw new TypeError('set must be an object of attribute values')
  }
  const out = {}
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined) {
      throw new TypeError(`set.${key} is undefined; use remove to drop a key`)
    }
    out[key] = JSON.parse(
      JSON.stringify(value instanceof Date ? value.toISOString() : value),
    )
  }
  return out
}

export function attributePatch(options) {
  if (!plain(options)) {
    throw new TypeError('patchAttributes takes { set, remove, ifMatch }')
  }
  const { set, remove = [], ifMatch } = options
  if (typeof ifMatch !== 'string' || ifMatch === '') {
    throw new TypeError(
      'ifMatch is required: the token readAttributes returned',
    )
  }
  if (!Array.isArray(remove) || remove.some((key) => typeof key !== 'string')) {
    throw new TypeError('remove must be an array of keys')
  }
  return { set: attributes(set), remove: [...remove], ifMatch }
}

const live = (open, convert) => ({
  [Symbol.asyncIterator]() {
    let stream = null
    let done = false
    const finish = () => {
      if (done) return
      done = true
      stream?.close()
    }
    return {
      async next() {
        if (done) return { done: true, value: undefined }
        stream ??= open()
        let value
        try {
          value = await stream.next()
        } catch (error) {
          finish()
          throw error
        }
        if (value === null) {
          finish()
          return { done: true, value: undefined }
        }
        return { done: false, value: convert(value) }
      },
      return(value) {
        finish()
        return Promise.resolve({ done: true, value })
      },
      [Symbol.asyncIterator]() {
        return this
      },
    }
  },
})

const revision = (value) => {
  if (value === undefined || value === null) return null
  return rowID(value, 'from')
}

export function createSpace(transport) {
  return {
    async query(first, ...rest) {
      const { sql, params } = statement(first, rest)
      return rows(await transport.query(sql, params))
    },
    observe(first, ...rest) {
      const { sql, params } = statement(first, rest)
      return live(() => transport.observe(sql, params), rows)
    },
    watch(glob, options = {}) {
      if (typeof glob !== 'string' || glob === '') {
        throw new TypeError('watch takes a glob')
      }
      const from = revision(options?.from)
      return live(() => transport.watch(glob, from), (event) => event)
    },
    async mutateRows(target, ops) {
      if (!Array.isArray(ops)) throw new TypeError('ops must be an array')
      return await transport.mutateRows(path(target), ops.map(rowOp))
    },
    async readAttributes(target) {
      return await transport.readAttributes(path(target))
    },
    async patchAttributes(target, options) {
      return await transport.patchAttributes(
        path(target),
        attributePatch(options),
      )
    },
  }
}
