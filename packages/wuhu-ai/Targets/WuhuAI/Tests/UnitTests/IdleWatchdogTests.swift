import Clocks
import Dependencies
import Fetch
import Foundation
import Synchronization
import Testing
@testable import WuhuAI

private let completingSSE = """
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {}

"""

private final class StallGate: Sendable {
  private let held = Mutex<AsyncStream<Never>.Continuation?>(nil)

  func stall() async throws -> Response {
    let stream = AsyncStream<Never> { continuation in
      held.withLock { $0 = continuation }
    }
    for await _ in stream {}
    throw CancellationError()
  }
}

@Suite("Idle watchdog")
struct IdleWatchdogTests {
  @Test("silence past the idle window fails as .transport(.idleTimeout)")
  func idleSilenceTimesOut() async throws {
    let clock = TestClock()
    let gate = StallGate()
    let endpoint = AnthropicEndpoint(model: "claude-test", apiKey: "test-key")
      .withFetch(FetchClient { _ in try await gate.stall() })

    let outcome = Task { () -> InferenceError? in
      await withDependencies {
        $0.continuousClock = clock
      } operation: {
        do {
          _ = try await endpoint.inference(
            context: Context(messages: []),
            options: RequestOptions(idleTimeout: .seconds(120)),
          ).collect()
          return nil
        } catch let error as InferenceError {
          return error
        } catch {
          return nil
        }
      }
    }

    await clock.advance(by: .seconds(120))
    #expect(await outcome.value == InferenceError.transport(.idleTimeout))
  }

  @Test("a stream that completes never trips an armed watchdog")
  func completionBeatsTheWatchdog() async throws {
    let clock = TestClock()
    let endpoint = AnthropicEndpoint(model: "claude-test", apiKey: "test-key")
      .withFetch(FetchClient { _ in
        Response(status: .ok, body: .string(completingSSE, encoding: .utf8))
      })

    let message = try await withDependencies {
      $0.continuousClock = clock
    } operation: {
      try await endpoint.inference(
        context: Context(messages: []),
        options: RequestOptions(idleTimeout: .seconds(120)),
      ).collect()
    }

    #expect(flattenedText(message) == "Hello")
  }

  @Test("no idle window means no watchdog even when time never advances")
  func nilIdleTimeoutSkipsTheWatchdog() async throws {
    let endpoint = AnthropicEndpoint(model: "claude-test", apiKey: "test-key")
      .withFetch(FetchClient { _ in
        Response(status: .ok, body: .string(completingSSE, encoding: .utf8))
      })

    let message = try await withDependencies {
      $0.continuousClock = TestClock()
    } operation: {
      try await endpoint.inference(context: Context(messages: [])).collect()
    }

    #expect(flattenedText(message) == "Hello")
  }
}

private func flattenedText(_ message: AssistantMessage) -> String {
  message.content.compactMap { block -> String? in
    guard case let .text(content) = block else { return nil }
    return content.text
  }.joined()
}
