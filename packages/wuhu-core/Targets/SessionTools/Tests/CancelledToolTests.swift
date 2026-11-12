import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import class MainHub.Hub
import SessionDomain
@testable import SessionTools
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall

@Suite(.deterministicDependencies, .timeLimit(.minutes(1))) struct CancelledToolTests {
  /// Runs `call` in a task that is cancelled before it reaches the executor.
  private func cancelledBeforeItBegins(_ executor: ToolExecutor, _ session: SessionID, _ call: ToolCall) async throws -> ToolResultPayload {
    let task = Task { () -> ToolResultPayload in
      while !Task.isCancelled { await Task.yield() }
      return try await executor.execute(session: session, call: call, state: ToolExecutionState()).payload
    }
    task.cancel()
    return try await task.value
  }

  @Test func `a write cancelled before it begins writes and answers with its own result`() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = try await SessionRuntime.toolExecutor(owner: Hub(space: space))
      let session = try await makeSession(space)

      let call = ToolCall(id: "tc-cancelled-write", name: "write", arguments: .object(["path": "/notes/cancelled.md", "content": "written anyway"]))
      guard case .write = try await cancelledBeforeItBegins(executor, session, call) else {
        throw Mismatch("a cancelled write should answer its own result")
      }
      #expect(try await space.readTextForTest("/notes/cancelled.md") == "written anyway")
    }
  }

  @Test func `a grep cancelled before it begins runs nothing`() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/notes/a.md", Data("needle".utf8), ifMatch: nil)
      let executor = try await SessionRuntime.toolExecutor(owner: Hub(space: space))
      let session = try await makeSession(space)

      let call = ToolCall(id: "tc-cancelled-grep", name: "grep", arguments: .object(["pattern": .string("needle")]))
      await #expect(throws: CancellationError.self) {
        _ = try await cancelledBeforeItBegins(executor, session, call)
      }
    }
  }

  @Test func `a grep cancelled while it runs answers its result`() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/notes/a.md", Data("needle".utf8), ifMatch: nil)
      let session = try await makeSession(space)
      let tokens = try await testTokens(space: space, spaceURL: "http://main")
      let connection = MainConnection()
      let main = FetchClient.inProcess(SessionRuntime.bindMain(owner: Hub(space: space), tokens: tokens, connection: connection))
      let held = HeldRequest()
      connection.bind(FetchClient { request in
        if request.url.path == "/v1/tools/grep" { await held.wait() }
        // Main answers on its own process, not in the caller's task: the caller's cancellation is not its to observe.
        return try await Task { try await main(request) }.value
      })
      let executor = ToolExecutor(main: connection, credential: { try await tokens.sessionToken($0) })

      let call = ToolCall(id: "tc-running-grep", name: "grep", arguments: .object(["pattern": .string("needle")]))
      let running = Task { try await executor.execute(session: session, call: call, state: ToolExecutionState()) }
      try await until("the grep reaches main") { held.reached }
      running.cancel()
      held.open()
      guard case let .grep(result) = try await running.value.payload else {
        throw Mismatch("a grep that began before the cancellation should answer its result")
      }
      #expect(result.output.contains("needle"))
    }
  }
}

/// A main request the test holds: the first one to reach it parks, and says so.
private final class HeldRequest: Sendable {
  private struct State {
    var reached = false
    var open = false
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var reached: Bool { state.withLock { $0.reached } }

  func wait() async {
    await withCheckedContinuation { continuation in
      let open = state.withLock { state -> Bool in
        state.reached = true
        guard !state.open else { return true }
        state.waiting.append(continuation)
        return false
      }
      if open { continuation.resume() }
    }
  }

  func open() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.open = true
      defer { state.waiting = [] }
      return state.waiting
    }
    for continuation in waiting { continuation.resume() }
  }
}
