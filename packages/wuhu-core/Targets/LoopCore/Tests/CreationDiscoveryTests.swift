import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct CreationDiscoveryTests {
  @Test func `a seeded session's first wake runs its pre-reads before its first inference`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(
        group: .shared,
        title: "t",
        kind: .agent,
        createdBy: "morgan",
        model: .test,
        snapshot: .init(preReads: ["/AGENTS.md"]),
      )

      let script = InferenceScript([Fix.replying("hello")])
      let executed = ExecScript { call in
        guard call.name == "read" else { throw UnexpectedCall("tool \(call.name)") }
        return .read(.init(path: "/AGENTS.md", revision: .journal(1), content: "instructions"))
      }
      let config = makeConfig(executeTool: { try await executed($0) }, inference: { try await script($0) })

      try await runService(sessions, config) { service in
        try await service.wake(sid)
        try await until("first assistant reply") {
          try await sessions.hydrate(sid).transcript.kernel.assistantEntries.count == 1
        }
      }

      let calls = executed.calls.value
      #expect(calls.map(\.name) == ["read"])
      #expect(calls.first?.arguments == .object(["path": .string("/AGENTS.md")]))

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      guard transcript.items.count == 3,
            case .generationHead = transcript.items[0],
            case let .toolResult(reread) = transcript.items[1],
            case .assistant = transcript.items[2]
      else {
        Issue.record("expected head + read result + assistant, got \(transcript.items)")
        return
      }
      #expect(reread.provenance == .compactionReestablishment)
      #expect(!transcript.needsReestablishment, "a fresh assistant settles re-establishment")

      #expect(script.attempts.value.first?.itemCount == 2)
    }
  }

  @Test func `a pre-feature session without a head wakes inert`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let config = makeConfig()
      try await runService(sessions, config) { service in
        try await service.wake(sid)
        try await holds("no work appears") { try await sessions.settledWork(sid) }
      }
      #expect(try await sessions.hydrate(sid).transcript.kernel.items.isEmpty)
    }
  }
}
