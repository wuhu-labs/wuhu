#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct InferenceKit.AudioClip
import enum InferenceKit.AudioMediaType
import struct InferenceKit.CapabilityClient
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import struct InferenceKit.Transcription
import SessionDomain
import SpaceCore

extension ToolExecutor {
  func capabilities() async throws -> CapabilityClient {
    try await CapabilityClient.load(read: { path in
      do { return try await space.fs(.shared).read(path).1 }
      catch SpaceError.notFound { return nil }
    }, credentials: credentials)
  }

  func capabilityInput(_ raw: String, as session: SessionID, limit: Int) async throws -> Data {
    let address = try await resolve(raw, as: session)
    switch address {
    case let .machine(machine, path):
      guard let entry = try await machineStat(machine, path: path) else { throw CapabilityError(.invalidArgument, "Input file does not exist.") }
      guard entry.size <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      return try await Data(machineFile(machine, path: path, entry: entry, reference: address.rendered))
    case let .space(path, group, _):
      let entry = try await space.fs(group).stat(path)
      guard entry.size <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      let bytes = try await readRaw(address).1
      guard bytes.count <= limit else { throw CapabilityError(.invalidArgument, "Input exceeds the \(limit)-byte bound.") }
      return bytes
    case .system: throw CapabilityError(.invalidArgument, "Capability inputs must be private space or authorized machine files.")
    }
  }

  func transcribe(_ session: SessionID, audio: String, options: CapabilityOptions) async throws -> Transcription {
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
    let bytes = try await capabilityInput(audio, as: session, limit: 25 * 1024 * 1024)
    return try await capabilities().transcribe(.init(bytes: bytes, mediaType: type), options: options)
  }
}
