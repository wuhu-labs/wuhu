#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

public struct CodexTranscriber: Transcriber {
  public static let defaultBaseURL: URL = URL(string: "https://chatgpt.com/backend-api")!

  public let providerID: String = "codex"
  public let model: String = "chatgpt-transcribe"

  var baseURL: URL
  var accessToken: String
  var accountID: String
  var originator: String

  public init(
    baseURL: URL = CodexTranscriber.defaultBaseURL,
    accessToken: String,
    accountID: String,
    originator: String = "wuhu",
  ) {
    self.baseURL = baseURL
    self.accessToken = accessToken
    self.accountID = accountID
    self.originator = originator
  }

  struct Payload: Decodable {
    var text: String
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
    if let language {
      form.appendField("language", language)
    }
    let body = form.finish()

    var headers = RequestHeaders()
    headers.setSensitive("authorization", "Bearer \(accessToken)")
    headers.setSensitive("chatgpt-account-id", accountID)
    headers.set("originator", originator)
    // Cloudflare rejects this route with 403 when User-Agent is absent.
    headers.set("user-agent", TranscriberTransport.userAgent)
    headers.set("content-type", body.contentType)

    let payload = try await TranscriberTransport.send(
      Request(url: baseURL.appendingPathComponent("transcribe"), method: .post, headers: headers, body: body),
      decoding: Payload.self,
    )
    return Transcription(text: payload.text, provider: providerID, model: model, language: language)
  }
}
