import Clocks
import Credentials
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import JSONValue
import Testing

private let bothCredentials = CredentialResolver { id in
  id == "codex" ? .chatGPT(accessToken: "private-token", accountID: "private-account") : .apiKey("private-key")
}

private func client(_ capability: String, active: String = "test", dialect: String, model: String? = nil, credentials: CredentialResolver = bothCredentials) throws -> CapabilityClient {
  let modelField = model.map { ",\"model\":\"\($0)\"" } ?? ""
  let config = "{\"\(capability)\":{\"active\":\"\(active)\",\"providers\":{\"test\":{\"dialect\":\"\(dialect)\",\"baseURL\":\"https://fake.provider/v1\"\(modelField)},\"codex\":{\"dialect\":\"codex\"}}}}"
  return try .init(document: CapabilitiesDocument(json: Data(config.utf8)), credentials: credentials)
}

private struct CapabilityRequest: Sendable {
  var url: String
  var method: String
  var headers: RequestHeaders
  var body: String
}

private final class CapabilityRecorder: Sendable {
  let requests = LockIsolated<[CapabilityRequest]>([])
  let replies: [String]
  let statuses: [Status]

  init(_ replies: [String], statuses: [Status] = []) {
    self.replies = replies
    self.statuses = statuses
  }

  var fetch: FetchClient {
    FetchClient { request in
      let body = String(decoding: try await request.body?.data() ?? Data(), as: UTF8.self)
      let index = self.requests.withValue {
        let count = $0.count
        $0.append(.init(url: request.url.absoluteString, method: request.method.rawValue, headers: request.headers, body: body))
        return count
      }
      let reply = self.replies[min(index, self.replies.count - 1)]
      return Response(status: self.statuses.indices.contains(index) ? self.statuses[index] : .ok, body: .string(reply))
    }
  }
}

private let imageReply = #"{"data":[{"b64_json":"UE5H"}]}"#
private let audio = AudioClip(bytes: Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!, mediaType: .wav)

