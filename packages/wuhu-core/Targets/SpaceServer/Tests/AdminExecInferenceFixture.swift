#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import ServeNIO
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

struct AdminExecInferenceFixture: Sendable {
  private let server: ServeNIOServer
  private final class State: Sendable {
    let requests = Mutex(0)
    let held = AsyncStream<Void>.makeStream()
  }

  private let state: State

  static func start(space: Space) async throws -> Self {
    let state = State()
    let server = try await ServeNIOServer.bind(port: 0, handler: { request in
      #expect(request.headers[.init("x-api-key")!] == "fixture-credential")
      _ = try await request.body?.data()
      let round = state.requests.withLock { $0 += 1; return $0 }
      #expect(round <= 2, "A live request was duplicated across parent exec")
      if round == 2 { for await _ in state.held.stream {}; try Task.checkCancellation() }
      let source = "import {readText,writeText} from 'wuhu:space'; const p=await readText('/exec-effects.txt'); await writeText('/exec-effects.txt',String(Number(p.content)+1),{ifMatch:p.token}); result('once')"
      let block: JSONValue = round == 1 ? ["type": "tool_use", "id": "exec-once", "name": "run_script", "input": [:]] : ["type": "text", "text": ""]
      let delta: JSONValue = round == 1 ? ["type": "input_json_delta", "partial_json": .string(JSONValue.object(["source": .string(source), "timeout_seconds": 10, "on_timeout": "kill"]).jsonString())] : ["type": "text_delta", "text": "live inference survived parent exec"]
      let events: [(String, JSONValue)] = [
        ("message_start", ["message": ["usage": ["input_tokens": 10]]]),
        ("content_block_start", ["index": 0, "content_block": block]),
        ("content_block_delta", ["index": 0, "delta": delta]),
        ("content_block_stop", ["index": 0]),
        ("message_delta", ["delta": ["stop_reason": .string(round == 1 ? "tool_use" : "end_turn")], "usage": ["output_tokens": 1]]),
        ("message_stop", [:]),
      ]
      return Response(status: .ok, body: .bytes(Data(events.map { "event: \($0.0)\ndata: \($0.1.jsonString())\n\n" }.joined().utf8), contentType: "text/event-stream"))
    })
    let port = try #require(server.localAddress?.port)
    let models = """
    {"offline":{"dialect":"anthropic","baseURL":"http://127.0.0.1:\(port)","opaqueReplay":"none","models":{"small":{"maxInput":100000,"maxOutput":1000,"efforts":["none"],"defaultEffort":"none"}}}}
    """
    _ = try await space.fs(.shared).write("/models.json", Data(models.utf8), ifMatch: nil)
    _ = try await space.fs(.shared).write("/exec-effects.txt", Data("0".utf8), ifMatch: nil)
    return Self(server: server, state: state)
  }

  func isHeld() -> Bool { state.requests.withLock { $0 } == 2 }

  func finish(space: Space, session: SessionID, worker: WorkerClient) async throws {
    #expect(isHeld())
    #expect(try await space.fs(.shared).read("/exec-effects.txt").1 == Data("1".utf8))
    state.held.continuation.finish()
    try await until("held inference commits after real parent exec", timeout: .seconds(30)) {
      try await space.sessions.transcript(session).items.contains {
        if case let .assistant(entry) = $0 { entry.content.contains(.text("live inference survived parent exec")) } else { false }
      }
    }
    try await until("live worker settles after parent exec", timeout: .seconds(30)) {
      do { try await WorkerConnection.requireExecIdle(worker); return true } catch { return false }
    }
    let transcript = try await space.sessions.transcript(session)
    #expect(transcript.items.filter { if case .toolResult = $0 { true } else { false } }.count == 1)
    #expect(try await space.fs(.shared).read("/exec-effects.txt").1 == Data("1".utf8))
    #expect(isHeld())
  }

  func shutdown() async { state.held.continuation.finish(); await server.shutdown() }
}
