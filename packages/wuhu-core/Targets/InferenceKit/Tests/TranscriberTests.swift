import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import Testing

private struct EmittedRequest: Sendable {
  var url: String
  var method: String
  var headers: [String: String]
  var sensitiveHeaderNames: [String]
  var parts: [String: String]
  var fileName: String?
  var fileContentType: String?
  var fileBytes: Data?
}

private final class Recorder: Sendable {
  let held = LockIsolated<[EmittedRequest]>([])

  func client(status: Status = .ok, payload: String) -> FetchClient {
    FetchClient { request in
      let body = try await request.body?.data() ?? Data()
      self.held.withValue { $0.append(parseEmitted(request, body: body)) }
      return Response(status: status, headers: Headers(), body: .bytes(Data(payload.utf8), contentType: "application/json"))
    }
  }
}

private func parseEmitted(_ request: Request, body: Data) -> EmittedRequest {
  var emitted = EmittedRequest(
    url: request.url.absoluteString,
    method: request.method.rawValue,
    headers: request.headers.values,
    sensitiveHeaderNames: request.headers.sensitiveValues.keys.sorted(),
    parts: [:],
    fileName: nil,
    fileContentType: nil,
    fileBytes: nil,
  )
  guard let contentType = request.headers["content-type"],
        let marker = contentType.range(of: "boundary=")
  else { return emitted }
  let boundary = String(contentType[marker.upperBound...])
  let separator = Data("--\(boundary)".utf8)
  for chunk in body.split(separator: separator) {
    guard let split = chunk.range(of: Data("\r\n\r\n".utf8)) else { continue }
    let head = String(decoding: chunk[chunk.startIndex ..< split.lowerBound], as: UTF8.self)
    var value = chunk[split.upperBound...]
    while value.last == 0x0A || value.last == 0x0D { value = value.dropLast() }
    guard let name = quoted(after: "name=", in: head) else { continue }
    if let filename = quoted(after: "filename=", in: head) {
      emitted.fileName = filename
      emitted.fileBytes = Data(value)
      emitted.fileContentType = head
        .split(separator: "\r\n")
        .first { $0.hasPrefix("Content-Type: ") }
        .map { String($0.dropFirst("Content-Type: ".count)) }
    } else {
      emitted.parts[name] = String(decoding: value, as: UTF8.self)
    }
  }
  return emitted
}

private func quoted(after key: String, in text: String) -> String? {
  guard let start = text.range(of: key + "\"") else { return nil }
  guard let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
  return String(text[start.upperBound ..< end])
}

extension Data {
  fileprivate func split(separator: Data) -> [Data] {
    var pieces: [Data] = []
    var cursor = startIndex
    while let found = self[cursor...].range(of: separator) {
      if found.lowerBound > cursor { pieces.append(self[cursor ..< found.lowerBound]) }
      cursor = found.upperBound
    }
    if cursor < endIndex { pieces.append(self[cursor...]) }
    return pieces
  }
}

private let clip = AudioClip(bytes: Data("RIFFfake-wav-bytes".utf8), mediaType: .wav)

@Suite struct TranscriberTests {
  @Test func codexEmitsTheDictationMultipartAndReadsTheTranscript() async throws {
    let recorder = Recorder()
    let transcription = try await withDependencies {
      $0.uuid = .incrementing
      $0.fetch = recorder.client(payload: """
      {"text":"hello wuhu","asset_pointer":"sediment://file_1","asset_ttl":"30d","asset_format":"wav"}
      """)
    } operation: {
      try await CodexTranscriber(accessToken: "jwt", accountID: "acct-42")
        .transcribe(clip, language: "en")
    }

    let emitted = try #require(recorder.held.value.first)
    #expect(emitted.url == "https://chatgpt.com/backend-api/transcribe")
    #expect(emitted.method == "POST")
    #expect(emitted.sensitiveHeaderNames == ["authorization", "chatgpt-account-id"])
    #expect(emitted.headers["originator"] == "wuhu")
    #expect(emitted.headers["user-agent"] == TranscriberTransport.userAgent)
    #expect(emitted.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=----wuhu") == true)
    #expect(emitted.fileName == "audio.wav")
    #expect(emitted.fileContentType == "audio/wav")
    #expect(emitted.fileBytes == clip.bytes)
    #expect(emitted.parts == ["language": "en"])

    #expect(transcription == Transcription(
      text: "hello wuhu",
      provider: "codex",
      model: "chatgpt-transcribe",
      language: "en",
    ))
  }

  @Test func openAIEmitsTheModelAndReadsLanguageAndDuration() async throws {
    let recorder = Recorder()
    let transcription = try await withDependencies {
      $0.uuid = .incrementing
      $0.fetch = recorder.client(payload: """
      {"text":"hello wuhu","languages":[{"code":"en"}],"usage":{"type":"duration","seconds":3}}
      """)
    } operation: {
      try await OpenAITranscriber(apiKey: "sk-test").transcribe(clip, language: nil)
    }

    let emitted = try #require(recorder.held.value.first)
    #expect(emitted.url == "https://api.openai.com/v1/audio/transcriptions")
    #expect(emitted.sensitiveHeaderNames == ["authorization"])
    #expect(emitted.parts == ["model": "gpt-4o-mini-transcribe", "response_format": "json"])
    #expect(emitted.fileName == "audio.wav")

    #expect(transcription == Transcription(
      text: "hello wuhu",
      provider: "openai",
      model: "gpt-4o-mini-transcribe",
      language: "en",
      durationSeconds: 3,
    ))
  }

  @Test func upstreamFailuresCarryTheStatusAndBody() async throws {
    let recorder = Recorder()
    await withDependencies {
      $0.uuid = .incrementing
      $0.fetch = recorder.client(status: .forbidden, payload: "blocked")
    } operation: {
      await #expect(throws: TranscriptionError.upstream(status: 403, body: "blocked")) {
        try await CodexTranscriber(accessToken: "jwt", accountID: "acct").transcribe(clip, language: nil)
      }
    }
  }

  @Test func oversizedAndEmptyAudioNeverReachTheProvider() async throws {
    let recorder = Recorder()
    await withDependencies {
      $0.uuid = .incrementing
      $0.fetch = recorder.client(payload: "{}")
    } operation: {
      let huge = AudioClip(
        bytes: Data(repeating: 0, count: TranscriptionLimits.maximumBytes + 1),
        mediaType: .m4a,
      )
      await #expect(throws: TranscriptionError.tooLarge(
        bytes: TranscriptionLimits.maximumBytes + 1,
        limit: TranscriptionLimits.maximumBytes,
      )) {
        try await OpenAITranscriber(apiKey: "sk").transcribe(huge, language: nil)
      }
      await #expect(throws: TranscriptionError.empty) {
        try await OpenAITranscriber(apiKey: "sk").transcribe(
          AudioClip(bytes: Data(), mediaType: .m4a),
          language: nil,
        )
      }
    }
    #expect(recorder.held.value.isEmpty)
  }

  @Test func mediaTypesAcceptTheAliasesRecordersEmit() {
    #expect(AudioMediaType(header: "audio/x-m4a") == .m4a)
    #expect(AudioMediaType(header: "audio/mp4") == .mp4)
    #expect(AudioMediaType(header: "audio/wav; codecs=1") == .wav)
    #expect(AudioMediaType(header: "AUDIO/MP3") == .mpeg)
    #expect(AudioMediaType(header: "audio/webm") == .webm)
    #expect(AudioMediaType(header: "video/mp4") == nil)
    #expect(AudioMediaType.m4a.fileExtension == "m4a")
  }
}