@Suite struct CapabilityTests {
  @Test func noConfigSynthesizesCodexWithoutAModelSheet() async throws {
    let recorder = CapabilityRecorder([imageReply])
    let provider = CapabilityClient(document: nil, credentials: bothCredentials)
    let image = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("moon") }
    #expect(image == Data("PNG".utf8))
    #expect(recorder.requests.value.first?.url == "https://chatgpt.com/backend-api/codex/images/generations")
    #expect(recorder.requests.value.first?.headers.sensitiveValues["chatgpt-account-id"] == "private-account")
  }

  @Test func missingCapabilityEntryAlsoSynthesizesCodex() async throws {
    let document = try CapabilitiesDocument(json: Data(#"{"web_search":{"active":"brave","providers":{"brave":{"dialect":"brave"}}}}"#.utf8))
    let recorder = CapabilityRecorder([#"{"text":"bare"}"#])
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: {
      try await CapabilityClient(document: document, credentials: bothCredentials).transcribe(audio)
    }
    #expect(result.provider == "codex")
    #expect(result.language == nil && result.durationSeconds == nil && result.words == nil)
    #expect(recorder.requests.value.first?.url == "https://chatgpt.com/backend-api/transcribe")
  }

  @Test func activeProviderWinsEvenWithACodexLogin() async throws {
    let provider = try client("transcription", dialect: "openai-audio", model: "whisper-1")
    let recorder = CapabilityRecorder([#"{"text":"hello","duration":1.5,"language":"en","words":[{"word":"hello","start":0.25,"end":1.2}],"segments":[{"text":"hello","start":0,"end":1.5}]}"#])
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: {
      try await provider.transcribe(audio, options: .init(timestamps: ["words", "segments"]))
    }
    #expect(result.provider == "test" && result.model == "whisper-1")
    #expect(result.words?.first?.start == 0.25 && result.durationSeconds == 1.5)
    let request = try #require(recorder.requests.value.first)
    #expect(request.url == "https://fake.provider/v1/audio/transcriptions")
    #expect(request.body.contains("verbose_json") && request.body.contains("timestamp_granularities[]"))
    #expect(request.headers.sensitiveValues["authorization"] == "Bearer private-key")
    #expect(request.headers.sensitiveValues["chatgpt-account-id"] == nil)
  }

  @Test func explicitBrokenActiveNeverFallsBack() async throws {
    let recorder = CapabilityRecorder([imageReply])
    for provider in [
      try client("image", active: "missing", dialect: "openai-images"),
      try client("image", dialect: "unknown"),
      try client("image", dialect: "openai-images", credentials: .init { id in id == "codex" ? .chatGPT(accessToken: "token", accountID: "account") : nil }),
    ] {
      do {
        _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("moon") }
        Issue.record("Broken explicit configuration succeeded")
      } catch let error as CapabilityError { #expect(error.code == .providerNotConfigured) }
    }
    #expect(recorder.requests.value.isEmpty)
  }

  @Test func explicitOverrideIsAuthoritativeAndUnknownOverrideFails() async throws {
    let recorder = CapabilityRecorder([imageReply])
    let provider = try client("image", dialect: "openai-images")
    _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("moon", options: .init(provider: "codex")) }
    #expect(recorder.requests.value.first?.url == "https://chatgpt.com/backend-api/codex/images/generations")
    await #expect(throws: CapabilityError.self) { _ = try await provider.image("moon", options: .init(provider: "absent")) }
  }

  @Test func malformedConfigDoesNotBecomeUnconfigured() throws {
    #expect(throws: CapabilityError.self) { try CapabilitiesDocument(json: Data(#"{"image":{"active":"test","providers":{}}"#.utf8)) }
  }

  @Test func requestedHardFeaturesFailBeforeUpload() async throws {
    let recorder = CapabilityRecorder([#"{"text":"should not happen"}"#])
    let provider = try client("transcription", dialect: "openai-audio", model: "gpt-4o-mini-transcribe")
    do {
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.transcribe(audio, options: .init(timestamps: ["words"])) }
      Issue.record("Unsupported word timestamps succeeded")
    } catch let error as CapabilityError { #expect(error.code == .unsupportedFeature) }
    let oldQwen = try client("transcription", dialect: "dashscope", model: "qwen3-asr-flash-filetrans")
    do { _ = try await oldQwen.transcribe(audio, options: .init(diarize: true)); Issue.record("Old Qwen diarization succeeded") }
    catch let error as CapabilityError { #expect(error.code == .unsupportedFeature) }
    #expect(recorder.requests.value.isEmpty)
  }

  @Test(arguments: [(401, CapabilityError.Code.providerAuth), (403, .providerEntitlement), (429, .providerRateLimited), (500, .providerUnavailable)])
  func providerErrorsAreTypedAndNeverExposeBodies(status: Int, code: CapabilityError.Code) async throws {
    let recorder = CapabilityRecorder([#"{"error":{"message":"private-key private-token private-account"}}"#], statuses: [Status(code: status)])
    let provider = try client("image", dialect: "openai-images")
    do {
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("moon") }
      Issue.record("Provider error succeeded")
    } catch let error as CapabilityError {
      #expect(error.code == code)
      #expect(!error.description.contains("private-"))
    }
    #expect(recorder.requests.value.count == 1)
  }

  @Test func regionErrorIsDistinct() async throws {
    let recorder = CapabilityRecorder([#"{"error":{"code":"unsupported_country_region_territory"}}"#], statuses: [.forbidden])
    do {
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await client("image", dialect: "openai-images").image("moon") }
      Issue.record("Region error succeeded")
    } catch let error as CapabilityError { #expect(error.code == .providerRegion) }
  }

  @Test func openAIAndCodexEditsUseTheirOwnWireDialects() async throws {
    for dialect in ["openai-images", "codex"] {
      let provider = try client("image", dialect: dialect, credentials: .init { _ in dialect == "codex" ? .chatGPT(accessToken: "token", accountID: "account") : .apiKey("key") })
      let recorder = CapabilityRecorder([imageReply])
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("blue moon", images: [Data("png".utf8)], options: .init(size: "1536x1024")) }
      let request = try #require(recorder.requests.value.first)
      #expect(request.url == "https://fake.provider/v1/images/edits")
      if dialect == "codex" { #expect(JSONValue.parse(request.body)?["images"].list.first?["image_url"].text?.hasPrefix("data:image/png;base64,") == true) }
      else { #expect(request.body.contains("name=\"image[]\"") && request.body.contains("blue moon")) }
    }
  }

  @Test(arguments: ["draft", "standard", "fine", "ultra"])
  func qwenQualityMapsToExactModels(quality: String) async throws {
    let provider = try client("image", dialect: "dashscope")
    let recorder = CapabilityRecorder([#"{"output":{"choices":[{"message":{"content":[{"image":"https://storage/image?signature=fixture"}]}}]}}"#, "PNG"])
    _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.image("moon", options: .init(quality: quality, size: "1536x1024")) }
    let requests = recorder.requests.value
    let body = try #require(JSONValue.parse(requests[0].body))
    let expected = ["draft": "z-image-turbo", "standard": "qwen-image-3.0", "fine": "qwen-image-3.0-pro", "ultra": "wan2.7-image-pro"]
    #expect(body["model"].text == expected[quality])
    #expect(body["parameters"]["size"].text == "1536*1024")
    #expect(requests[1].headers.sensitiveValues.isEmpty)
    #expect(requests[1].url == "https://storage/image?signature=fixture")
  }

  @Test func qwenDraftEditErrorsInsteadOfSwitchingTier() async throws {
    do { _ = try await client("image", dialect: "dashscope").image("blue", images: [Data([1])], options: .init(quality: "draft")); Issue.record("Draft edit succeeded") }
    catch let error as CapabilityError { #expect(error.code == .unsupportedFeature) }
  }

  @Test func qwenEditUsesNativeImageContent() async throws {
    let recorder = CapabilityRecorder([#"{"output":{"choices":[{"message":{"content":[{"image":"https://storage/image"}]}}]}}"#, "PNG"])
    _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await client("image", dialect: "dashscope").image("blue moon", images: [Data([1, 2])]) }
    let first = recorder.requests.value[0]
    #expect(first.url == "https://fake.provider/v1/services/aigc/multimodal-generation/generation")
    #expect(JSONValue.parse(first.body)?["input"]["messages"].list.first?["content"].list.first?["image"].text == "data:image/png;base64,AQI=")
    #expect(!first.body.contains("bbox") && !first.body.contains("mask"))
  }

  @Test func braveAndExaSearchNormalizeUsefulSources() async throws {
    for dialect in ["brave", "exa"] {
      let reply = dialect == "brave" ? #"{"web":{"results":[{"title":"Fixture title","url":"https://example.test/page","description":"Synthetic snippet","page_age":"2026-10-02T14:22:41","age":"2 days ago","publishedDate":"wrong-dialect"}]}}"# : #"{"results":[{"title":"Fixture title","url":"https://example.test/page","highlights":["Synthetic snippet"],"publishedDate":"2026-10-02T14:22:41"}]}"#
      let recorder = CapabilityRecorder([reply])
      let result = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await client("web_search", dialect: dialect).search("space & moon", options: .init(count: 3)) }
      #expect(result.sources.first?.snippet == "Synthetic snippet")
      #expect(result.sources.first?.title == "Fixture title")
      #expect(result.sources.first?.published == "2026-10-02T14:22:41")
      let request = recorder.requests.value[0]
      if dialect == "brave" { #expect(request.url.contains("web/search?q=space%20%26%20moon&count=3")); #expect(request.headers.sensitiveValues["x-subscription-token"] == "private-key") }
      else { #expect(request.url == "https://fake.provider/v1/search"); #expect(request.headers.sensitiveValues["x-api-key"] == "private-key"); #expect(JSONValue.parse(request.body)?["numResults"].numeric == 3) }
    }
  }

  @Test func codexHostedSearchReturnsExplicitSourcesAndSnippets() async throws {
    let recorder = CapabilityRecorder([#"data: {"type":"response.completed","response":{"output":[{"type":"web_search_call","action":{"sources":[{"url":"https://example.test/page","title":"Source"}]}},{"type":"message","content":[{"type":"output_text","text":"Synthetic snippet","annotations":[{"type":"url_citation","url":"https://example.test/page","title":"Source"}]}]}]}}"#])
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await CapabilityClient(document: nil, credentials: bothCredentials).search("moon") }
    #expect(result.sources.count == 1 && result.text == "Synthetic snippet")
    #expect(recorder.requests.value[0].body.contains("web_search_call.action.sources"))
    #expect(recorder.requests.value[0].body.contains("\"store\":false"))
  }

  @Test func codexRetainsDoneItemsWhenCompletionOmitsOutput() async throws {
    let recorder = CapabilityRecorder([#"""
    data: {"type":"response.output_item.done","item":{"type":"web_search_call","action":{"sources":[{"url":"https://example.test/page","title":"Source"}]}}}
    data: {"type":"response.output_item.done","item":{"type":"message","content":[{"type":"output_text","text":"Actual searched snippet","annotations":[{"type":"url_citation","url":"https://example.test/page","title":"Source"}]}]}}
    data: {"type":"response.completed","response":{"status":"completed","output":[]}}
    """#])
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await CapabilityClient(document: nil, credentials: bothCredentials).search("moon") }
    #expect(result.sources.count == 1 && result.sources.first?.title == "Source")
    #expect(result.text == "Actual searched snippet")
  }

  @Test func diarizationModelProvidesSegmentsWithoutGranularityFields() async throws {
    let recorder = CapabilityRecorder([#"{"text":"hello","segments":[{"text":"hello","start":0,"end":1,"speaker":"A"}]}"#])
    let provider = try client("transcription", dialect: "openai-audio", model: "gpt-4o-transcribe-diarize")
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.transcribe(audio, options: .init(timestamps: ["segments"], diarize: true)) }
    #expect(result.segments?.first?.speaker == "A" && result.segments?.first?.end == 1)
    let body = try #require(recorder.requests.value.first?.body)
    #expect(body.contains("diarized_json") && body.contains("chunking_strategy") && body.contains("auto"))
    #expect(!body.contains("timestamp_granularities"))
    do {
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await provider.transcribe(audio, options: .init(timestamps: ["words"], diarize: true)) }
      Issue.record("Diarization model accepted word timestamps")
    } catch let error as CapabilityError { #expect(error.code == .unsupportedFeature) }
    #expect(recorder.requests.value.count == 1)
  }

  @Test func diarizationModelChunksLongPlainTranscriptionWithoutSpeakerRequest() async throws {
    func little(_ value: UInt32) -> Data { Data((0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    var bytes = Data(audio.bytes.prefix(40)) + little(640_000) + Data(repeating: 0, count: 640_000)
    bytes.replaceSubrange(4 ..< 8, with: little(UInt32(bytes.count - 8)))
    let clip = AudioClip(bytes: bytes, mediaType: .wav)
    #expect(AudioDuration.seconds(clip) == 40)
    let recorder = CapabilityRecorder([#"{"text":"long plain transcript"}"#])
    let result = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await client("transcription", dialect: "openai-audio", model: "gpt-4o-transcribe-diarize").transcribe(clip) }
    #expect(result.text == "long plain transcript")
    #expect(recorder.requests.value.first?.body.contains("chunking_strategy") == true)
    #expect(recorder.requests.value.first?.body.contains("auto") == true)
  }

  @Test(arguments: [false, true])
  func qwenManagedUploadIsDeletedAndStorageGetsNoBearer(cleanupFails: Bool) async throws {
    let replies = [
      #"{"data":{"uploaded_files":[{"file_id":"owned-fixture"}]}}"#,
      #"{"data":{"url":"http://storage/input?signature=fixture%2Bkeep"}}"#,
      #"{"output":{"task_id":"task-fixture","task_status":"PENDING"}}"#,
      #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://storage/transcript?signature=fixture"}]}}"#,
      #"{"properties":{"original_duration_in_milliseconds":1500},"transcripts":[{"text":"hello","sentences":[{"text":"hello","begin_time":100,"end_time":1500,"speaker_id":2,"words":[{"text":"hello","begin_time":100,"end_time":900,"confidence":0.8}]}]}]}"#,
      "{}",
    ]
    let recorder = CapabilityRecorder(replies, statuses: [.ok, .ok, .ok, .ok, .ok, cleanupFails ? .internalServerError : .ok])
    let result = try await withDependencies { $0.fetch = recorder.fetch; $0.continuousClock = ImmediateClock() } operation: {
      try await client("transcription", dialect: "dashscope").transcribe(audio, options: .init(timestamps: ["words", "segments"], diarize: true))
    }
    #expect(result.durationSeconds == 1.5 && result.segments?.first?.start == 0.1)
    #expect(result.words?.first?.speaker == "2" && result.words?.first?.confidence == 0.8)
    let requests = recorder.requests.value
    #expect(requests.count == 6)
    #expect(requests[2].url.hasSuffix("/services/audio/asr/transcription"))
    #expect(JSONValue.parse(requests[2].body)?["input"]["file_urls"].list.first?.text == "http://storage/input?signature=fixture%2Bkeep")
    #expect(requests[2].headers["x-dashscope-async"] == "enable")
    #expect(requests[4].headers.sensitiveValues.isEmpty)
    #expect(requests[5].method == "DELETE" && requests[5].url.hasSuffix("/files/owned-fixture"))
  }

  @Test func qwenDeletesOwnedUploadWhenTaskFails() async throws {
    let recorder = CapabilityRecorder([
      #"{"data":{"uploaded_files":[{"file_id":"owned-fixture"}]}}"#,
      #"{"data":{"url":"http://storage/input"}}"#,
      #"{"output":{"task_id":"task-fixture","task_status":"FAILED","code":"private-key"}}"#,
      "{}",
    ])
    await #expect(throws: CapabilityError.self) {
      _ = try await withDependencies { $0.fetch = recorder.fetch } operation: { try await client("transcription", dialect: "dashscope").transcribe(audio) }
    }
    #expect(recorder.requests.value.last?.method == "DELETE")
    #expect(recorder.requests.value.count == 4)
  }

  @Test func byteAndDurationBoundsRefuseBeforeProviderIO() async throws {
    let provider = CapabilityClient(document: nil, credentials: bothCredentials)
    await #expect(throws: CapabilityError.self) { _ = try await provider.transcribe(.init(bytes: Data(repeating: 0, count: 25 * 1024 * 1024 + 1), mediaType: .wav)) }
    var wav = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVEfmt ".utf8)
    func little(_ value: UInt32) -> Data { Data((0 ..< 4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    wav += little(16) + Data([1, 0, 1, 0]) + little(1) + little(2) + Data([2, 0, 16, 0]) + Data("data".utf8) + little(14402)
    #expect(AudioDuration.seconds(.init(bytes: wav, mediaType: .wav)) == 7201)
    await #expect(throws: CapabilityError.self) { _ = try await provider.transcribe(.init(bytes: wav, mediaType: .wav)) }
  }
}
