import Dependencies
import Foundation
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing
import WuhuAI

// The session's work flag as every committed write left it, consecutive
// repeats folded: a flip to no_work and back inside the exchange is the bug.
private final class WorkFlips: TransactionObserver, Sendable {
  let session: String
  let flips = Mutex<[String]>([])

  init(_ session: SessionID) { self.session = session.rawValue }

  func observes(eventsOfKind _: DatabaseEventKind) -> Bool { true }
  func databaseDidChange(with _: DatabaseEvent) {}
  func databaseDidRollback(_: Database) {}
  func databaseDidCommit(_ db: Database) {
    guard let work = try? String.fetchOne(db, sql: "SELECT work FROM sessions WHERE id = ?", arguments: [session]) else { return }
    flips.withLock { if $0.last != work { $0.append(work) } }
  }
}

@Suite struct KernelNagTests {
  private static let request = QueueInput.message(.init(
    id: UUID(), messageID: .init("r1"), conversationID: .init("dm"), sender: Fix.sender, timestamp: anchor,
    kind: .request, requestID: .init("r1"), content: .init(text: "do it"),
  ))

  private static func call(_ name: String, _ id: String) -> ToolCall {
    ToolCall(id: id, name: name, arguments: .object([:]))
  }

  private static func parkNotices(_ transcript: Transcript) -> Int {
    transcript.items.count { if case let .notification(notification) = $0 { notification.kind == .parkReminder } else { false } }
  }

  @Test func `the nag rides the write of the message that tried to finish, so the work never reads settled`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let flips = WorkFlips(sid)
      sessions.writer.add(transactionObserver: flips)

