import JSONValue
import struct MainHub.ToolProblem
import struct ProviderCapabilities.CapabilityError
import struct ProviderCapabilities.CapabilityOptions
import enum ProviderCapabilities.FrameSelection
import QuickJSKit
import SessionDomain
import SpaceTools

struct ScriptAI {
  let actor: ScriptActor
  let tools: ToolExecutor
  let execution: ScriptExecution

  func install(in engine: JSEngine) {
    installCompletion(in: engine)
    let claims = MachineWriteClaims()
    engine.define("__wuhu_capability", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(kind)? = arguments.first else {
          throw CapabilityError(.invalidArgument, "capability needs a capability kind.")
        }
        return try await tools.capability(session, kind)
      }
    })
    engine.define("__wuhu_generate_image", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(prompt)? = arguments.first,
              case let .string(destination)? = arguments[safe: 1]?.object?["destination"]
        else {
          throw CapabilityError(.invalidArgument, "generateImage needs a prompt and { destination }.")
        }
        let options = try capabilityOptions(arguments[safe: 1], allowed: ["destination", "provider", "model", "quality", "size", "frames", "frameMs"])
        let paths: [String]
        if case let .array(values)? = arguments[safe: 2] {
          paths = try values.map {
            guard case let .string(path) = $0 else { throw CapabilityError(.invalidArgument, "Reference images must be private paths.") }
            return path
          }
          guard !paths.isEmpty else { throw CapabilityError(.invalidArgument, "editImage needs at least one reference image.") }
        } else { paths = [] }
        return try await tools.generateImage(session, prompt: prompt, destination: destination, claims: claims, images: paths, options: options)
      }
    })
    engine.define("__wuhu_inspect_image", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(path)? = arguments.first else { throw CapabilityError(.invalidArgument, "inspectImage needs an image path.") }
        return try await tools.inspectImage(session, path)
      }
    })
    engine.define("__wuhu_render_frames", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(path)? = arguments.first, let options = arguments[safe: 1]?.object,
              case let .string(destination)? = options["destination"], options.keys.allSatisfy(["destination", "frames"].contains)
        else {
          throw CapabilityError(.invalidArgument, "renderFrames needs a GIF path and { destination, frames? }.")
        }
        return try await tools.renderFrames(session, path, frames: frameSelection(options["frames"]), destination: destination, claims: claims)
      }
    })
    engine.define("__wuhu_transcribe", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(audio)? = arguments.first else { throw CapabilityError(.invalidArgument, "transcribe needs a private audio path.") }
        return try await tools.transcribe(session, audio: audio, options: capabilityOptions(arguments[safe: 1], allowed: ["provider", "model", "language", "timestamps", "diarize"]))
      }
    })
    engine.define("__wuhu_web_search", promising: { [actor, tools] arguments in
      try await capabilityAnswer {
        let session = try capabilitySession(actor)
        guard case let .string(query)? = arguments.first else { throw CapabilityError(.invalidArgument, "webSearch needs a query.") }
        return try await tools.search(session, query, options: capabilityOptions(arguments[safe: 1], allowed: ["provider", "count"]))
      }
    })
  }
}

private func capabilitySession(_ actor: ScriptActor) throws -> SessionID {
  guard let session = actor.session else {
    throw CapabilityError(.invalidArgument, "Capabilities run as a session; a script without one has complete() only.")
  }
  return session
}

private func frameSelection(_ value: JSONValue?) throws -> FrameSelection {
  switch value {
  case nil, .null?: return .count(9)
  case let .integer(count)?: return .count(count)
  case let .array(indices)?:
    return try .indices(indices.map {
      guard case let .integer(index) = $0 else { throw CapabilityError(.invalidArgument, "Frame indices are whole numbers.") }
      return index
    })
  default: throw CapabilityError(.invalidArgument, "frames is a count or a list of frame indices.")
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
