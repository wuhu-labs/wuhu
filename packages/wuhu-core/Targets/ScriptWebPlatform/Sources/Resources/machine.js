import { failure } from "wuhu:space-core"
import { claim } from "wuhu:host"
const { host, guarded, signal: running, bytesOf, base64Of } = claim()

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

const ownExec = async (operation, id) => {
  const value = await call(() => host.machine_own_exec(operation, id))
  if (value.error) throw failure(value.error)
  return value.ok
}
export const execs = () => ownExec("list")
export const execStatus = (id) => ownExec("status", id)
export const killExec = (id) => ownExec("kill", id)
export const machines = () => call(() => host.machine_list())
export const copy = async (from, to, options = {}) => {
  const value = await call(() => host.machine_copy(String(from), String(to), options.overwrite === true))
  if (value.error) throw failure(value.error)
  return value.ok
}

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
