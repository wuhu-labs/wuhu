#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import enum InferenceKit.AudioMediaType
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import JSONValue
import struct MachineContract.MachineID
import enum MainHub.Address
import enum MainHub.Addressing
import struct MainHub.ToolProblem
import OrderedCollections
import SessionDomain
import SpaceClient

// The capabilities (search, images, transcription) run on main behind its
// routes, with main's provider credentials; the worker sends the request and
// reads the private bytes a call names.
extension ToolExecutor {
  func capability(_ session: SessionID, _ kind: String) async throws -> JSONValue {
    try await capabilityCall { try await client(session).api(.get, "/v1/capabilities/\(pathSegment(kind))") }
  }

  func search(_ session: SessionID, _ query: String, options: CapabilityOptions) async throws -> JSONValue {
    var body: OrderedDictionary<String, JSONValue> = ["query": .string(query)]
    body["provider"] = options.provider.map(JSONValue.string)
    body["count"] = options.count.map(JSONValue.integer)
    return try await capabilityCall { try await client(session).api(.post, "/v1/web-search", body: .object(body)) }
  }

  /// A PNG from the image provider, with up to five PNG references.
  func image(_ session: SessionID, _ prompt: String, images: [Data], options: CapabilityOptions) async throws -> Data {
    var body: OrderedDictionary<String, JSONValue> = ["prompt": .string(prompt)]
    if !images.isEmpty { body["images"] = .array(images.map { .string($0.base64EncodedString()) }) }
    body["provider"] = options.provider.map(JSONValue.string)
    body["model"] = options.model.map(JSONValue.string)
    body["quality"] = options.quality.map(JSONValue.string)
    body["size"] = options.size.map(JSONValue.string)
    let output: ImageOutput = try await capabilityCall { try await client(session).api(.post, "/v1/image", body: .object(body)) }
    guard let image = Data(base64Encoded: output.b64JSON), PNGHeader(image) != nil else {
      throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a PNG.")
    }
    return image
  }

  func transcribe(_ session: SessionID, audio: String, options: CapabilityOptions) async throws -> JSONValue {
    let ext = URL(fileURLWithPath: audio).pathExtension.lowercased()
    let type: AudioMediaType? = switch ext {
    case "wav": .wav
    case "mp3": .mpeg
    case "m4a": .m4a
    case "mp4": .mp4
    case "webm": .webm
    default: nil
    }
    guard let type else { throw CapabilityError(.invalidArgument, "Audio extension must be wav, mp3, m4a, mp4 or webm.") }
    let bytes = try await capabilityInput(session, audio, limit: 25 * 1024 * 1024)
    let output = try await capabilityCall {
      try await client(session).transcribe(
        bytes, contentType: type.rawValue, language: options.language, provider: options.provider, model: options.model,
        timestamps: options.timestamps?.joined(separator: ","), diarize: options.diarize,
      )
    }
    return try JSONValueEncoder().encode(output)
  }

  /// A private file a capability takes as input, whole, at most `limit` bytes.
  func capabilityInput(_ session: SessionID, _ raw: String, limit: Int) async throws -> Data {
    let address = try await resolvedAddress(raw, as: session)
    if case .system = address { throw CapabilityError(.invalidArgument, "Capability inputs must be private space or authorized machine files.") }
    do {
      return try await client(session).file(address.rendered, limit: limit).data
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .notFound {
      throw CapabilityError(.invalidArgument, "Input file does not exist.")
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .byteLimitExceeded {
      throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.")
    }
  }

  /// `/models.json` and its companions from `shared`; nil when absent.
  func sharedDocument(_ session: SessionID, _ path: String) async throws -> Data? {
    do { return try await client(session).file("wuhu://shared.localspace" + path).data }
    catch let failure as SpaceClient.ToolFailure where failure.error.code == .notFound { return nil }
  }

  /// `raw` with a machine named by its roster name swapped for its id; a host
  /// that is neither names no machine.
  func resolvedAddress(_ raw: String, as session: SessionID) async throws -> Address {
    guard let host = Addressing.machineHost(raw), !host.isEmpty, !MachineID.isValid(host) else { return try Addressing.parse(raw) }
    guard let machine = await machineID(host, as: session) else { throw ToolProblem("unknown machine: \(host)") }
    return try Addressing.parse("machines://" + machine.rawValue + String(raw.dropFirst("machines://".count + host.count)))
  }

  // A capability route's refusal is the CapabilityError it carried.
  private func capabilityCall<Output>(_ run: () async throws -> Output) async throws -> Output {
    do {
      return try await run()
    } catch let failure as SpaceClient.ToolFailure {
      guard let code = CapabilityError.Code(rawValue: failure.error.code.rawValue) else { throw failure }
      throw failure.error.hint.map { CapabilityError(code, failure.error.message, hint: $0) } ?? CapabilityError(code, failure.error.message)
    } catch let failure as SpaceClient.TransportFailure {
      guard let code = failure.code.flatMap(CapabilityError.Code.init(rawValue:)) else { throw failure }
      throw CapabilityError(code, failure.message)
    }
  }
}

private struct ImageOutput: Decodable {
  var b64JSON: String
}
