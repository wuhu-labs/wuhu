import { failure } from "wuhu:space-core"
import { claim } from "wuhu:host"
const { host } = claim()
const discover = host.discovery
const create = host.session_create
const ask = host.session_request
const send = host.session_send
const retag = host.session_tags
const act = host.session_control
const stop = host.session_cancel
const observer = host.session_observer

export async function toolRoster() {
  const reply = await discover("toolRoster")
  if (reply.error) throw failure(reply.error)
  return reply.ok
}

export async function createSession(options) {
  if (options === null || typeof options !== "object") {
    throw new TypeError("createSession needs { title, kind, topLevel, group, provider, model, modelGroup, effort, template, tags, message, expectsReply, stallSeconds, key, request }")
  }
  const made = await create(options)
  if (made.error !== undefined) {
    const error = new Error(made.error)
    if (made.id !== undefined) error.id = made.id
    if (made.code !== undefined) error.code = made.code
    throw error
  }
  const result = made.requestId === undefined ? { id: made.id } : { id: made.id, requestId: made.requestId }
  for (const key of ["modelGroup", "member", "provider", "model"]) {
    if (made[key] !== undefined) result[key] = made[key]
  }
  return result
}

function answered(reply) {
  if (reply !== null && typeof reply === "object" && reply.error !== undefined) {
    const error = new Error(reply.error)
    if (reply.code !== undefined) error.code = reply.code
    throw error
  }
  return reply
}

export async function sendMessage(options) {
  return answered(await send(options))
}

export async function request(id, message, { stallSeconds, schema, fields } = {}) {
  return answered(await ask(String(id), String(message), stallSeconds ?? null, { schema, fields }))
}

export async function setTags(id, tags) {
  if (!Array.isArray(tags)) throw new TypeError("setTags(id, tags) wants an array of strings")
  await retag(String(id), tags)
}

export async function archive(id, { force = false } = {}) {
  await act("archive", String(id), force)
}

export async function unarchive(id) {
  await act("unarchive", String(id))
}

export async function interrupt(id) {
  await act("interrupt", String(id))
}

export async function resume(id) {
  await act("resume", String(id))
}

export async function createObserver(group, options) {
  if (options === null || typeof options !== "object") {
    throw new TypeError("createObserver(group, { name, handler, observe: { sql | url, throttleSeconds } | timer: { inSeconds | cron }, sessionsPerHour })")
  }
  return answered(await observer("createObserver", String(group), options))
}

export async function cancelObserver(group, name) {
  return answered(await observer("cancelObserver", String(group), String(name)))
}

export async function observers(group) {
  return answered(await observer("observers", String(group)))
}

export async function cancel(id) {
  const reply = await stop(String(id))
  if (reply.error !== undefined) {
    const error = new Error(reply.error)
    error.code = reply.code
    throw error
  }
  return reply
}
