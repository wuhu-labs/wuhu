import enum ScriptWebPlatform.ScriptWebPlatform

// The JS half of run_script. The modules are defined first so they can capture
// their host functions; `scriptPrelude` then builds the globals and deletes every
// `__wuhu_*` host function, so a script reaches the host only through them. A
// module that needs the execution's abort signal defines `__wuhu_link_<name>`,
// which the prelude calls once with `{ signal, guarded }`. The prelude also
// leaves its internals in `__wuhu_kernel` for `wuhu:host`, which hands them to the shared modules
// of ScriptWebPlatform, defined last; the kernel is deleted after them.

let hostModule = #"""
export const claim = () => {
  const kernel = globalThis.__wuhu_kernel
  if (kernel === undefined) throw new TypeError("wuhu:host belongs to the built-in modules")
  return kernel
}
"""#

let spaceModule = #"""
import { createSpace, failure } from "wuhu:space-core"

const hostQuery = __wuhu_space_query
const openStream = __wuhu_space_open
const nextItem = __wuhu_space_next
const closeStream = __wuhu_space_close
const hostRows = __wuhu_space_rows
const hostAttributes = __wuhu_space_attributes
const hostPatch = __wuhu_space_patch
const hostVerb = __wuhu_space_verb
const discover = __wuhu_discovery
const createGroupHost = __wuhu_create_group
const identityOrigin = __wuhu_identity_origin
const read = __wuhu_conversation
const between = __wuhu_dm
const channel = __wuhu_channel

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

export const { query, observe, watch, mutateRows, readAttributes, patchAttributes, find, grep } = createSpace({
  query: (sql, params) => call(() => hostQuery(sql, params)),
  observe: (sql, params) => stream("observe", sql, params),
  watch: (glob, from) => stream("watch", glob, from),
  mutateRows: (path, ops) => call(() => hostRows(path, ops)),
  readAttributes: (path) => call(() => hostAttributes(path)),
  patchAttributes: (path, patch) => call(() => hostPatch(path, patch)),
  find: (search) => call(() => hostVerb("find", search, {})),
  grep: (search) => call(() => hostVerb("grep", search, {})),
})

export const context = () => call(() => discover("context"))
export const groups = () => call(() => discover("groups"))
export const createGroup = (input) => call(() => createGroupHost(input))
export async function identity() {
  const snapshot = await call(() => discover("identity"))
  return { ...snapshot, issuerFor(origin) {
    const canonical = identityOrigin(origin)
    if (canonical === null) throw new TypeError("issuerFor takes an exact HTTP(S) audience origin")
    return snapshot.overrides[canonical] ?? snapshot.defaultIssuer
  } }
}

export function createTable(path, header) {
  return call(() => hostVerb("table.create", { path, header }, {}))
}
export function tableSchema(path, options = {}) {
  return call(() => hostVerb("table.schema", { path }, options))
}
export function alterTable(path, header, options = {}) {
  return call(() => hostVerb("table.alter", { path, header }, options))
}
export function instantiateTemplate(template, options = {}) {
  return call(() => hostVerb("new", { template }, options))
}
export function remove(path, options = {}) {
  return call(() => hostVerb("rm", { path }, options))
}

const anchor = (value) => (value instanceof Date ? value.toISOString() : value)

export function conversation(id, { after, before, limit } = {}) {
  return read(id, { after: anchor(after), before: anchor(before), limit })
}

export const createChannel = (options) => call(() => channel("create", options))
export const addChannelMembers = (id, people) => call(() => channel("add", { id, people }))
export const removeChannelMembers = (id, people) => call(() => channel("remove", { id, people }))
export const renameChannel = (id, title) => call(() => channel("rename", { id, title }))

export function dm(a, b) {
  return between(a, b)
}
"""#

let secretModule = #"""
const use = __wuhu_secret
const put = __wuhu_secret_set
const names = __wuhu_secret_list
const drop = __wuhu_secret_remove
const noMachine = (options) => {
  if (options?.machine !== undefined && options?.machine !== null) {
    throw new TypeError("machines keep no secrets of their own: an exec's { secrets: { ENV: 'NAME' } } names a secret of the machine's group, set and listed here as that group's")
  }
}

export const secret = (name, options) => {
  noMachine(options)
  const group = options?.group
  return group === undefined || group === null ? use(String(name)) : use(String(name), String(group))
}

export async function set(name, value, options) {
  noMachine(options)
  await put(String(name), String(value))
}

export const list = (options) => {
  noMachine(options)
  const group = options?.group
  return group === undefined || group === null ? names() : names(String(group))
}

export async function remove(name, options) {
  noMachine(options)
  await drop(String(name))
}
"""#

let scriptPrelude = """
(() => {
  const host = {}
  for (const name of Object.keys(globalThis)) {
    if (!name.startsWith("__wuhu_")) continue
    host[name.slice(7)] = globalThis[name]
    delete globalThis[name]
  }
  const web = (\(ScriptWebPlatform.source))({
    fetch: ({ body, ...request }) => host.fetch({ ...request, body: body !== null && "bytes" in body ? { base64: web.base64Of(body.bytes) } : body }),
    sleep: host.sleep,
    timer: host.timer,
    cancel: host.cancel,
    decode: (bytes) => host.decode(web.base64Of(bytes)),
    encode: (text) => web.bytesOf(host.encode(text)),
    body: (reply) => ({ read: (as) => (as === "text" ? host.body(reply.body, "text") : web.bytesOf(host.body(reply.body, "base64"))) }),
  })
  host.stopped().then(web.stop)
""" + #"""

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

  const { guarded, signal, bytesOf, base64Of } = web
  for (const [name, link] of Object.entries(host)) {
    if (name.startsWith("link_")) link({ signal, guarded })
  }
  globalThis.__wuhu_kernel = { host, guarded, signal, bytesOf, base64Of }
  Object.assign(globalThis, {
    DOMException: web.DOMException,
    Event: web.Event,
    EventTarget: web.EventTarget,
    AbortSignal: web.AbortSignal,
    AbortController: web.AbortController,
    Headers: web.Headers,
    Request: web.Request,
    Response: web.Response,
    fetch: web.fetch,
    console,
    result,
    update,
    sleep: web.sleep,
    setTimeout: web.setTimeout,
    clearTimeout: web.clearTimeout,
    signal,
  })
})()
"""#
