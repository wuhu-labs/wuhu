import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct ClaudeCodeArchiveTests {
  private static func isMirror(_ line: String) -> Bool { line.contains(#""type":"transcript_mirror""#) }

  @Test func `an idle agent loaded cold by the archive is archived on the first call`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode()
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        try await service.archive(sid)
      }
      #expect(try await sessions.record(sid).lifecycle.isArchived)
      #expect(fake.launches.value.isEmpty)
    }
  }

  @Test func `a parked task loaded cold by the archive is archived with no reminder turn`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await Self.parkedTask(sessions)
      await time.advance(by: 60)

      let fake = FakeClaudeCode()
      let write = ArchiveWrite()
      let service = await write.service(sessions, makeClaudeCodeConfig(fake))
      fake.service.withLock { $0 = service }
      async let archived: Void = service.archive(sid)
      try await until("the archive is being written") { write.reached.value }
      try await holds("the reminder that fell due never goes in") { fake.launches.value.isEmpty }
      write.gate.release()
      try await archived
      #expect(try await sessions.record(sid).lifecycle.isArchived)
      #expect(fake.launches.value.isEmpty)
      await service.registry.stop()
    }
  }

  @Test func `a failed archive write hands the owed reminder back to the loop`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await Self.parkedTask(sessions)
      await time.advance(by: 60)

      let fake = FakeClaudeCode(turnsPerLaunch: [[1]])
      let write = ArchiveWrite(fails: true)
      let service = await write.service(sessions, makeClaudeCodeConfig(fake))
      fake.service.withLock { $0 = service }
      let archive = Task { try await service.archive(sid) }
      try await until("the archive is being written") { write.reached.value }
      try await holds("no reminder while it is written") { fake.launches.value.isEmpty }
      write.gate.release()
      let result = await archive.result
      #expect(throws: ArchiveWriteFailed.self) { try result.get() }
      try await until("the reminder goes in") { fake.writes.value.count == 1 }
      #expect(fake.writtenTexts[0][0].contains("<source>park.r1</source>"))
      #expect(try await sessions.record(sid).lifecycle == .live)
      await service.registry.stop()
    }
  }

  @Test func `a pass already past the idle check starts no turn under the archive`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(deferred: { turn, line in turn == 0 && Self.isMirror(line) })
      let archived = try await Self.archiveWhileNagRenders(sessions, sid, fake, write: ArchiveWrite())
      try archived.get()
      let record = try await sessions.record(sid)
      #expect(record.lifecycle.isArchived)
      #expect(record.work == .noWork)
      #expect(fake.writes.value.count == 1)
    }
  }

  @Test func `a nag held back by a failed archive write goes in afterwards`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      let fake = FakeClaudeCode(deferred: { turn, line in turn == 0 && Self.isMirror(line) })
      let archived = try await Self.archiveWhileNagRenders(sessions, sid, fake, write: ArchiveWrite(fails: true)) {
        try await until("the nag goes in") { fake.writes.value.count == 2 }
      }
      #expect(throws: ArchiveWriteFailed.self) { try archived.get() }
      #expect(try await sessions.record(sid).lifecycle == .live)
      #expect(fake.writtenTexts[1][0].contains("<source>owed.reply</source>"))
    }
  }

  @Test func `a turn claimed before the archive refuses it until the turn runs`() async throws {
    try await withKernelDeps { time in
      let sessions = try Space.inMemory().sessions
      let sid = try await Self.parkedTask(sessions)
      await time.advance(by: 60)

      let fake = FakeClaudeCode(turnsPerLaunch: [[1]])
      let spawning = Box(false)
      let spawn = Latch()
      var config = makeClaudeCodeConfig(fake)
      let seam = fake.seam
      config.claudeCode = ClaudeCodeSeam(spawn: { launch in
        spawning.withLock { $0 = true }
        await spawn.wait()
        return try await seam.spawn(launch)
      }, render: seam.render)
      let write = ArchiveWrite()
      let service = await write.service(sessions, config)
      fake.service.withLock { $0 = service }
      try await service.wake(sid)
      try await until("the reminder turn is spawning") { spawning.value }
      let settled = Box(false)
      let archive = Task {
        defer { settled.withLock { $0 = true } }
        try await service.archive(sid)
      }
      try await until("the archive is refused or being written") { settled.value || write.reached.value }
      spawn.release()
      try await until("the reminder goes in") { fake.writes.value.count == 1 }
      write.gate.release()
      let result = await archive.result
      #expect(throws: SessionError.busyForArchive) { try result.get() }
      let record = try await sessions.record(sid)
      #expect(record.lifecycle == .live)
      await service.registry.stop()
    }
  }

  @Test func `a queued input or a running turn still refuses the archive`() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let sid = try await sessions.claudeCodeSession()
      _ = try await sessions.enqueue(sid, input: Fix.message("one"))
      let gate = Latch()
      let fake = FakeClaudeCode(cue: { cue in
        await gate.wait(unless: cue.killed)
        return .proceed
      })
      try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
        fake.service.withLock { $0 = service }
        await #expect(throws: SessionError.busyForArchive) { try await service.archive(sid) }
        try await until("the turn is running") { fake.writes.value.count == 1 }
        await #expect(throws: SessionError.busyForArchive) { try await service.archive(sid) }
        gate.release()
        try await until("the settled session archives") { (try? await service.archive(sid)) != nil }
      }
      #expect(try await sessions.record(sid).lifecycle.isArchived)
    }
  }

  // Archives a warm agent whose idle pass is rendering the nag owed after its
  // first turn, holding the store write until the render has been let go.
  private static func archiveWhileNagRenders(
    _ sessions: SessionStore,
    _ sid: SessionID,
    _ fake: FakeClaudeCode,
    write: ArchiveWrite,
    afterwards: () async throws -> Void = {},
  ) async throws -> Result<Void, any Error> {
    let rendering = Box(false)
    let render = Latch()
    var config = makeClaudeCodeConfig(fake)
    let seam = fake.seam
    config.claudeCode = ClaudeCodeSeam(spawn: seam.spawn) { id, inputs, channel in
      if channel == .standardInput, inputs.isEmpty, !rendering.value {
        rendering.withLock { $0 = true }
        await render.wait()
      }
      return try await seam.render(id, inputs, channel)
    }
    var archived: Result<Void, any Error> = .success(())
    try await runService(await write.service(sessions, config)) { service in
      fake.service.withLock { $0 = service }
      _ = try await service.enqueue(item: Fix.message("please answer", conversation: sid.rawValue, owesReply: true), to: sid)
      try await until("the nag after the turn's result is being rendered") { rendering.value }
      let archive = Task { try await service.archive(sid) }
      try await until("the archive is being written") { write.reached.value }
      render.release()
      try await holds("the nag turn never starts under it") { fake.writes.value.count == 1 }
      write.gate.release()
      archived = await archive.result
      try await afterwards()
    }
    return archived
  }

  // A task whose request is still open after its first park reminder; the
  // next one is due a minute later.
  private static func parkedTask(_ sessions: SessionStore) async throws -> SessionID {
    let sid = try await sessions.claudeCodeSession(kind: .task)
    let fake = FakeClaudeCode(deferred: { turn, line in turn == 0 && isMirror(line) })
    let request = QueueInput.message(.init(
      id: UUID(), messageID: .init("r1"), conversationID: .init("dm"), sender: Fix.sender, timestamp: anchor,
      kind: .request, requestID: .init("r1"), content: .init(text: "do it"),
    ))
    try await runService(sessions, makeClaudeCodeConfig(fake)) { service in
      fake.service.withLock { $0 = service }
      _ = try await service.enqueue(item: request, to: sid)
      try await until("the first park reminder goes in") { fake.writes.value.count == 2 }
      try await until("its turn settles") { try await sessions.settledWork(sid) && fake.hookReplies.value.count == 5 }
    }
    return sid
  }
}

private struct ArchiveWriteFailed: Error {}

// Holds the archive's store write until released, then writes it or fails.
private final class ArchiveWrite: Sendable {
  let reached = Box(false)
  let gate = Latch()
  private let fails: Bool

  init(fails: Bool = false) { self.fails = fails }

  func service(_ sessions: SessionStore, _ config: LoopConfig) async -> SessionService {
    await SessionService(sessions: sessions, loopConfig: config) { id in
      SessionRepo(sessions: sessions, id: id, archiveWrite: { store, id, grace in
        self.reached.withLock { $0 = true }
        await self.gate.wait()
        if self.fails { throw ArchiveWriteFailed() }
        return try await store.archive(id, grace: grace)
      })
    }
  }
}

extension SessionLifecycle {
  fileprivate var isArchived: Bool {
    if case .archived = self { true } else { false }
  }
}
