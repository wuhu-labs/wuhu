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
      try await owner.capabilityDocument(path)
    }, credentials: credentials)
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
    let bytes = try await owner.capabilityInput(audio, as: session, limit: 25 * 1024 * 1024)
    return try await capabilities().transcribe(.init(bytes: bytes, mediaType: type), options: options)
  }
}
