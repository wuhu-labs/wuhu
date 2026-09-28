// @ts-self-types="./open-cache.d.ts"

// Per kind, in bytes. The web app and the content origin each keep their own
// store, and between them they stay within the browser's 100 MB.
export const appCacheBudgets = {
  query: 5_000_000,
  document: 20_000_000,
  conversation: 25_000_000,
  transcript: 30_000_000,
  meta: 5_000_000,
}

export const pageCacheBudgets = {
  page: 10_000_000,
  query: 4_000_000,
  meta: 1_000_000,
}

const encoder = new TextEncoder()

export function byteLength(text) {
  return encoder.encode(text).byteLength
}

export const sharedGroup = 'shared'

export function scopeKey({ space, group, viewer }) {
  return `${space}\n${group}\n${viewer}`
}

// Whitespace is collapsed only outside quotes, where it is not data.
export function normalizeSQL(sql) {
  let normalized = ''
  let quote = null
  let pendingSpace = false
  for (const character of sql.trim()) {
    if (quote === null && /\s/.test(character)) {
      pendingSpace = true
      continue
    }
    if (pendingSpace) normalized += ' '
    pendingSpace = false
    normalized += character
    if (quote === null && (character === "'" || character === '"')) {
      quote = character
    } else if (character === quote) {
      quote = null
    }
  }
  return normalized
}

// What must go, least recently used first, for an incoming entry to fit its
// kind's budget; null when it can never fit, so it is refused before anything
// is evicted. A kind with no budget on this origin keeps nothing.
export function evictions(entries, incoming, budget) {
  if (!(incoming.bytes <= budget)) return null
  const others = entries.filter((entry) => entry.id !== incoming.id)
  let total = others.reduce((sum, entry) => sum + entry.bytes, incoming.bytes)
  const evicted = []
  for (const entry of others.sort((a, b) => a.used - b.used)) {
    if (total <= budget) break
    evicted.push(entry.id)
    total -= entry.bytes
  }
  return evicted
}

export function sseParser() {
  let buffer = ''
  return {
    push(chunk) {
      buffer += chunk
      const payloads = []
      for (;;) {
        const boundary = /\r\n\r\n|\n\n|\r\r/.exec(buffer)
        if (boundary == null) break
        const lines = buffer.slice(0, boundary.index).split(/\r\n|\n|\r/)
        buffer = buffer.slice(boundary.index + boundary[0].length)
        const field = (name) =>
          lines
            .filter((line) => line.startsWith(`${name}:`))
            .map((line) => line.slice(name.length + 1).replace(/^ /, ''))
        const data = field('data').join('\n')
        if (data.length > 0) {
          payloads.push({ event: field('event').at(-1) ?? 'message', data })
        }
      }
      return payloads
    },
  }
}

function settled(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

// Metadata and values live in separate stores so eviction scans small
// records, never the cached bodies. A database that fails to open, or that
// the browser closes, is opened again on the next call.
export function openCache(
  { budgets, name = 'wuhu-open-cache', now = Date.now },
) {
  let database = null
  const open = () => {
    database ??= new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1)
      request.onupgradeneeded = () => {
        const meta = request.result.createObjectStore('meta', { keyPath: 'id' })
        meta.createIndex('kind', 'kind')
        meta.createIndex('scope', 'scope')
        request.result.createObjectStore('values')
      }
      request.onsuccess = () => {
        const opened = request.result
        opened.onclose = () => database = null
        opened.onversionchange = () => {
          opened.close()
          database = null
        }
        resolve(opened)
      }
      request.onerror = () => reject(request.error)
    }).catch((failure) => {
      database = null
      throw failure
    })
    return database
  }
  const transaction = async (mode, run) => {
    const connection = await open()
    let stores
    try {
      stores = connection.transaction(['meta', 'values'], mode)
    } catch (failure) {
      database = null
      throw failure
    }
    const done = new Promise((resolve, reject) => {
      stores.oncomplete = resolve
      stores.onerror = () => reject(stores.error)
      stores.onabort = () => reject(stores.error)
    })
    const result = await run(
      stores.objectStore('meta'),
      stores.objectStore('values'),
    )
    await done
    return result
  }
  const entryId = (scope, kind, key) => `${scopeKey(scope)}\n${kind}\n${key}`

  return {
    get(scope, kind, key) {
      const id = entryId(scope, kind, key)
      return transaction('readwrite', async (meta, values) => {
        const [record, value] = await Promise.all([
          settled(meta.get(id)),
          settled(values.get(id)),
        ])
        if (record === undefined) return undefined
        meta.put({ ...record, used: now() })
        return value
      })
    },
    put(scope, kind, key, value, bytes) {
      const id = entryId(scope, kind, key)
      return transaction('readwrite', async (meta, values) => {
        const entries = await settled(meta.index('kind').getAll(kind))
        const evicted = evictions(entries, { id, bytes }, budgets[kind])
        if (evicted === null) return
        for (const gone of evicted) {
          meta.delete(gone)
          values.delete(gone)
        }
        values.put(value, id)
        meta.put({ id, scope: scopeKey(scope), kind, bytes, used: now() })
      })
    },
    purge(scope, kind) {
      return transaction('readwrite', async (meta, values) => {
        const records = await settled(
          meta.index('scope').getAll(scopeKey(scope)),
        )
        for (const record of records) {
          if (kind !== undefined && record.kind !== kind) continue
          meta.delete(record.id)
          values.delete(record.id)
        }
      })
    },
  }
}
