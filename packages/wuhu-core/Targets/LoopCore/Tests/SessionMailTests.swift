import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct SessionMailTests {
  @Test func `the cell takes what main mails as its own messages`() throws {
    #expect(SessionCell.kind == SessionMail.kind)
    for mail in [SessionMail.put(SessionPut(Fix.message("one"), topic: "t", due: anchor, throttle: 30)), .clear("t")] {
      let message = try JSONDecoder().decode(SessionCell.Message.self, from: JSONEncoder().encode(mail))
      #expect(try JSONDecoder().decode(SessionMail.self, from: JSONEncoder().encode(message)) == mail)
    }
  }

  @Test func `an input mailed while no worker runs is taken by the next one`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.enqueue(sid, input: Fix.message("one"))
      #expect(try await sessions.undrainedInputs(sid).isEmpty)

      let script = InferenceScript([Fix.replying("first")])
      try await runService(space, makeConfig(inference: { try await script($0) })) { _ in
        try await until("settled") { try await sessions.settledWork(sid) && script.count == 1 }
      }
      #expect(try await sessions.lines(sid).assistantLines.count == 1)
    }
  }
}
