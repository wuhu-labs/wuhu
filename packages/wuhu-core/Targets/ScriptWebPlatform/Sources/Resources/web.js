// The web platform both script runtimes give a script, over its host's primitives:
// fetch(request), sleep(ms) and timer(ms) start host calls and return their promises (a timer
// does not keep the script alive); a request's body is null, { text } or { bytes }, and a
// rejection with a `code` reaches the script as is. cancel(promise, reason) gives a call up;
// decode(bytes) and encode(text) convert UTF-8; body(reply) is a fetched response's body,
// { bytes } or { read(as) } with `as` "text" or "bytes".
(host) => {
  const internal = Symbol("internal")
  const bytesOf = (base64) => {
    const binary = atob(base64)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  }
  const base64Of = (bytes) => {
    let binary = ""
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(binary)
  }
  const whole = (bytes) => bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes.buffer : bytes.slice().buffer

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
          globalThis.console.error(error)
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
        try {
          signal.onabort?.call(signal, event)
        } catch (error) {
          globalThis.console.error(error)
        }
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
  const watching = (options) => options?.signal ? AbortSignal.any([execution.signal, options.signal]) : execution.signal

  // Rejects with the signal's reason, and gives up the host call `start` made, when `signal`
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

  const bodySource = (body) => {
    if (body == null) return null
    if (typeof body === "string") return { text: body }
    if (body instanceof ArrayBuffer) return { bytes: new Uint8Array(body.slice(0)) }
    if (ArrayBuffer.isView(body)) return { bytes: new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)) }
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
      return "bytes" in source ? host.decode(source.bytes) : source.read("text")
    }
    async arrayBuffer() {
      return whole(await this.bytes())
    }
    async bytes() {
      const source = this.#consume()
      if (source === null) return new Uint8Array(0)
      if ("text" in source) return host.encode(source.text)
      return "bytes" in source ? source.bytes : source.read("bytes")
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
        const response = new Response(null, { status: head.status, statusText: head.statusText, headers: head.headers, [internal]: true })
        response.#url = head.url
        setBody(response, host.body(head))
        return response
      }
    }
  }

  const failure = (code, message) => {
    const error = new TypeError(message)
    error.code = code
    return error
  }

  const fetch = async (input, init) => {
    const hasIdentity = init != null && "identity" in Object(init)
    const identity = init?.identity
    if (hasIdentity && typeof identity !== "boolean") throw failure("invalidArgument", "identity must be a boolean")
    const request = new Request(input, init)
    if (identity === true && request.headers.has("authorization")) {
      throw failure("invalidArgument", "identity: true cannot be combined with Authorization")
    }
    const signal = AbortSignal.any([execution.signal, request.signal])
    const source = takeBody(request)
    try {
      const call = () => host.fetch({ url: request.url, method: request.method, headers: [...request.headers], body: source, identity: identity === true })
      const reply = await guarded(signal, call)
      if (reply.error) throw failure(reply.error.code, reply.error.message)
      return fetched(reply)
    } catch (error) {
      if (signal.aborted) throw signal.reason
      if (error.code) throw error
      throw new TypeError(`fetch failed: ${error.message}`)
    }
  }

  return {
    DOMException, Event, EventTarget, AbortSignal, AbortController, Headers, Request, Response, fetch, sleep, setTimeout, clearTimeout,
    signal: execution.signal,
    stop: (reason) => execution.abort(new DOMException(reason, "AbortError")),
    guarded, bytesOf, base64Of,
  }
}
