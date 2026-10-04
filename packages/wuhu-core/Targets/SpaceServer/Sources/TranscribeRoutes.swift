#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Fetch
import struct InferenceKit.AudioClip
import enum InferenceKit.AudioMediaType
import struct InferenceKit.CapabilityClient
import struct InferenceKit.CapabilityError
import struct InferenceKit.CapabilityOptions
import enum InferenceKit.TranscriptionLimits
import JSONValue
import ServeRouting
import SpaceContract
import SpaceCore

func addTranscribeRoutes(_ router: inout Router, space: Space, credentials: CredentialResolver) {
  router.get("/v1/transcribe") { _, _ in
    do {
      let info = try await spaceCapabilities(space: space, credentials: credentials).transcriberInfo()
      return try Response.json(TranscriberInfo(available: true, provider: info.provider, model: info.model))
    } catch {
      return try Response.json(TranscriberInfo(available: false, provider: nil, model: nil))
    }
  }

  router.post("/v1/transcribe") { request, _ in
    guard let header = request.headers[.contentType], let mediaType = AudioMediaType(header: header) else {
      return errorResponse(.unsupportedMediaType, code: "invalid_argument", message: "Transcription needs an audio content type.", hint: AudioMediaType.allCases.map(\.rawValue).joined(separator: ", "))
    }
    do {
      let client = try await spaceCapabilities(space: space, credentials: credentials)
      let query = queryValues(of: request.url)
      let options = CapabilityOptions(provider: query["provider"], model: query["model"], language: query["language"], timestamps: query["timestamps"].map { $0.split(separator: ",").map(String.init) }, diarize: query["diarize"].map { $0 == "true" })
      if let value = query["diarize"], !["true", "false"].contains(value) { throw CapabilityError(.invalidArgument, "diarize must be true or false.") }
      _ = try await client.transcriberInfo(options: options)
      let bytes = try await request.body?.data(upTo: TranscriptionLimits.maximumBytes) ?? Data()
      let transcription = try await client.transcribe(AudioClip(bytes: bytes, mediaType: mediaType), options: options)
      return try Response.json(TranscriptionOutput(
        text: transcription.text, provider: transcription.provider, model: transcription.model,
        language: transcription.language, durationSeconds: transcription.durationSeconds,
        segments: try transcription.segments.map { try $0.map { try JSONValueEncoder().encode($0) } },
        words: try transcription.words.map { try $0.map { try JSONValueEncoder().encode($0) } },
        confidence: transcription.confidence, usage: transcription.usage,
      ))
    } catch let error as CapabilityError {
      return capabilityFailure(error)
    } catch FetchError.bodyLimitExceeded {
      return errorResponse(.contentTooLarge, code: "invalid_argument", message: "Audio exceeds the 25 MiB transcription bound.")
    } catch {
      return capabilityFailure(.init(.providerUnavailable, "Transcription could not be completed.", hint: "Check the private audio input and selected capability provider."))
    }
  }
}

func spaceCapabilities(space: Space, credentials: CredentialResolver) async throws -> CapabilityClient {
  try await CapabilityClient.load(read: { path in
    do { return try await space.fs(.shared).read(path).1 }
    catch SpaceError.notFound { return nil }
  }, credentials: credentials)
}

func capabilityFailure(_ error: CapabilityError) -> Response {
  let status: Status = switch error.code {
  case .invalidArgument, .unsupportedFeature: .badRequest
  case .providerAuth: .unauthorized
  case .providerRegion, .providerEntitlement: .forbidden
  case .providerRateLimited: .tooManyRequests
  case .providerNotConfigured, .providerUnavailable: .serviceUnavailable
  }
  return errorResponse(status, code: error.code.rawValue, message: error.message, hint: error.hint)
}
