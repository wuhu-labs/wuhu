import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import enum InferenceKit.TranscriptionLimits
import JSONValue
import SpaceContract
import SpaceFS
@testable import SpaceServer
import Testing

private let chatGPTLogin = CredentialResolver { provider in
  provider == "codex" ? .chatGPT(accessToken: "jwt", accountID: "acct-42") : nil
}

private let openAIKey = CredentialResolver { provider in
  provider == "openai" ? .apiKey("sk-test") : nil
}

private func providerReplying(_ payload: String, status: Status = .ok) -> (FetchClient, LockIsolated<[URL]>) {
  let seen = LockIsolated<[URL]>([])
  return (FetchClient { request in
    _ = try await request.body?.data()
    seen.withValue { $0.append(request.url) }
    return Response(status: status, headers: Headers(), body: .bytes(Data(payload.utf8), contentType: "application/json"))
  }, seen)
}

private func transcribeRequest(_ bytes: Data, contentType: String, query: String = "") -> Request {
  var request = Request(
    url: URL(string: "http://space/v1/transcribe\(query)")!,
    method: .post,
    body: .bytes(bytes, contentType: contentType),
  )
  request.headers["content-type"] = contentType
  return request
}

private let wavAudio = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!
private let configuredOpenAI = #"{"transcription":{"active":"openai","providers":{"openai":{"dialect":"openai-audio"}}}}"#

private func configure(_ harness: Harness, _ json: String = configuredOpenAI) async throws {
  _ = try await harness.space.fs(.shared).write("/capabilities.json", Data(json.utf8), ifMatch: nil)
}

@Suite struct TranscribeRouteTests {
  @Test func aChatGPTLoginTranscribesThroughTheDictationBackend() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let (provider, seen) = providerReplying(#"{"text":"hello wuhu","asset_format":"wav"}"#)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav", query: "?language=en"))
    }

    #expect(response.status == .ok)
    let output = try JSONValueDecoder().decode(TranscriptionOutput.self, from: try await json(response))
    #expect(output == TranscriptionOutput(
      text: "hello wuhu",
      provider: "codex",
      model: "chatgpt-transcribe",
      language: nil,
      durationSeconds: nil,
    ))
    #expect(seen.value.map(\.absoluteString) == ["https://chatgpt.com/backend-api/transcribe"])
  }

  @Test func anAPIKeyAloneTranscribesThroughTheOpenAIAudioAPI() async throws {
    let harness = try Harness(credentials: openAIKey)
    try await configure(harness)
    let (provider, seen) = providerReplying(#"{"text":"hi","languages":[{"code":"en"}],"usage":{"seconds":2}}"#)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    }

    #expect(response.status == .ok)
    let output = try JSONValueDecoder().decode(TranscriptionOutput.self, from: try await json(response))
    #expect(output.provider == "openai")
    #expect(output.model == "gpt-4o-mini-transcribe")
    #expect(output.durationSeconds == 2)
    #expect(seen.value.map(\.absoluteString) == ["https://api.openai.com/v1/audio/transcriptions"])
  }

  @Test func withoutACredentialTheRouteRefusesAndTheProbeSaysSo() async throws {
    let harness = try Harness()

    let refusal = try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    #expect(refusal.status == .serviceUnavailable)
    #expect(try await json(refusal).object?["code"] == .string("provider_not_configured"))

    let probe = try await harness.get(harness.api, "/v1/transcribe")
    let info = try JSONValueDecoder().decode(TranscriberInfo.self, from: try await json(probe))
    #expect(info == TranscriberInfo(available: false, provider: nil, model: nil))
  }

  @Test func withoutACredentialTheBodyIsNeverBuffered() async throws {
    let harness = try Harness()
    let drained = LockIsolated(false)
    var request = Request(
      url: URL(string: "http://space/v1/transcribe")!,
      method: .post,
      body: .stream(contentType: "audio/wav", replaying: {
        drained.setValue(true)
        return AsyncStream<Data> { $0.finish() }
      }),
    )
    request.headers["content-type"] = "audio/wav"

    let response = try await harness.api(request)
    #expect(response.status == Status.serviceUnavailable)
    #expect(drained.value == false)
  }

  @Test func anUpstreamRefusalNeverRelaysTheProviderBody() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let (provider, _) = providerReplying("upstream said something private", status: .forbidden)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    }
    let body = try await json(response)
    #expect(response.status == .forbidden)
    #expect(body.object?["message"] == .string("The capability provider refused the request (HTTP 403)."))
  }

  @Test func theProbeNamesTheProviderTheRouteWouldUse() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let probe = try await harness.get(harness.api, "/v1/transcribe")
    let info = try JSONValueDecoder().decode(TranscriberInfo.self, from: try await json(probe))
    #expect(info == TranscriberInfo(available: true, provider: "codex", model: "chatgpt-transcribe"))
  }

  @Test func aNonAudioBodyIsRefusedBeforeAnyProviderCall() async throws {
    let harness = try Harness(credentials: openAIKey)
    try await configure(harness)
    let response = try await harness.api(transcribeRequest(Data("{}".utf8), contentType: "application/json"))
    #expect(response.status == .unsupportedMediaType)
    #expect(try await json(response).object?["code"] == .string("invalid_argument"))
  }

  @Test func audioBeyondTheProviderBoundIsRefusedWith413() async throws {
    let harness = try Harness(credentials: openAIKey)
    try await configure(harness)
    let response = try await harness.api(transcribeRequest(
      Data(repeating: 0, count: TranscriptionLimits.maximumBytes + 1),
      contentType: "audio/m4a",
    ))
    #expect(response.status == .contentTooLarge)
    #expect(try await json(response).object?["code"] == .string("invalid_argument"))
  }

  @Test func anUpstreamRefusalSurfacesAsABadGateway() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let (provider, _) = providerReplying("blocked", status: .forbidden)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    }
    #expect(response.status == .forbidden)
    #expect(try await json(response).object?["code"] == .string("provider_entitlement"))
  }

  @Test func theWallGatesTheRouteOutsideDev() async throws {
    let harness = try Harness(dev: false, credentials: chatGPTLogin)
    let post = try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    #expect(post.status == .unauthorized)
    let probe = try await harness.get(harness.api, "/v1/transcribe")
    #expect(probe.status == .unauthorized)
  }
}

