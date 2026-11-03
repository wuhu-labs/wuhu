import { claim } from "wuhu:host"
const { host, guarded, signal } = claim()
const call = (start) => guarded(signal, start)

export class CapabilityError extends Error {
  constructor(payload) {
    super(payload.message)
    this.name = "CapabilityError"
    this.code = payload.code
    this.hint = payload.hint
  }
}
const answer = (value) => {
  if (value.error) throw new CapabilityError(value.error)
  return value.ok
}

export class CompletionError extends Error {
  constructor(payload) {
    super(payload.message)
    this.name = "CompletionError"
    this.code = payload.code
    if (payload.provider !== undefined) this.provider = payload.provider
  }
}
export const complete = async (input, options) => {
  const value = await call(() => host.complete(input, options))
  if (value.error) throw new CompletionError(value.error)
  return value.ok
}

const limit = 4
let running = 0
const waiting = []
const turn = () => running < limit ? (running++, Promise.resolve()) : new Promise((resolve) => waiting.push(resolve))
const done = () => { const next = waiting.shift(); if (next) next(); else running-- }
async function image(prompt, options, images) {
  if (typeof options?.destination !== "string") throw new CapabilityError({ code: "invalid_argument", message: "Image calls need { destination }", hint: "Use a create-only space or authorized machine path." })
  await turn()
  try { return answer(await call(() => host.generate_image(String(prompt), options, images))) }
  finally { done() }
}
export const capability = async (kind) => answer(await call(() => host.capability(kind)))
export const generateImage = (prompt, options) => image(prompt, options)
export const editImage = (images, prompt, options) => {
  if (!Array.isArray(images) || images.length === 0) throw new CapabilityError({ code: "invalid_argument", message: "editImage needs reference image paths", hint: "Pass an array of one to five private PNG paths." })
  return image(prompt, options, images)
}
export const transcribe = async (audio, options = {}) => answer(await call(() => host.transcribe(audio, options)))
