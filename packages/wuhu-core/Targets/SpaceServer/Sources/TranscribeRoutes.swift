#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Credentials.CredentialResolver
import Fetch
import struct InferenceKit.AudioClip
import enum InferenceKit.AudioMediaType
import struct InferenceKit.ModelsDocument
import struct InferenceKit.ProviderCatalog
import protocol InferenceKit.Transcriber
import struct InferenceKit.Transcription
import enum InferenceKit.TranscriptionError
import enum InferenceKit.TranscriptionLimits
import Logging
import ServeRouting
import SpaceContract
import SpaceCore

func addTranscribeRoutes(_ router: inout Router, space: Space, credentials: CredentialResolver) {
  router.get("/v1/transcribe") { _, _ in
    let transcriber = await spaceTranscriber(space: space, credentials: credentials)
    return try Response.json(TranscriberInfo(
      available: transcriber != nil,
      provider: transcriber?.providerID,
      model: transcriber?.model,
    ))
  }

  router.post("/v1/transcribe") { request, _ in
    guard let header = request.headers[.contentType], let mediaType = AudioMediaType(header: header) else {
      return errorResponse(
        .unsupportedMediaType,
        code: ErrorCode.unsupported.rawValue,
        message: "transcription needs an audio content type",
        hint: AudioMediaType.allCases.map(\.rawValue).joined(separator: ", "),
      )
    }
    // Resolve before buffering: a space with no provider must refuse the
    // upload, not pay 25 MiB of memory to discover it cannot serve it.
    guard let transcriber = await spaceTranscriber(space: space, credentials: credentials) else {
      return transcribeFailure(.noTranscriber, provider: nil)
    }
    let bytes: Data
    do {
      bytes = try await request.body?.data(upTo: TranscriptionLimits.maximumBytes) ?? Data()
    } catch FetchError.bodyLimitExceeded {
      return errorResponse(
        .contentTooLarge,
        code: ErrorCode.invalidArgument.rawValue,
        message: "audio exceeds the \(TranscriptionLimits.maximumBytes)-byte transcription bound",
      )
    } catch {
      return errorResponse(
        .badRequest,
        code: ErrorCode.invalidArgument.rawValue,
        message: "the audio body could not be read",
      )
    }
    let transcription: Transcription
    do {
      transcription = try await transcriber.transcribe(
        AudioClip(bytes: bytes, mediaType: mediaType),
        language: queryValues(of: request.url)["language"],
      )
    } catch let error as TranscriptionError {
      return transcribeFailure(error, provider: transcriber.providerID)
    }
    return try Response.json(TranscriptionOutput(
      text: transcription.text,
      provider: transcription.provider,
      model: transcription.model,
      language: transcription.language,
      durationSeconds: transcription.durationSeconds,
    ))
  }
}

private func spaceTranscriber(space: Space, credentials: CredentialResolver) async -> (any Transcriber)? {
  let document: ModelsDocument
  if let (_, data) = try? await space.fs(.shared).read(ModelsDocument.spacePath), let parsed = try? ModelsDocument(json: data) {
    document = parsed
  } else {
    document = ModelsDocument(providers: [:])
  }
  return await ProviderCatalog(document: document, credentials: credentials).resolveTranscriber()
}

func transcribeFailure(_ error: TranscriptionError, provider: String?) -> Response {
  if let provider {
    Logger(label: "wuhu.transcribe").warning("\(provider) transcription failed: \(error.diagnostic)")
  }
  let message = provider.map { "\($0): \(error.description)" } ?? error.description
  return switch error {
  case .noTranscriber:
    errorResponse(
      .serviceUnavailable,
      code: "noTranscriber",
      message: message,
      hint: "wuhu auth login codex, or wuhu auth set openai",
    )
  case .unsupportedMediaType:
    errorResponse(.unsupportedMediaType, code: ErrorCode.unsupported.rawValue, message: message)
  case .tooLarge:
    errorResponse(.contentTooLarge, code: ErrorCode.invalidArgument.rawValue, message: message)
  case .empty:
    errorResponse(.badRequest, code: ErrorCode.invalidArgument.rawValue, message: message)
  case let .upstream(status, _):
    errorResponse(
      status == 429 ? .tooManyRequests : .badGateway,
      code: ErrorCode.unavailable.rawValue,
      message: message,
    )
  case .transport:
    errorResponse(.serviceUnavailable, code: ErrorCode.unavailable.rawValue, message: message)
  case .malformedResponse:
    errorResponse(.badGateway, code: ErrorCode.unavailable.rawValue, message: message)
  }
}
