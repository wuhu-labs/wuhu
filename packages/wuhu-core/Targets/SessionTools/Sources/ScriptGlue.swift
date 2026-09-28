// The JS half of run_script. The modules are defined first so they can capture
// their host functions; `scriptPrelude` then builds the globals and deletes every
// `__wuhu_*` host function, so a script reaches the host only through them. A
// module that needs the execution's abort signal defines `__wuhu_link_<name>`,
// which the prelude calls once with `{ signal, guarded }`. The prelude also
// leaves its internals in `__wuhu_kernel` for wuhu:machine, which is defined
// last and takes them away.

let spaceModule = #"""
import { createSpace, failure } from "wuhu:space-core"

const hostQuery = __wuhu_space_query
const openStream = __wuhu_space_open
const nextItem = __wuhu_space_next
const closeStream = __wuhu_space_close
const hostRows = __wuhu_space_rows
const hostAttributes = __wuhu_space_attributes
const hostPatch = __wuhu_space_patch
const read = __wuhu_conversation
const between = __wuhu_dm

let signal
let guarded
globalThis.__wuhu_link_space = (execution) => {
  ;({ signal, guarded } = execution)
}

const call = async (start) => {
  const reply = await guarded(signal, start)
  if ("error" in reply) throw failure(reply.error)
  return reply.ok
}

const stream = (kind, sql, extra) => {
  let id = null
  let closed = false
  return {
    async next() {
      if (closed) return null
      if (id === null) {
        const opened = await call(() => openStream(kind, sql, extra))
        if (closed) {
          closeStream(opened)
          return null
        }
        id = opened
      }
      return await call(() => nextItem(id))
    },
    close() {
      if (closed) return
      closed = true
      if (id !== null) closeStream(id)
    },
  }
}

export const { query, observe, watch, mutateRows, readAttributes, patchAttributes } = createSpace({
  query: (sql, params) => call(() => hostQuery(sql, params)),
  observe: (sql, params) => stream("observe", sql, params),
  watch: (glob, from) => stream("watch", glob, from),
  mutateRows: (path, ops) => call(() => hostRows(path, ops)),
  readAttributes: (path) => call(() => hostAttributes(path)),
  patchAttributes: (path, patch) => call(() => hostPatch(path, patch)),
})

const anchor = (value) => (value instanceof Date ? value.toISOString() : value)

export function conversation(id, { after, before, limit } = {}) {
  return read(id, { after: anchor(after), before: anchor(before), limit })
}

export function dm(a, b) {
  return between(a, b)
}
"""#

let secretModule = #"""
const use = __wuhu_secret
const put = __wuhu_secret_set
const names = __wuhu_secret_list
const drop = __wuhu_secret_remove
const vaultPut = __wuhu_vault_set
const vaultNames = __wuhu_vault_list
const vaultDrop = __wuhu_vault_remove

// `{ machine }` names a machine's vault instead of the group's secrets.
const machineOf = (options) => {
  const machine = options?.machine
  if (machine === undefined || machine === null) return null
  if (options.group !== undefined && options.group !== null) throw new TypeError("name a group or a machine, not both")
  return String(machine)
}

export const secret = (name, options) => {
  // A vault's values never leave its machine, so no placeholder can stand for
  // one: exec's secrets argument is the way to use them.
  if (options?.machine !== undefined && options?.machine !== null) {
    throw new TypeError("secret() names a group's secrets; a machine vault's values never leave the machine, so pass the entry to exec as { secrets: { ENV: 'name' } }")
  }
  const group = options?.group
  return group === undefined || group === null ? use(String(name)) : use(String(name), String(group))
}

export async function set(name, value, options) {
  const machine = machineOf(options)
  if (machine === null) await put(String(name), String(value))
  else await vaultPut(machine, String(name), String(value))
}

export const list = (options) => {
  const machine = machineOf(options)
  if (machine !== null) return vaultNames(machine)
  const group = options?.group
  return group === undefined || group === null ? names() : names(String(group))
}

export async function remove(name, options) {
  const machine = machineOf(options)
  if (machine === null) await drop(String(name))
  else await vaultDrop(machine, String(name))
}
"""#

let machineModule = #"""
const { host, guarded, signal: running, bytesOf, base64Of } = globalThis.__wuhu_kernel
delete globalThis.__wuhu_kernel