      let tail = Box<[TranscriptItem]>([])
      let stored = Box<SessionHydration?>(nil)
      let script = InferenceScript([
        Fix.replying("thinking out loud"),
        { request in
          tail.withLock { $0 = Array(request.transcript.items.suffix(2)) }
          let hydration = try await sessions.hydrate(sid)
          stored.withLock { $0 = hydration }
          return Fix.reply("answering", calls: [Self.call("send_message", "c-1")])
        },
        Fix.replying("all done"),
      ])
      let config = makeConfig(
        executeTool: { _ in .sendMessage(.init(messageID: .init("a1"), conversationID: .init(sid.rawValue), n: 1)) },
        inference: { try await script($0) },
      )
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("please review", conversation: sid.rawValue, owesReply: true), to: sid)
        try await until("the exchange settles") { try await sessions.settledWork(sid) && script.count == 3 }
        try await holds("the wrap-up to be the last word") { script.count == 3 }
      }

      guard case .assistant = tail.value.first, case let .notification(nag) = tail.value.last else {
        Issue.record("the nag follows the message that tried to finish: \(tail.value)")
        return
      }
      #expect(nag.kind == .owedReply && nag.conversations == [.init(sid.rawValue)])
      #expect(stored.value?.record.work == .hasWork)
      #expect(stored.value?.transcript.kernel.items.last?.id == nag.id, "stored with the message, before the next inference")
      #expect(stored.value?.queueTail == 1, "the nag was never a queue row")
      #expect(flips.flips.withLock { $0 } == [SessionWork.hasWork.rawValue, SessionWork.noWork.rawValue])
    }
  }

  @Test func `a stop the loop never judged is judged when the session resumes`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Fix.message("please review", conversation: sid.rawValue, owesReply: true))
      _ = try await sessions.drainQueue(sid)
      try await sessions.markInterrupted(sid)
      _ = try await sessions.appendAssistant(sid, attemptID: UUID(), message: .init(content: [.text("stopped")]), metadata: Fix.reply("").metadata)

      let seen = Box<SystemNotification?>(nil)
      let script = InferenceScript([
        { request in
          if case let .notification(notification)? = request.transcript.items.last { seen.withLock { $0 = notification } }
          return Fix.reply("noted")
        },
      ])
      try await runService(sessions, makeConfig(inference: { try await script($0) })) { service in
        try await service.resume(sid)
        try await until("the nag is answered") { try await sessions.settledWork(sid) && script.count == 1 }
        try await holds("once") { script.count == 1 }
      }
      #expect(seen.value?.kind == .owedReply)
      #expect(seen.value?.conversations == [.init(sid.rawValue)])
    }
  }

  @Test func `a task that stops with its request open is nagged at once, then on the backoff until it reports`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .task, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("done?"),
        Fix.replying("still thinking"),
        Fix.replying("reporting", calls: [Self.call("report", "c-1")]),
        Fix.replying("reported"),
      ])
      let config = makeConfig(
        executeTool: { _ in .report(.init(messageID: .init("f1"), requestID: .init("r1"), conversationID: .init("dm"), kind: .final)) },
        inference: { try await script($0) },
      )
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Self.request, to: sid)
        try await until("the first reminder is answered") { try await sessions.settledWork(sid) && script.count == 2 }
        try await holds("the next one waits a minute") { script.count == 2 }
        try await time.asleep("the park wake", dueIn: 60)
        await time.advance(by: 59)
        try await holds("still waiting") { script.count == 2 }
        await time.advance(by: 1)
        try await until("the park wake reports") { try await sessions.settledWork(sid) && script.count == 4 }
        await time.advance(by: 3600)
        try await holds("a reported task is never reminded again") { script.count == 4 }
      }
      let transcript = try await sessions.hydrate(sid).transcript.kernel
      #expect(Self.parkNotices(transcript) == 2)
      #expect(script.attempts.value[1].at == anchor)
      #expect(abs(script.attempts.value[2].at.timeIntervalSince(anchor) - 60) < 0.001)
    }
  }

  @Test func `a task waiting on an armed timer or a deadline on its child's request is never nagged`() async throws {
    let wakes: [ToolResultPayload] = [
      .timer(.init(subscriptionID: .init("timer.c-1"), schedule: .oneShot(anchor.addingTimeInterval(3600)), message: "check")),
      .request(.init(requestID: .init("c1"), task: .init("child"), conversationID: .init("dm-child"), deadline: anchor.addingTimeInterval(3600))),
    ]
    for wake in wakes {
      try await withKernelDeps { time in
        let sessions = try Space.inMemory().sessions
        let sid = try await sessions.createSession(group: .shared, title: "t", kind: .task, createdBy: "morgan", model: .test)
        let script = InferenceScript([
          Fix.replying("arming", calls: [Self.call("wake", "c-1")]),
          Fix.replying("waiting"),
        ])
        let config = makeConfig(executeTool: { _ in wake }, inference: { try await script($0) })
        try await runService(sessions, config) { service in
          _ = try await service.enqueue(item: Self.request, to: sid)
          try await until("it parks") { try await sessions.settledWork(sid) && script.count == 2 }
          #expect(time.sleepCount == 1 && time.sleeping(dueIn: 30) == 1, "only the reaper is asleep")
          await time.advance(by: 900)
          try await holds("no reminder while \(wake) is armed") { script.count == 2 }
        }
        #expect(Self.parkNotices(try await sessions.hydrate(sid).transcript.kernel) == 0)
      }
    }
  }

  @Test func `a task is not nagged while its exec runs, only when it stops`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .task, createdBy: "morgan", model: .test)
      let started = Box(false)
      let afterExec = Box<Int?>(nil)
      let script = InferenceScript([
        Fix.replying("building", calls: [Self.call("exec", "c-1")]),
        { request in
          afterExec.withLock { $0 = Self.parkNotices(request.transcript) }
          return Fix.reply("built")
        },
        Fix.replying("reminded"),
      ])
      let config = makeConfig(
        executeTool: { _ in
          @Dependency(\.continuousClock) var clock
          started.withLock { $0 = true }
          try await clock.sleep(for: .seconds(600))
          return .exec(.init(output: "ok", exitCode: 0))
        },
        inference: { try await script($0) },
      )
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Self.request, to: sid)
        try await until("the exec runs") { started.value }
        try await time.asleep("the exec", dueIn: 600)
        await time.advance(by: 300)
        try await holds("no reminder while the exec holds the turn") { script.count == 1 }
        await time.advance(by: 300)
        try await until("the stop is reminded") { try await sessions.settledWork(sid) && script.count == 3 }
      }
      #expect(afterExec.value == 0)
      #expect(Self.parkNotices(try await sessions.hydrate(sid).transcript.kernel) == 1)
    }
  }

  @Test func `a restarted task with its request still open stays inert when it loads`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .task, createdBy: "morgan", model: .test)
      _ = try await sessions.enqueue(sid, input: Self.request)
      _ = try await sessions.drainQueue(sid)
      _ = try await sessions.appendAssistant(sid, attemptID: UUID(), message: .init(content: [.text("stopped")]), metadata: Fix.reply("").metadata)
      try await sessions.restart(sid)
      #expect(try await sessions.bootSessions().contains(sid), "its request is still open")

      let script = InferenceScript([])
      try await runService(sessions, makeConfig(inference: { try await script($0) })) { _ in
        await time.advance(by: 900)
        try await holds("a restart spends no turn") { script.count == 0 }
      }
      #expect(try await sessions.record(sid).work == .noWork)
    }
  }
}
