import class MainHub.Hub
import struct MainHub.SessionAccess
import class MainHub.SessionService
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import struct WuhuAI.ToolCall

@Suite(.timeLimit(.minutes(1))) struct ToolOutcomeCommitTests {
  @Test(arguments: [false, true], [false, true])
  func acknowledgementFollowsDurableToolResult(reestablishment: Bool, appendFails: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "tool commit", kind: .agent, createdBy: "morgan", model: .test)
      let calls = Box(0)
      let commits = Box(0)
      let appends = Box(0)
      let releaseAppend = Latch()
      defer { releaseAppend.release() }
      var access = SessionAccess()
      access.beforeAppend = { _, event in
        guard case let .transcriptAppended(items, _, _) = event,
              items.contains(where: { item in
                guard case let .toolResult(result) = item else { return false }
                return result.payload.renderedText.contains("durable payload")
              })
        else { return }
        appends.withLock { $0 += 1 }
        #expect(commits.value == 0)
        await releaseAppend.wait(unless: { Task.isCancelled })
        if appendFails { throw UnexpectedCall("tool append refused") }
      }
      let hub = Hub(space: space, sessionAccess: access)
      let call: ToolCall = reestablishment
        ? .init(id: "compact_call", name: "compact", arguments: .object([
          "summary": .string("retained work"),
          "pre_reads": .array([.string("/notes.md")]),
        ]))
        : .init(id: "read_call", name: "read", arguments: .object(["path": .string("/notes.md")]))
      let script = InferenceScript([
        Fix.replying("reading", calls: [call]),
        Fix.replying("done"),
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.executeTool = { invocation in
        calls.withLock { $0 += 1 }
        return ToolOutcome(payload: .read(.init(path: "/notes.md", revision: .journal(1), content: "durable payload")), committed: {
          do {
            let transcript = try await sessions.hydrate(id).transcript.kernel
            let results = transcript.items.compactMap { item -> ToolResultItem? in
              guard case let .toolResult(result) = item, result.payload.renderedText.contains("durable payload") else { return nil }
              return result
            }
            #expect(results.count == 1)
            #expect(results.first?.provenance == (reestablishment ? .compactionReestablishment : .toolCall(ToolCallID(invocation.call.id))))
          } catch {
            Issue.record(error)
          }
          commits.withLock { $0 += 1 }
        })
      }
      let service = await SessionService(sessions: sessions, main: hub, loopConfig: config)
      try await runService(service) { service in
        _ = try await service.enqueue(item: Fix.message("read it"), to: id)
        do {
          try await until("tool result append entered") { appends.value == 1 }
          #expect(commits.value == 0)
          let before = try await sessions.hydrate(id).transcript.kernel
          #expect(!before.items.contains { item in
            guard case let .toolResult(result) = item else { return false }
            return result.payload.renderedText.contains("durable payload")
          })
          releaseAppend.release()
          if appendFails {
            try await until("failed append parks session") { try await sessions.record(id).work == .errored }
            #expect(commits.value == 0)
          } else {
            try await until("tool outcome acknowledged") { commits.value == 1 }
            try await until("settled after tool result") { try await sessions.settledWork(id) }
          }
        } catch {
          releaseAppend.release()
          throw error
        }
      }
      #expect(calls.value == 1)
      #expect(commits.value == (appendFails ? 0 : 1))
      if appendFails {
        let transcript = try await sessions.hydrate(id).transcript.kernel
        #expect(!transcript.items.contains { item in
          guard case let .toolResult(result) = item else { return false }
          return result.payload.renderedText.contains("durable payload")
        })
      }
    }
  }
}