extension TranscribeRouteTests {
  @Test func explicitlyConfiguredOpenAIWinsOverAValidCodexLoginOnExistingEndpoint() async throws {
    let harness = try Harness(credentials: .init { provider in
      provider == "codex" ? .chatGPT(accessToken: "private-token", accountID: "private-account") : .apiKey("private-key")
    })
    try await configure(harness, #"{"transcription":{"active":"openai","providers":{"openai":{"dialect":"openai-audio","baseURL":"https://fake.openai/v1","model":"whisper-1"},"codex":{"dialect":"codex"}}}}"#)
    let (provider, seen) = providerReplying(#"{"text":"hello","language":"en","duration":1.5,"segments":[{"text":"hello","start":0,"end":1.5}],"words":[{"word":"hello","start":0.1,"end":1.4}]}"#)
    let response = try await withDependencies { $0.fetch = provider } operation: {
      try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav", query: "?timestamps=words,segments"))
    }
    #expect(response.status == .ok)
    #expect(seen.value.map(\.absoluteString) == ["https://fake.openai/v1/audio/transcriptions"])
    let output = try await json(response)
    #expect(output.object?["provider"] == .string("openai"))
    #expect(output.object?["durationSeconds"] == .number(1.5))
    #expect(output.object?["words"]?.array?.count == 1)
    #expect(output.object?["confidence"] == nil)
    let probe = try await harness.get(harness.api, "/v1/transcribe")
    #expect(try await json(probe).object?["provider"] == .string("openai"))
  }

  @Test func brokenActiveWithACodexLoginRefusesWithoutBufferingOrFallback() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    try await configure(harness, #"{"transcription":{"active":"missing","providers":{"codex":{"dialect":"codex"}}}}"#)
    let drained = LockIsolated(false)
    var request = Request(url: URL(string: "http://space/v1/transcribe")!, method: .post, body: .stream(contentType: "audio/wav", replaying: { drained.setValue(true); return AsyncStream<Data> { $0.finish() } }))
    request.headers["content-type"] = "audio/wav"
    let response = try await harness.api(request)
    #expect(response.status == .serviceUnavailable)
    #expect(try await json(response).object?["code"] == .string("provider_not_configured"))
    #expect(!drained.value)
  }

  @Test func malformedConfigFailsInsteadOfSynthesizingCodex() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    try await configure(harness, "{malformed")
    let response = try await harness.api(transcribeRequest(wavAudio, contentType: "audio/wav"))
    #expect(response.status == .serviceUnavailable)
    #expect(try await json(response).object?["code"] == .string("provider_not_configured"))
  }
}
