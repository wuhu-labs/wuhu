import Dependencies
import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct WakeTests {
  @Test func `wake drains a delivery written straight to the repo while the session is live`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("first"),
        Fix.replying("second"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("one"), to: sid)
        try await until("first settle") { try await sessions.settledWork(sid) }

        // The channel fan-out path: the row lands in the repo without passing
        // through the live actor; the write's work signal wakes the recipient.
        _ = try await sessions.enqueue(sid, input: Fix.message("two"))

        try await until("second settle") {
          try await sessions.settledWork(sid) && script.count == 2
        }
      }

      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(transcript.assistantEntries.count == 2)
    }
  }
}
