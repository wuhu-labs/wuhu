import Credentials
import Dependencies
import FetchWebSocket
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
@testable import LoopCore
import Serve
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct ResponsesKernelAcceptanceTests {
  @Test func archiveUnarchiveStartOverAndShutdownInvalidateRuntimeInference() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "lifecycle", kind: .agent, createdBy: "morgan", model: .test)
      let invalidated = Box<[SessionID]>([])
      let committed = AsyncStream<Void>.makeStream()
      var config = makeConfig(inference: { _ in
        var reply = Fix.reply("done")
        reply.committed = { _, _ in committed.continuation.yield(()) }
        return reply
      })
      config.invalidateInference = { id in invalidated.withLock { $0.append(id) } }
      let service = await SessionService(sessions: sessions, loopConfig: config)
      try await runService(service) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        for await _ in committed.stream { break }
        try await service.archive(sid)
        #expect(invalidated.value == [sid])
        try await service.unarchive(sid)
        #expect(invalidated.value == [sid, sid])
        _ = try await service.restart(sid, executor: nil, note: nil)
        #expect(invalidated.value == [sid, sid, sid])
      }
      #expect(invalidated.value == [sid, sid, sid, sid])
      await #expect(throws: UnfulfilledError.self) { try await service.wake(sid) }
      #expect(await service.registry.sessions.isEmpty)
      #expect(invalidated.value == [sid, sid, sid, sid])
    }
  }

  @Test(arguments: [false, true])
  func modelAndMechanicalCompactionInvalidateRuntimeInference(mechanical: Bool) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "compaction", kind: .agent, createdBy: "morgan", model: .test)
      let compact = ToolCall(id: "call_compact", name: "compact", arguments: .object(["summary": .string("folded")]))
      let script = InferenceScript([Fix.replying("large", tokens: 900), mechanical ? Fix.failing(.contextTooLong) : Fix.replying("folding", calls: [compact], tokens: 950), Fix.replying("fresh", tokens: 100)])
      let invalidated = Box<[SessionID]>([])
      var config = makeConfig(inference: { try await script($0) }, compact: { _ in .init(summary: "mechanical") }, budget: .init(maxInput: 1100, maxOutput: 100))
      config.invalidateInference = { id in invalidated.withLock { $0.append(id) } }
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("fresh committed turn") { guard script.count == 3 else { return false }; return try await sessions.settledWork(sid) }
        #expect(invalidated.value == [sid])
      }
      #expect(invalidated.value == [sid, sid])
    }
  }

  @Test(arguments: ["committed", "no-ack", "phase", "handles"])
  func actualKernelCommitToolExecutionAndRendering(kind: String) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "socket acceptance", kind: .agent, createdBy: "morgan", model: .test)
      let registry = ResponsesSocketRegistry()
      let document = ModelsDocument(providers: ["offline": .init(dialect: .responses, baseURL: URL(string: "https://example.test/v1")!, transport: .websocket, models: ["test": .init(maxInput: 1_001_000, maxOutput: 1000, efforts: ["low"], defaultEffort: "low")])])
      let resolved = try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey("offline") }).resolve(.init(provider: "offline", model: "test", effort: "low"), session: sid)
      let (client, server) = WebSocket.pair()
      let inbound = AsyncThrowingStream<WebSocketEvent, any Error>.makeStream()
      let bodies = Box<[JSONValue]>([])
      let commits = Box<[AssistantEntry]>([])
      let dials = Box(0)
      let executions = Box<[String]>([])
      let connector = WebSocketConnector { _ in
        dials.withLock { $0 += 1 }
        return WebSocketConnection(inbound: .init(inbound.stream), send: { message in
          switch message {
          case .text(let text): try await client.send(.text(text))
          case .binary(let bytes): try await client.send(.binary(bytes))
          }
        }, close: { _ in client.close() }, abort: { client.abort() })
      }
      var config = makeConfig(executeTool: { call in
        executions.withLock { $0.append(call.id) }
        return .failure(.init(message: "lookup complete"))
      }, inference: { request in
        let lease = try await registry.acquire(session: sid, model: resolved)
        let executor = InferenceExecutor(session: sid, model: resolved, systemPrompt: "offline acceptance", tools: [Tool(name: "lookup", description: "lookup", parameters: .object(["type": .string("object"), "properties": .object([:])]))], webSocket: lease.session)
        let completed = try await executor.run(attemptID: request.attemptID, transcript: request.transcript, mode: .normal, handles: ["morgan": "old-handle"])
        await registry.release(session: sid, lease: lease.lease)
        return InferenceReply(message: completed.message, metadata: completed.metadata, committed: { entry, transcript in
          let persisted = try? await sessions.hydrate(sid).transcript.kernel
          #expect(persisted?.items.contains(.assistant(entry)) == true)
          commits.withLock { $0.append(entry) }
          if kind != "no-ack" {
            await executor.acknowledge(entry: entry, transcript: transcript, handles: ["morgan": kind == "handles" ? "new-handle" : "old-handle"])
          }
        })
      })
      config.invalidateInference = { await registry.invalidate($0) }
      try await withDependencies { $0[WebSocketConnector.self] = connector } operation: {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            for await message in client.inbound {
              switch message {
              case .text(let text): inbound.continuation.yield(.message(.text(text)))
              case .binary(let bytes): inbound.continuation.yield(.message(.binary(bytes)))
              }
            }
            inbound.continuation.finish()
          }
          group.addTask {
            var turn = 0
            for await message in server.inbound {
              guard case .text(let text) = message, let value = JSONValue.parse(text) else { throw AcceptanceFailure() }
              bodies.withLock { $0.append(value) }
              if turn == 0 {
                for event in [
                  #"{"type":"response.created","response":{"id":"resp_server"}}"#,
                  #"{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_server","call_id":"call_server","name":"lookup","arguments":""}}"#,
                  #"{"type":"response.function_call_arguments.done","item_id":"fc_server","arguments":"{\"key\":1}"}"#,
                  #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_server","call_id":"call_server","name":"lookup","arguments":"{\"key\":1}"}}"#,
                ] { try await server.send(.text(event)) }
                if kind == "phase" {
                  try await server.send(.text(#"{"type":"response.output_item.added","item":{"id":"msg_phase","type":"message","role":"assistant","phase":"commentary","content":[]}}"#))
                  try await server.send(.text(#"{"type":"response.output_item.done","item":{"id":"msg_phase","type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"looking up"}]}}"#))
                }
                try await server.send(.text(#"{"type":"response.completed","response":{"id":"resp_server","status":"completed","usage":{"input_tokens":10,"output_tokens":1},"output":[]}}"#))
              } else {
                guard turn == 1 else { throw AcceptanceFailure() }
                try await server.send(.text(#"{"type":"response.completed","response":{"id":"resp_done","status":"completed","usage":{"input_tokens":10,"output_tokens":0},"output":[]}}"#))
              }
              turn += 1
            }
          }
          do {
            try await runService(sessions, config) { service in
              _ = try await service.enqueue(item: Fix.message("use lookup"), to: sid)
              try await until("two committed turns") { commits.withLock { $0.count } == 2 }
              try await until("settled") { try await sessions.settledWork(sid) }
            }
            client.abort()
            await registry.shutdown()
            try await group.waitForAll()
          } catch {
            client.abort()
            await registry.shutdown()
            group.cancelAll()
            throw error
          }
        }
      }
      let captured = bodies.withLock { $0 }
      #expect(captured.count == 2)
      #expect(dials.withLock { $0 } == 1)
      let second = try #require(captured.last?.object)
      let input = try #require(second["input"]?.array)
      if kind == "committed" {
        #expect(second["previous_response_id"]?.stringValue == "resp_server")
        #expect(input.count == 1)
        #expect(input[0].object?["call_id"]?.stringValue == "call_server")
      } else {
        #expect(second["previous_response_id"] == nil)
        #expect(input.count > 1)
        let result = try #require(input.first { $0.object?["type"]?.stringValue == "function_call_output" })
        #expect(result.object?["call_id"]?.stringValue == executions.withLock { $0.first })
      }
      let entry = try #require(commits.withLock { $0.first })
      #expect(entry.toolCallIDs["call_server"]?.rawValue != "call_server")
      #expect(executions.withLock { $0 } == [entry.toolCallIDs["call_server"]!.rawValue])
    }
  }
}

private struct AcceptanceFailure: Error {}
