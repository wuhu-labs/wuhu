import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import Scratch
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
      let folder = try ScratchFolder("session-mail")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let creator = SessionExecution(space: old, loopConfig: makeConfig())
      let sid = try await old.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      await creator.shutdown()
      try await old.close()

      let space = try Space.open(file: file)
      let sessions = space.sessions
      try await sessions.enqueue(sid, input: Fix.message("one"))
      #expect(try await sessions.undrainedInputs(sid).isEmpty)
      let script = InferenceScript([Fix.replying("first")])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      try await runService(service) { _ in
        try await until("settled") { try await sessions.settledWork(sid) && script.count == 1 }
      }
      #expect(try await sessions.lines(sid).assistantLines.count == 1)
      try await space.close()
    }
  }
}
