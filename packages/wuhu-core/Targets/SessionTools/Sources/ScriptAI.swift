import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import JSONValue
import QuickJSKit
import SessionDomain
import SpaceTools

let scriptImageConcurrency = 4

struct ScriptAI {
  let session: SessionID
  let tools: ToolExecutor

  func install(in engine: JSEngine) throws {
    let claims = MachineWriteClaims()
    engine.define("__wuhu_capability", promising: { [session, tools] arguments in
      try await capabilityAnswer {
        try await tools.refuseUnlessLive(session)
        guard case let .string(kind)? = arguments.first else {
          throw CapabilityError(.invalidArgument, "capability needs a capability kind.")
        }
        return try await tools.capabilities().capability(kind)
      }
    })
    engine.define("__wuhu_generate_image", promising: { [session, tools] arguments in
      try await capabilityAnswer {
        guard case let .string(prompt)? = arguments.first,
              case let .string(destination)? = arguments[safe: 1]?.object?["destination"]
        else {
          throw CapabilityError(.invalidArgument, "generateImage needs a prompt and { destination }.")
        }
        let options = try capabilityOptions(arguments[safe: 1], allowed: ["destination", "provider", "model", "quality", "size"])
        let paths: [String]
        if case let .array(values)? = arguments[safe: 2] {
          paths = try values.map {
            guard case let .string(path) = $0 else { throw CapabilityError(.invalidArgument, "Reference images must be private paths.") }
            return path
          }
          guard !paths.isEmpty else { throw CapabilityError(.invalidArgument, "editImage needs at least one reference image.") }
        } else { paths = [] }
        let image = try await tools.generateImage(session, prompt: prompt, destination: destination, claims: claims, images: paths, options: options)
        return .object(["path": .string(image.path), "mimeType": .string("image/png"), "bytes": .integer(image.bytes), "width": .integer(image.width), "height": .integer(image.height)])
      }
    })
    engine.define("__wuhu_transcribe", promising: { [session, tools] arguments in
      try await capabilityAnswer {
        guard case let .string(audio)? = arguments.first else { throw CapabilityError(.invalidArgument, "transcribe needs a private audio path.") }
        let value = try await tools.transcribe(session, audio: audio, options: capabilityOptions(arguments[safe: 1], allowed: ["provider", "model", "language", "timestamps", "diarize"]))
        return try JSONValueEncoder().encode(value)
      }
    })
    engine.define("__wuhu_web_search", promising: { [tools] arguments in
      try await capabilityAnswer {
        guard case let .string(query)? = arguments.first else { throw CapabilityError(.invalidArgument, "webSearch needs a query.") }
        let value = try await tools.capabilities().search(query, options: capabilityOptions(arguments[safe: 1], allowed: ["provider", "count"]))
        return try JSONValueEncoder().encode(value)
      }
    })
    try engine.defineModule("wuhu:ai", source: aiModule)
    try engine.defineModule("wuhu:web_search", source: webSearchModule)
  }
}

private func capabilityOptions(_ value: JSONValue?, allowed: Set<String>) throws -> CapabilityOptions {
  if let value, value != .null {
    guard let object = value.object, object.keys.allSatisfy(allowed.contains) else {
      throw CapabilityError(.invalidArgument, "Unknown capability option.")
    }
  }
  do { return try JSONValueDecoder().decode(CapabilityOptions.self, from: value ?? .object([:])) }
  catch { throw CapabilityError(.invalidArgument, "Malformed capability options.") }
}

private func capabilityAnswer(_ body: () async throws -> JSONValue) async throws -> JSONValue {
  do { return .object(["ok": try await body()]) }
  catch is CancellationError { throw CancellationError() }
  catch let error as CapabilityError { return .object(["error": try JSONValueEncoder().encode(error)]) }
  catch let error as ToolProblem { return .object(["error": try JSONValueEncoder().encode(CapabilityError(.invalidArgument, error.message))]) }
  catch { return .object(["error": Wire.failure(error).payload]) }
}

private let capabilityModule = #"""
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
"""#

private let aiModule = capabilityModule + "\n" + #"""
const probe = __wuhu_capability
const generate = __wuhu_generate_image
const recognize = __wuhu_transcribe
let signal
let guarded
globalThis.__wuhu_link_ai = (execution) => { ;({ signal, guarded } = execution) }
const limit = \#(scriptImageConcurrency)
let running = 0
const waiting = []
const turn = () => running < limit ? (running++, Promise.resolve()) : new Promise((resolve) => waiting.push(resolve))
const done = () => { const next = waiting.shift(); if (next) next(); else running-- }
async function image(prompt, options, images) {
  if (typeof options?.destination !== "string") throw new CapabilityError({ code: "invalid_argument", message: "Image calls need { destination }", hint: "Use a create-only space or authorized machine path." })
  await turn()
  try { return answer(await guarded(signal, () => generate(String(prompt), options, images))) }
  finally { done() }
}
export const capability = async (kind) => answer(await guarded(signal, () => probe(kind)))
export const generateImage = (prompt, options) => image(prompt, options)
export const editImage = (images, prompt, options) => {
  if (!Array.isArray(images) || images.length === 0) throw new CapabilityError({ code: "invalid_argument", message: "editImage needs reference image paths", hint: "Pass an array of one to five private PNG paths." })
  return image(prompt, options, images)
}
export const transcribe = async (audio, options = {}) => answer(await guarded(signal, () => recognize(audio, options)))
"""#

private let webSearchModule = capabilityModule + "\n" + #"""
const search = __wuhu_web_search
let signal
let guarded
globalThis.__wuhu_link_web_search = (execution) => { ;({ signal, guarded } = execution) }
export const webSearch = async (query, options = {}) => answer(await guarded(signal, () => search(query, options)))
export default webSearch
"""#
