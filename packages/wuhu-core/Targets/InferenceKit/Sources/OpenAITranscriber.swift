#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

public struct OpenAITranscriber: Transcriber {
  public static let defaultModel: String = "gpt-transcribe"
  public static let defaultBaseURL: URL = URL(string: "https://api.openai.com/v1")!

  public let providerID: String = "openai"
  public let model: String

  var baseURL: URL
  var apiKey: String

  public init(
    baseURL: URL = OpenAITranscriber.defaultBaseURL,
    apiKey: String,
    model: String = OpenAITranscriber.defaultModel,
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
  }

  struct Payload: Decodable {
    struct Language: Decodable {
      var code: String
    }

    struct Usage: Decodable {
      var seconds: Double?
    }

    var text: String
    var languages: [Language]?
    var usage: Usage?
  }

  public func transcribe(_ clip: AudioClip, language: String?) async throws(TranscriptionError) -> Transcription {
    try TranscriberTransport.validate(clip)

    var form = MultipartForm(boundary: TranscriberTransport.boundary())
    form.appendFile(
      name: "file",
      filename: "audio.\(clip.mediaType.fileExtension)",
      contentType: clip.mediaType.rawValue,
      bytes: clip.bytes,
    )
    form.appendField("model", model)
    form.appendField("response_format", "json")
    if let language {
      form.appendField("language", language)
    }
    let body = form.finish()

    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(apiKey)")
    headers.set("user-agent", TranscriberTransport.userAgent)
    headers.set("content-type", body.contentType)

    let payload = try await TranscriberTransport.send(
      Request(
        url: baseURL.appendingPathComponent("audio").appendingPathComponent("transcriptions"),
        method: .post,
        headers: headers,
        body: body,
      ),
      decoding: Payload.self,
    )
    return Transcription(
      text: payload.text,
      provider: providerID,
      model: model,
      language: language ?? payload.languages?.first?.code,
      durationSeconds: payload.usage?.seconds,
    )
  }
}
