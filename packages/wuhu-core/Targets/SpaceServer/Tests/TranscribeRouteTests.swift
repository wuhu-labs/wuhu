import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import enum InferenceKit.TranscriptionLimits
import JSONValue
import SpaceContract
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

@Suite struct TranscribeRouteTests {
  @Test func aChatGPTLoginTranscribesThroughTheDictationBackend() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let (provider, seen) = providerReplying(#"{"text":"hello wuhu","asset_format":"wav"}"#)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(Data("RIFFwav".utf8), contentType: "audio/wav", query: "?language=en"))
    }

    #expect(response.status == .ok)
    let output = try JSONValueDecoder().decode(TranscriptionOutput.self, from: try await json(response))
    #expect(output == TranscriptionOutput(
      text: "hello wuhu",
      provider: "codex",
      model: "chatgpt-transcribe",
      language: "en",
      durationSeconds: nil,
    ))
    #expect(seen.value.map(\.absoluteString) == ["https://chatgpt.com/backend-api/transcribe"])
  }

  @Test func anAPIKeyAloneTranscribesThroughTheOpenAIAudioAPI() async throws {
    let harness = try Harness(credentials: openAIKey)
    let (provider, seen) = providerReplying(#"{"text":"hi","languages":[{"code":"en"}],"usage":{"seconds":2}}"#)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(Data("m4a".utf8), contentType: "audio/m4a"))
    }

    #expect(response.status == .ok)
    let output = try JSONValueDecoder().decode(TranscriptionOutput.self, from: try await json(response))
    #expect(output.provider == "openai")
    #expect(output.model == "gpt-transcribe")
    #expect(output.durationSeconds == 2)
    #expect(seen.value.map(\.absoluteString) == ["https://api.openai.com/v1/audio/transcriptions"])
  }

  @Test func withoutACredentialTheRouteRefusesAndTheProbeSaysSo() async throws {
    let harness = try Harness()

    let refusal = try await harness.api(transcribeRequest(Data("wav".utf8), contentType: "audio/wav"))
    #expect(refusal.status == .serviceUnavailable)
    #expect(try await json(refusal).object?["code"] == .string("noTranscriber"))

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
      try await harness.api(transcribeRequest(Data("wav".utf8), contentType: "audio/wav"))
    }
    let body = try await json(response)
    #expect(response.status == .badGateway)
    #expect(body.object?["message"] == .string("codex: the transcription provider refused the audio (HTTP 403)"))
  }

  @Test func theProbeNamesTheProviderTheRouteWouldUse() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let probe = try await harness.get(harness.api, "/v1/transcribe")
    let info = try JSONValueDecoder().decode(TranscriberInfo.self, from: try await json(probe))
    #expect(info == TranscriberInfo(available: true, provider: "codex", model: "chatgpt-transcribe"))
  }

  @Test func aNonAudioBodyIsRefusedBeforeAnyProviderCall() async throws {
    let harness = try Harness(credentials: openAIKey)
    let response = try await harness.api(transcribeRequest(Data("{}".utf8), contentType: "application/json"))
    #expect(response.status == .unsupportedMediaType)
    #expect(try await json(response).object?["code"] == .string("unsupported"))
  }

  @Test func audioBeyondTheProviderBoundIsRefusedWith413() async throws {
    let harness = try Harness(credentials: openAIKey)
    let response = try await harness.api(transcribeRequest(
      Data(repeating: 0, count: TranscriptionLimits.maximumBytes + 1),
      contentType: "audio/m4a",
    ))
    #expect(response.status == .contentTooLarge)
    #expect(try await json(response).object?["code"] == .string("invalidArgument"))
  }

  @Test func anUpstreamRefusalSurfacesAsABadGateway() async throws {
    let harness = try Harness(credentials: chatGPTLogin)
    let (provider, _) = providerReplying("blocked", status: .forbidden)

    let response = try await withDependencies {
      $0.fetch = provider
    } operation: {
      try await harness.api(transcribeRequest(Data("wav".utf8), contentType: "audio/wav"))
    }
    #expect(response.status == .badGateway)
    #expect(try await json(response).object?["code"] == .string("unavailable"))
  }

  @Test func theWallGatesTheRouteOutsideDev() async throws {
    let harness = try Harness(dev: false, credentials: chatGPTLogin)
    let post = try await harness.api(transcribeRequest(Data("wav".utf8), contentType: "audio/wav"))
    #expect(post.status == .unauthorized)
    let probe = try await harness.get(harness.api, "/v1/transcribe")
    #expect(probe.status == .unauthorized)
  }
}
