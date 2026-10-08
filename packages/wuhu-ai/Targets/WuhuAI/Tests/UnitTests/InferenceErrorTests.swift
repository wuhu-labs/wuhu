import Dependencies
import Fetch
import Foundation
import HTTPTypes
import Testing
@testable import WuhuAI

// MARK: - Helpers

private func stubFetch(_ response: Response) -> FetchClient {
  FetchClient { _ in response }
}

private func throwingFetch(_ error: any Error) -> FetchClient {
  FetchClient { _ in throw error }
}

private func anthropicEndpoint() -> AnthropicEndpoint {
  AnthropicEndpoint(model: "claude-test", apiKey: "test-key")
}

private func openAIEndpoint() -> OpenAIGPTEndpoint {
  OpenAIGPTEndpoint(model: "gpt-test", apiKey: "test-key")
}

private func captureInferenceError<E: ModelEndpoint>(
  fetch: FetchClient,
  endpoint: E = anthropicEndpoint(),
) async -> InferenceError? {
  let bound = endpoint.withFetch(fetch)
  do {
    _ = try await bound.inference(context: Context(messages: [])).collect()
    return nil
  } catch {
    return error
  }
}

// MARK: - Non-2xx Classification

@Suite("InferenceError classification")
struct InferenceErrorTests {
  @Test("429 with Retry-After delta-seconds maps to .rateLimited carrying retryAt")
  func rateLimitedDeltaSeconds() async throws {
    var headers = Headers()
    headers[.retryAfter] = "30"
    let now = Date(timeIntervalSince1970: 1_792_567_680)
    let response = Response(
      status: .init(code: 429),
      headers: headers,
      body: .string(#"{"error":{"type":"rate_limit_error","message":"slow down"}}"#),
    )

    let error = await withDependencies { $0.date = .constant(now) } operation: {
      await captureInferenceError(fetch: stubFetch(response))
    }
    #expect(error == .rateLimited(retryAt: now.addingTimeInterval(30)))
  }

  @Test("429 with HTTP-date Retry-After parses an absolute instant")
  func rateLimitedHTTPDate() async throws {
    var headers = Headers()
    headers[.retryAfter] = "Wed, 21 Oct 2026 07:28:00 GMT"
    let response = Response(
      status: .init(code: 429),
      headers: headers,
      body: .string("rate limited"),
    )

    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)

    guard case let .rateLimited(retryAt) = inferenceError else {
      Issue.record("expected .rateLimited, got \(inferenceError)")
      return
    }

    #expect(retryAt == Date(timeIntervalSince1970: 1_792_567_680))
  }

