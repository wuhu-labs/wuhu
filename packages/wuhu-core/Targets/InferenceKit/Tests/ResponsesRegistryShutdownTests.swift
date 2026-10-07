import Clocks
import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import SessionDomain
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ResponsesRegistryShutdownTests {
  @Test(arguments: [false, true])
  func explicitAndRunnerCancellationShutdownCloseOwnedSessionsAndAcquisition(cancellingRunner: Bool) async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let registry = ResponsesSocketRegistry()
      var model = try await fixtureCatalog().resolve(.init(provider: "openai", model: "gpt-5.4", effort: "medium"), session: .init("shutdown"))
      model.transport = .websocket
      let lease = try await registry.acquire(session: .init("shutdown"), model: model)
      let sent = AsyncStream<Void>.makeStream()
      let aborted = AsyncStream<Void>.makeStream()
      let task = Task {
        try await withDependencies { values in
          values[WebSocketConnector.self] = .init { _ in
            let inbound = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
            return WebSocketConnection(inbound: .init(inbound.stream), send: { _ in sent.continuation.yield(()) }, close: { _ in inbound.continuation.finish() }, abort: { aborted.continuation.yield(()); inbound.continuation.finish() })
          }
        } operation: {
          try await OpenAIGPTEndpoint(model: "test", apiKey: "offline").withWebSocket(session: lease.session, attemptID: "one").inference(context: .init(messages: [])).collect()
        }
      }
      for await _ in sent.stream { break }
      if cancellingRunner {
        let started = AsyncStream<Void>.makeStream()
        let runner = Task { started.continuation.yield(()); await registry.run() }
        for await _ in started.stream { break }
        runner.cancel()
        let _: Void = await runner.value
      } else {
        let _: Void = await registry.shutdown()
      }
      for await _ in aborted.stream { break }
      switch await task.result {
      case .success: Issue.record("owned inference survived shutdown")
      case .failure(let error): #expect(error as? InferenceError == .transport(.connectionClosed))
      }
      await #expect(throws: CancellationError.self) { _ = try await registry.acquire(session: .init("shutdown"), model: model) }
      let _: Void = await registry.shutdown()
    }
  }
}