const call = (start) => guarded(running, start)

const payload = (data) => {
  if (typeof data === "string") return { text: data }
  if (data instanceof ArrayBuffer) return { base64: base64Of(new Uint8Array(data)) }
  if (ArrayBuffer.isView(data)) return { base64: base64Of(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)) }
  throw new TypeError("data must be a string, an ArrayBuffer or a typed array")
}

const settings = (options = {}) => {
  const out = {}
  for (const key of ["cwd", "env", "secrets", "timeout", "maxOutput", "stdin"]) {
    if (options[key] !== undefined) out[key] = options[key]
  }
  return out
}

class Process {
  #id
  #reading = false
  #stdin = Promise.resolve()
  constructor(id) {
    this.#id = id
  }
  get id() {
    return this.#id
  }
  #claim() {
    if (this.#reading) throw new Error(`process ${this.#id} already has a reader`)
    this.#reading = true
  }
  async *#read(mode) {
    let done = false
    try {
      while (!done) {
        const batch = await call(() => host.machine_next(this.#id, mode))
        done = batch.done
        for (const item of batch.items) yield mode === "lines" ? item : { stream: item.stream, data: bytesOf(item.data) }
      }
    } finally {
      // The one reader left early (break, return or a throw): nobody can read
      // the rest, so the host drops it instead of holding it.
      if (!done) host.machine_discard(this.#id).catch(() => {})
    }
  }
  lines() {
    this.#claim()
    return this.#read("lines")
  }
  [Symbol.asyncIterator]() {
    this.#claim()
    return this.#read("bytes")
  }
  #queue(start) {
    const next = this.#stdin.then(() => call(start))
    this.#stdin = next.catch(() => {})
    return next
  }
  write(data) {
    const body = payload(data)
    return this.#queue(() => host.machine_write(this.#id, body))
  }
  end() {
    return this.#queue(() => host.machine_end(this.#id))
  }
  kill() {
    return host.machine_kill(this.#id)
  }
  wait() {
    return call(() => host.machine_wait(this.#id))
  }
}

const date = (entry) => ({ ...entry, mtime: new Date(entry.mtime * 1000) })

export const machines = () => call(() => host.machine_list())

export function machine(reference) {
  const ref = String(reference)
  const fs = (op, args) => call(() => host.machine_fs(ref, op, args))
  return Object.freeze({
    async stat(path) {
      const entry = await fs("stat", { path: String(path) })
      return entry === null ? null : date(entry)
    },
    async list(path) {
      return (await fs("list", { path: String(path) })).map(date)
    },
    async read(path) {
      return bytesOf(await fs("read", { path: String(path) }))
    },
    readText(path) {
      return fs("readText", { path: String(path) })
    },
    write(path, data, options = {}) {
      const body = { path: String(path), data: payload(data) }
      if (options.ifMatch !== undefined) body.ifMatch = String(options.ifMatch)
      return fs("write", body)
    },
    async remove(path) {
      await fs("remove", { path: String(path) })
    },
    async mkdir(path) {
      await fs("mkdir", { path: String(path) })
    },
    async move(from, to) {
      await fs("move", { from: String(from), to: String(to) })
    },
    exec(command, options) {
      return call(() => host.machine_exec(ref, String(command), settings(options)))
    },
    async spawn(command, options) {
      const { id } = await call(() => host.machine_spawn(ref, String(command), settings(options)))
      return new Process(id)
    },
  })
}
"""#

let scriptPrelude = #"""
(() => {
  const host = {}
  for (const name of Object.keys(globalThis)) {
    if (!name.startsWith("__wuhu_")) continue
    host[name.slice(7)] = globalThis[name]
    delete globalThis[name]
  }
  const internal = Symbol("internal")

  const bytesOf = (base64) => {
    const text = atob(base64)
    const out = new Uint8Array(text.length)
    for (let i = 0; i < text.length; i++) out[i] = text.charCodeAt(i)
    return out
  }
  const base64Of = (bytes) => {
    let text = ""
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(text)
  }

  class DOMException extends Error {
    constructor(message = "", name = "Error") {
      super(message)
      Object.defineProperty(this, "name", { value: name, writable: true, configurable: true })
    }
  }

  class Event {
    constructor(type) {
      this.type = String(type)
      this.target = null
    }
  }

  class EventTarget {
    #listeners = new Map()
    addEventListener(type, listener, options = {}) {
      if (!listener) return
      const { once = false, signal } = typeof options === "object" ? options : {}
      if (signal?.aborted) return
      let entries = this.#listeners.get(type)
      if (!entries) this.#listeners.set(type, (entries = []))
      if (entries.some((entry) => entry.listener === listener)) return
      entries.push({ listener, once })
      signal?.addEventListener("abort", () => this.removeEventListener(type, listener), { once: true })
    }
    removeEventListener(type, listener) {
      const entries = this.#listeners.get(type)
      const index = entries?.findIndex((entry) => entry.listener === listener) ?? -1
      if (index >= 0) entries.splice(index, 1)
    }
    dispatchEvent(event) {
      event.target = this
      for (const entry of [...(this.#listeners.get(event.type) ?? [])]) {
        if (entry.once) this.removeEventListener(event.type, entry.listener)
        try {
          if (typeof entry.listener === "function") entry.listener.call(this, event)
          else entry.listener.handleEvent(event)
        } catch (error) {
          console.error(error)
        }
      }
      return true
    }
  }

  let abortSignal
  class AbortSignal extends EventTarget {
    #aborted = false
    #reason = undefined
    onabort = null
    constructor(key) {
      if (key !== internal) throw new TypeError("Illegal constructor")
      super()
    }
    get aborted() {
      return this.#aborted
    }
    get reason() {
      return this.#reason
    }
    throwIfAborted() {
      if (this.#aborted) throw this.#reason
    }
    static abort(reason = new DOMException("signal is aborted without reason", "AbortError")) {
      const signal = new AbortSignal(internal)
      abortSignal(signal, reason)
      return signal
    }
    static timeout(ms) {
      const signal = new AbortSignal(internal)
      host.timer(Number(ms)).then(() => abortSignal(signal, new DOMException("signal timed out", "TimeoutError")))
      return signal
    }
    static any(signals) {
      const signal = new AbortSignal(internal)
      const sources = [...signals]
      const aborted = sources.find((source) => source.aborted)
      if (aborted) {
        abortSignal(signal, aborted.reason)
        return signal
      }
      for (const source of sources) {
        source.addEventListener("abort", () => abortSignal(signal, source.reason), { once: true })
      }
      return signal
    }
    static {
      abortSignal = (signal, reason) => {
        if (signal.#aborted) return
        signal.#aborted = true
        signal.#reason = reason
        const event = new Event("abort")
        signal.onabort?.call(signal, event)
        signal.dispatchEvent(event)
      }
    }
  }

  class AbortController {
    #signal = new AbortSignal(internal)
    get signal() {
      return this.#signal
    }
    abort(reason = new DOMException("signal is aborted without reason", "AbortError")) {
      abortSignal(this.#signal, reason)
    }
  }

  const execution = new AbortController()
  host.stopped().then((reason) => execution.abort(new DOMException(reason, "AbortError")))

  const watching = (options) =>
    options?.signal ? AbortSignal.any([execution.signal, options.signal]) : execution.signal

  // Rejects with the signal's reason and cancels the host call when `signal`
  // aborts first.
  const guarded = async (signal, start) => {
    signal.throwIfAborted()
    const call = start()
    const abort = () => host.cancel(call, signal.reason)
    signal.addEventListener("abort", abort, { once: true })
    try {
      return await call
    } finally {
      signal.removeEventListener("abort", abort)
    }
  }

  const sleep = async (ms, options) => {
    await guarded(watching(options), () => host.sleep(Number(ms)))
  }

  const timers = new Map()
  let nextTimer = 1
  const setTimeout = (callback, ms = 0, ...args) => {
    const id = nextTimer++
    if (execution.signal.aborted) return id
    const call = host.sleep(Number(ms))
    const cancel = () => clearTimeout(id)
    const settle = () => {
      timers.delete(id)
      execution.signal.removeEventListener("abort", cancel)
    }
    timers.set(id, call)
    execution.signal.addEventListener("abort", cancel, { once: true })
    call.then(() => {
      settle()
      callback(...args)
    }, settle)
    return id
  }
  const clearTimeout = (id) => {
    const call = timers.get(id)
    if (!call) return
    timers.delete(id)
    host.cancel(call, null)
  }

  const text = (value) => {
    if (typeof value === "string") return value
    if (value instanceof Error) return value.stack ? `${value}\n${value.stack}` : String(value)
    try {
      return JSON.stringify(value) ?? String(value)
    } catch {
      return String(value)
    }
  }
  const console = {}
  for (const level of ["log", "info", "debug", "warn", "error"]) {
    console[level] = (...args) => host.console(level, args.map(text).join(" "))
  }

  const outcome = (value) => (typeof value === "string" ? value : (JSON.stringify(value) ?? "null"))
  let resulted = false
  const result = (value) => {
    if (resulted) throw new Error("result() can be called only once")
    host.result(outcome(value))
    resulted = true
  }
  const update = (value) => {
    if (!resulted) throw new Error("update() needs result() first")
    host.update(outcome(value))
  }

  const token = /^[!#$%&'*+.^_`|~0-9a-z-]+$/
  const headerName = (name) => {
    const lowered = String(name).toLowerCase()
    if (!token.test(lowered)) throw new TypeError(`invalid header name: ${name}`)
    return lowered
  }

  class Headers {
    #fields = new Map()
    constructor(init) {
      if (init == null) return
      if (init instanceof Headers || typeof init[Symbol.iterator] === "function") {
        for (const pair of init) {
          if (pair.length !== 2) throw new TypeError("a header pair has exactly two items")
          this.append(pair[0], pair[1])
        }
      } else {
        for (const name of Object.keys(init)) this.append(name, init[name])
      }
    }
    append(name, value) {
      const key = headerName(name)
      const values = this.#fields.get(key)
      if (values) values.push(String(value).trim())
      else this.#fields.set(key, [String(value).trim()])
    }
    set(name, value) {
      this.#fields.set(headerName(name), [String(value).trim()])
    }
    get(name) {
      return this.#fields.get(headerName(name))?.join(", ") ?? null
    }
    getSetCookie() {
      return [...(this.#fields.get("set-cookie") ?? [])]
    }
    has(name) {
      return this.#fields.has(headerName(name))
    }
    delete(name) {
      this.#fields.delete(headerName(name))
    }
    *entries() {
      for (const name of [...this.#fields.keys()].sort()) {
        if (name === "set-cookie") for (const value of this.#fields.get(name)) yield [name, value]
        else yield [name, this.get(name)]
      }
    }
    *keys() {
      for (const [name] of this.entries()) yield name
    }
    *values() {
      for (const [, value] of this.entries()) yield value
    }
    [Symbol.iterator]() {
      return this.entries()
    }
    forEach(callback, thisArg) {
      for (const [name, value] of this.entries()) callback.call(thisArg, value, name, this)
    }
  }

  // A body is held in JS ({ text } or { bytes }) or, for a fetched response,
  // on the host ({ handle }) until it is read.
  const bodySource = (body) => {
    if (body == null) return null
    if (typeof body === "string") return { text: body }
    if (body instanceof ArrayBuffer) return { bytes: new Uint8Array(body.slice(0)) }
    if (ArrayBuffer.isView(body)) {
      return { bytes: new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)) }
    }
    return { text: String(body) }
  }

  let takeBody
  let setBody
  class Message {
    #source = null
    #used = false
    get bodyUsed() {
      return this.#used
    }
    #consume() {
      if (this.#used) throw new TypeError("body has already been read")
      this.#used = true
      const source = this.#source
      this.#source = null
      return source
    }
    async text() {
      const source = this.#consume()
      if (source === null) return ""
      if ("text" in source) return source.text
      if ("bytes" in source) return host.decode(base64Of(source.bytes))
      return host.body(source.handle, "text")
    }
    async arrayBuffer() {
      return (await this.bytes()).buffer
    }
    async bytes() {
      const source = this.#consume()
      if (source === null) return new Uint8Array(0)
      if ("text" in source) return bytesOf(host.encode(source.text))
      if ("bytes" in source) return source.bytes
      return bytesOf(host.body(source.handle, "base64"))
    }
    async json() {
      return JSON.parse(await this.text())
    }
    static {
      takeBody = (message) => (message.#source === null ? null : message.#consume())
      setBody = (message, source) => {
        message.#source = source
      }
    }
  }

  const methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]

  class Request extends Message {
    #url
    #method
    #headers
    #signal
    constructor(input, init = {}) {
      super()
      const from = input instanceof Request ? input : null
      const method = String(init.method ?? from?.method ?? "GET")
      this.#method = methods.includes(method.toUpperCase()) ? method.toUpperCase() : method
      this.#url = from ? from.url : String(input)
      this.#headers = new Headers(init.headers ?? from?.headers)
      this.#signal = init.signal ?? from?.signal ?? new AbortController().signal
      const source = init.body !== undefined ? bodySource(init.body) : from ? takeBody(from) : null
      if (source !== null && (this.#method === "GET" || this.#method === "HEAD")) {
        throw new TypeError(`a ${this.#method} request cannot have a body`)
      }
      if (typeof init.body === "string" && !this.#headers.has("content-type")) {
        this.#headers.set("content-type", "text/plain;charset=UTF-8")
      }
      setBody(this, source)
    }
    get url() {
      return this.#url
    }
    get method() {
      return this.#method
    }
    get headers() {
      return this.#headers
    }
    get signal() {
      return this.#signal
    }
  }

  let fetched
  class Response extends Message {
    #status
    #statusText
    #headers
    #url = ""
    constructor(body = null, init = {}) {
      super()
      const status = init.status ?? 200
      if (init[internal] !== true && (status < 200 || status > 599)) {
        throw new RangeError(`status ${status} is outside 200-599`)
      }
      this.#status = status
      this.#statusText = String(init.statusText ?? "")
      this.#headers = new Headers(init.headers)
      if (typeof body === "string" && !this.#headers.has("content-type")) {
        this.#headers.set("content-type", "text/plain;charset=UTF-8")
      }
      setBody(this, bodySource(body))
    }
    get status() {
      return this.#status
    }
    get statusText() {
      return this.#statusText
    }
    get ok() {
      return this.#status >= 200 && this.#status <= 299
    }
    get headers() {
      return this.#headers
    }
    get url() {
      return this.#url
    }
    get redirected() {
      return false
    }
    get type() {
      return this.#url ? "basic" : "default"
    }
    static json(data, init = {}) {
      const response = new Response(JSON.stringify(data), init)
      if (!new Headers(init.headers).has("content-type")) response.headers.set("content-type", "application/json")
      return response
    }
    static {
      fetched = (head) => {
        const response = new Response(null, {
          status: head.status,
          statusText: head.statusText,
          headers: head.headers,
          [internal]: true,
        })
        response.#url = head.url
        setBody(response, { handle: head.body })
        return response
      }
    }
  }

  const fetch = async (input, init) => {
    const request = new Request(input, init)
    const signal = AbortSignal.any([execution.signal, request.signal])
    const source = takeBody(request)
    const body = source === null ? null : "text" in source ? { text: source.text } : { base64: base64Of(source.bytes) }
    const call = () => host.fetch({ url: request.url, method: request.method, headers: [...request.headers], body })
    try {
      return fetched(await guarded(signal, call))
    } catch (error) {
      if (signal.aborted) throw signal.reason
      throw new TypeError(`fetch failed: ${error.message}`)
    }
  }

  for (const [name, link] of Object.entries(host)) {
    if (name.startsWith("link_")) link({ signal: execution.signal, guarded })
  }
  globalThis.__wuhu_kernel = { host, guarded, signal: execution.signal, bytesOf, base64Of }

  Object.assign(globalThis, {
    DOMException,
    Event,
    EventTarget,
    AbortSignal,
    AbortController,
    Headers,
    Request,
    Response,
    fetch,
    console,
    result,
    update,
    sleep,
    setTimeout,
    clearTimeout,
    signal: execution.signal,
  })
})()
"""#
