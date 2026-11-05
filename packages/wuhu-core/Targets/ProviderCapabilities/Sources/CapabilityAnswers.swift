#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import struct SpaceContract.TranscriptionOutput

extension CapabilityClient {
  /// `transcribe` as the routes and scripts answer it: anything but a capability's own failure is
  /// today's catch-all.
  public func transcription(_ clip: AudioClip, options: CapabilityOptions) async throws -> TranscriptionOutput {
    let transcription: Transcription
    do { transcription = try await transcribe(clip, options: options) }
    catch let error as CapabilityError { throw error }
    catch is CancellationError { throw CancellationError() }
    catch { throw CapabilityError(.providerUnavailable, "Transcription could not be completed.", hint: "Check the private audio input and selected capability provider.") }
    let encoder = JSONValueEncoder()
    return try TranscriptionOutput(
      text: transcription.text, provider: transcription.provider, model: transcription.model,
      language: transcription.language, durationSeconds: transcription.durationSeconds,
      segments: transcription.segments.map { try $0.map { try encoder.encode($0) } },
      words: transcription.words.map { try $0.map { try encoder.encode($0) } },
      confidence: transcription.confidence, usage: transcription.usage,
    )
  }
}
