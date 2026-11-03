#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue

public enum AudioMediaType: String, Sendable, Hashable, CaseIterable, Codable {
  case wav = "audio/wav"
  case mpeg = "audio/mpeg"
  case mp4 = "audio/mp4"
  case m4a = "audio/m4a"
  case webm = "audio/webm"

  public init?(header: String) {
    let value = header.split(separator: ";", maxSplits: 1)[0]
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
    switch value {
    case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave":
      self = .wav
    case "audio/mpeg", "audio/mp3", "audio/x-mp3":
      self = .mpeg
    case "audio/mp4":
      self = .mp4
    case "audio/m4a", "audio/x-m4a":
      self = .m4a
    case "audio/webm":
      self = .webm
    default:
      return nil
    }
  }

  public var fileExtension: String {
    switch self {
    case .wav: "wav"
    case .mpeg: "mp3"
    case .mp4: "mp4"
    case .m4a: "m4a"
    case .webm: "webm"
    }
  }
}

public struct AudioClip: Sendable, Hashable {
  public var bytes: Data
  public var mediaType: AudioMediaType

  public init(bytes: Data, mediaType: AudioMediaType) {
    self.bytes = bytes
    self.mediaType = mediaType
  }
}

public struct TranscriptionSpan: Sendable, Hashable, Codable {
  public var text: String
  public var start: Double?
  public var end: Double?
  public var speaker: String?
  public var confidence: Double?

  public init(text: String, start: Double? = nil, end: Double? = nil, speaker: String? = nil, confidence: Double? = nil) {
    self.text = text
    self.start = start
    self.end = end
    self.speaker = speaker
    self.confidence = confidence
  }
}

public struct Transcription: Sendable, Hashable, Codable {
  public var text: String
  public var provider: String
  public var model: String
  public var language: String?
  public var durationSeconds: Double?
  public var segments: [TranscriptionSpan]?
  public var words: [TranscriptionSpan]?
  public var confidence: Double?
  public var usage: JSONValue?

  public init(
    text: String,
    provider: String,
    model: String,
    language: String? = nil,
    durationSeconds: Double? = nil,
    segments: [TranscriptionSpan]? = nil,
    words: [TranscriptionSpan]? = nil,
    confidence: Double? = nil,
    usage: JSONValue? = nil,
  ) {
    self.text = text
    self.provider = provider
    self.model = model
    self.language = language
    self.durationSeconds = durationSeconds
    self.segments = segments
    self.words = words
    self.confidence = confidence
    self.usage = usage
  }
}

public enum TranscriptionError: Error, Sendable, Equatable, CustomStringConvertible {
  case noTranscriber
  case unsupportedMediaType(String)
  case tooLarge(bytes: Int, limit: Int)
  case empty
  case upstream(status: Int, body: String?)
  case transport(String)
  case malformedResponse(String)

  // `description` reaches HTTP clients, so it never carries a provider's own
  // response text; `diagnostic` is the server-side-only form.
  public var description: String {
    switch self {
    case .noTranscriber:
      "no transcription provider is configured (add a ChatGPT login for codex or an api key for openai)"
    case let .unsupportedMediaType(value):
      "unsupported audio media type: \(value)"
    case let .tooLarge(bytes, limit):
      "audio is \(bytes) bytes; the limit is \(limit)"
    case .empty:
      "audio payload is empty"
    case let .upstream(status, _):
      "the transcription provider refused the audio (HTTP \(status))"
    case .transport:
      "cannot reach the transcription provider"
    case .malformedResponse:
      "the transcription provider answered in a shape wuhu could not read"
    }
  }

  public var diagnostic: String {
    switch self {
    case let .upstream(status, body):
      "upstream \(status)\(body.map { ": \($0)" } ?? "")"
    case let .transport(reason):
      "transport: \(reason)"
    case let .malformedResponse(reason):
      "malformed response: \(reason)"
    case .noTranscriber, .unsupportedMediaType, .tooLarge, .empty:
      description
    }
  }
}

public protocol Transcriber: Sendable {
  var providerID: String { get }
  var model: String { get }
  func transcribe(_ clip: AudioClip, language: String?) async throws(TranscriptionError) -> Transcription
}

public enum TranscriptionLimits {
  public static let maximumBytes: Int = 25 * 1024 * 1024
}