  @Test("HTTP-date parsing pins IMF-fixdate exactly and rejects near misses")
  func httpDateParsingPinned() {
    func retryAt(_ value: String) -> Date? {
      var headers = Headers()
      headers[.retryAfter] = value
      guard case let .rateLimited(date) = InferenceError.classify(
        status: 429, headers: headers, body: nil,
      ) else { return nil }
      return date
    }

    #expect(
      retryAt("Sun, 06 Nov 1994 08:49:37 GMT")
        == Date(timeIntervalSince1970: 784_111_777),
    )
    #expect(
      retryAt("  Wed, 21 Oct 2026 07:28:00 GMT  ")
        == Date(timeIntervalSince1970: 1_792_567_680),
    )
    #expect(
      retryAt("Tue, 29 Feb 2028 00:00:00 GMT")
        == Date(timeIntervalSince1970: 1_835_395_200),
    )

    #expect(retryAt("Wed, 21 Oct 2026 07:28:00 UTC") == nil)
    #expect(retryAt("Xyz, 21 Oct 2026 07:28:00 GMT") == nil)
    #expect(retryAt("Wed, 21 Foo 2026 07:28:00 GMT") == nil)
    #expect(retryAt("Wed, 21 Oct 2026 24:28:00 GMT") == nil)
    #expect(retryAt("garbage") == nil)
  }

  @Test("Non-finite or negative delta-seconds carry no retryAt", arguments: ["NaN", "inf", "-inf", "-5"])
  func rateLimitedRejectsUnusableDelta(_ value: String) {
    var headers = Headers()
    headers[.retryAfter] = value
    #expect(InferenceError.classify(status: 429, headers: headers, body: nil) == .rateLimited(retryAt: nil))
  }

  @Test("429 without Retry-After still maps to .rateLimited with nil retryAt")
  func rateLimitedNoHeader() async throws {
    let response = Response(status: .init(code: 429), body: .string("rate limited"))
    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)
    #expect(inferenceError == .rateLimited(retryAt: nil))
  }

  @Test("400 with a context-length-exceeded body maps to .contextTooLong")
  func contextTooLong() async throws {
    let response = Response(
      status: .init(code: 400),
      body: .string(#"{"error":{"type":"invalid_request_error","message":"prompt is too long: 250000 tokens > 200000 maximum"}}"#),
    )
    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)
    #expect(inferenceError == .contextTooLong)
  }

  @Test("413 maps to .contextTooLong regardless of body")
  func payloadTooLargeIsContextOverflow() async throws {
    let response = Response(status: .init(code: 413), body: .string("Payload Too Large"))
    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)
    #expect(inferenceError == .contextTooLong)
  }

  @Test("generic 400 maps to .invalidInput carrying status + body")
  func invalidInput() async throws {
    let response = Response(
      status: .init(code: 400),
      body: .string(#"{"error":{"type":"invalid_request_error","message":"missing field: model"}}"#),
    )
    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)

    guard case let .invalidInput(status, body) = inferenceError else {
      Issue.record("expected .invalidInput, got \(inferenceError)")
      return
    }

    #expect(status == 400)
    #expect(body?.contains("missing field") == true)
  }

  @Test("500 maps to .transient carrying status + body")
  func serverErrorIsTransient() async throws {
    let response = Response(status: .init(code: 500), body: .string("internal error"))
    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)

    guard case let .transient(status, body) = inferenceError else {
      Issue.record("expected .transient, got \(inferenceError)")
      return
    }

    #expect(status == 500)
    #expect(body?.contains("internal error") == true)
  }

  #if !canImport(FoundationEssentials)
    @Test("a URLError transport failure maps to .transient")
    func urlErrorIsTransient() async throws {
      let error = await captureInferenceError(
        fetch: throwingFetch(URLError(.notConnectedToInternet)),
      )
      let inferenceError = try #require(error)
      #expect(inferenceError == .transient(status: nil, body: nil))
    }
  #endif

  @Test("a FetchError transport-level failure maps to .transient")
  func fetchErrorIsTransient() async throws {
    let error = await captureInferenceError(
      fetch: throwingFetch(FetchError.bodyLimitExceeded(limit: 1)),
    )
    let inferenceError = try #require(error)
    #expect(inferenceError == .transient(status: nil, body: nil))
  }

  @Test("a FetchError.transportFailure maps to .transport carrying the kind")
  func fetchTransportFailureIsTransport() async throws {
    let error = await captureInferenceError(
      fetch: throwingFetch(FetchError.transportFailure(kind: .readTimeout)),
    )
    let inferenceError = try #require(error)
    #expect(inferenceError == .transport(.readTimeout))
  }

  @Test("CancellationError maps to .cancelled")
  func cancellationIsCancelled() async throws {
    let error = await captureInferenceError(fetch: throwingFetch(CancellationError()))
    let inferenceError = try #require(error)
    #expect(inferenceError == .cancelled)
  }

  @Test("an unrecognized error maps to .other with a diagnostic body")
  func unknownErrorIsOther() async throws {
    enum Weird: Error, CustomStringConvertible {
      case nope

      var description: String { "weird" }
    }

    let error = await captureInferenceError(fetch: throwingFetch(Weird.nope))
    let inferenceError = try #require(error)

    guard case let .other(status, body) = inferenceError else {
      Issue.record("expected .other, got \(inferenceError)")
      return
    }

    #expect(status == nil)
    #expect(body == "weird")
  }

  @Test("a mid-stream Anthropic overloaded_error maps to .transient")
  func midStreamOverloadIsTransient() async throws {
    let sse = """
    event: message_start
    data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

    event: error
    data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

    """
    let response = Response(
      status: .ok,
      headers: Headers(),
      body: .string(sse, encoding: .utf8),
    )

    let error = await captureInferenceError(fetch: stubFetch(response))
    let inferenceError = try #require(error)

    guard case let .transient(status, body) = inferenceError else {
      Issue.record("expected .transient, got \(inferenceError)")
      return
    }

    #expect(status == nil)
    #expect(body?.contains("Overloaded") == true)
  }

  @Test("a Responses cancelled event maps to .cancelled")
  func responsesCancelledIsCancelled() async throws {
    let sse = """
    event: response.cancelled
    data: {"type":"response.cancelled","response":{"status":"cancelled"}}

    """
    let response = Response(
      status: .ok,
      headers: Headers(),
      body: .string(sse, encoding: .utf8),
    )

    let error = await captureInferenceError(
      fetch: stubFetch(response),
      endpoint: openAIEndpoint(),
    )
    let inferenceError = try #require(error)
    #expect(inferenceError == .cancelled)
  }

  @Test("a Responses stream truncated before response.completed maps to .transient")
  func truncatedResponsesStreamIsTransient() async throws {
    let sse = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Hello"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1"}}

    """
    let response = Response(
      status: .ok,
      headers: Headers(),
      body: .string(sse, encoding: .utf8),
    )

    let error = await captureInferenceError(
      fetch: stubFetch(response),
      endpoint: openAIEndpoint(),
    )
    let inferenceError = try #require(error)

    guard case let .transient(status, body) = inferenceError else {
      Issue.record("expected .transient, got \(inferenceError)")
      return
    }

    #expect(status == nil)
    #expect(body?.contains("invalid_stream") == true)
    #expect(body?.contains("response.completed") == true)
  }
}
