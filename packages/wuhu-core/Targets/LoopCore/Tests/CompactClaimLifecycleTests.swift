#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct CompactClaimLifecycleTests {
  @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [nil, "keep the notes"] as [String?])
  func teardownDuringClaimPreservesOrIntentionallyDiscardsCommand(ordering: (restart: Bool, beforeWrite: Bool), instructions: String?) async throws {
    let (restart, beforeWrite) = ordering
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "claim teardown", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.requestCommand(id, .compact(instructions: instructions))
      let entered = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      defer { entered.continuation.finish(); release.continuation.finish(); gate.cancel() }
      let actor = SessionActor(
        id: id,
        repo: SessionRepo(sessions: sessions, id: id, compactClaimWrite: { store, id, generation in
          if beforeWrite {
            entered.continuation.yield(())
            await gate.value
            return try await store.claimCompactRequest(id, generation: generation)
          }
          let command = try await store.claimCompactRequest(id, generation: generation)
          entered.continuation.yield(())
          await gate.value
          return command
        }),
        loopConfig: makeConfig(),
        liveness: LivenessTracker(),
      )
      await actor.activate()
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      for await _ in entered.stream { break }
      let looper = try #require(await actor.looperTask)
      if restart {
        try await sessions.markInterrupted(id)
        _ = try await withCallback(of: SessionRestart.self) { actor.post(.restart(nil, nil, $0)) }
      } else {
        await actor.shutdown()
      }
      release.continuation.yield(())
      await looper.value
      let hydration = try await sessions.hydrate(id)
      if restart {
        #expect(try await sessions.pendingCommand(id) == nil)
        #expect(!hydration.transcript.kernel.items.contains { if case let .notification(n) = $0 { return n.kind == .compactRequest }; return false })
        #expect(hydration.undrained.isEmpty)
        await actor.shutdown()
      } else {
        #expect(try await sessions.pendingCommand(id) == .compact(instructions: instructions))
      }
    }
  }

  @Test func oldClaimCleanupPreservesRemountedClaimAndArchiveRefusal() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "claim overlap", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.requestCommand(id, .compact(instructions: "old"))
      let entered = AsyncStream<Int>.makeStream()
      let oldRelease = AsyncStream<Void>.makeStream()
      let newRelease = AsyncStream<Void>.makeStream()
      let oldGate = Task { for await _ in oldRelease.stream { break } }
      let newGate = Task { for await _ in newRelease.stream { break } }
      defer {
        entered.continuation.finish(); oldRelease.continuation.finish(); newRelease.continuation.finish()
        oldGate.cancel(); newGate.cancel()
      }
      let settled = AsyncStream<Void>.makeStream()
      defer { settled.continuation.finish() }
      let claims = Box(0)
      let actor = SessionActor(
        id: id,
        repo: SessionRepo(sessions: sessions, id: id, compactClaimWrite: { _, _, _ in
          let claim = claims.withLock { $0 += 1; return $0 }
          entered.continuation.yield(claim)
          if claim == 1 { await oldGate.value } else { await newGate.value }
          return nil
        }),
        loopConfig: makeConfig(),
        liveness: LivenessTracker(),
        afterLoop: { settled.continuation.yield(()) },
      )
      await actor.activate()
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      var iterator = entered.stream.makeAsyncIterator()
      #expect(await iterator.next() == 1)
      let oldLooper = try #require(await actor.looperTask)
      _ = try await withCallback(of: SessionRestart.self) { actor.post(.restart(nil, nil, $0)) }
      try await sessions.requestCommand(id, .compact(instructions: "new"))
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      #expect(await iterator.next() == 2)
      let newLooper = try #require(await actor.looperTask)
      oldRelease.continuation.yield(())
      await oldLooper.value
      #expect(await actor.liveState?.claimingCompactRequest == true)
      let reservation = UUID()
      let prepared = try await withCallback(of: Bool.self) { actor.post(.prepareArchive(reservation, $0)) }
      #expect(!prepared)
      if prepared { try await withCallback(of: Void.self) { actor.post(.releaseArchive(reservation, $0)) } }
      newRelease.continuation.yield(())
      for await _ in settled.stream { break }
      #expect(await actor.liveState?.claimingCompactRequest == false)
      let ready = try await withCallback(of: Bool.self) { actor.post(.prepareArchive(reservation, $0)) }
      #expect(ready)
      if ready { try await withCallback(of: Void.self) { actor.post(.releaseArchive(reservation, $0)) } }
      await actor.shutdown()
      await newLooper.value
    }
  }

  @Test(arguments: [false, true])
  func legacyCommandDeletionOrReplacementDoesNotGiveATokenRuntimeMeaning(replacement: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "legacy token", kind: .agent, createdBy: "morgan", model: .test)
      try await sessions.requestCommand(id, .compact(instructions: nil))
      #expect(try await sessions.claimCompactRequest(id, generation: 0) != nil)
      try await space.writer.write { db in
        if replacement {
          try db.execute(sql: "UPDATE session_commands SET created_at = ? WHERE session_id = ?", arguments: ["2026-10-14T11:17:16.000Z", id.rawValue])
        } else {
          try db.execute(sql: "DELETE FROM session_commands WHERE session_id = ?", arguments: [id.rawValue])
        }
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_command_tokens WHERE session_id = ?", arguments: [id.rawValue]) == 1)
      }
      try await verifyLegacyCompactToken(space: space, id: id, replacement: replacement)
    }
  }
}

func verifyLegacyCompactToken(space: Space, id: SessionID, replacement: Bool) async throws {
  let sessions = space.sessions
  let entered = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  let settled = AsyncStream<Void>.makeStream()
  let gate = Task { for await _ in release.stream { break } }
  defer { entered.continuation.finish(); release.continuation.finish(); settled.continuation.finish(); gate.cancel() }
  let actor = SessionActor(
    id: id,
    repo: SessionRepo(sessions: sessions, id: id),
    loopConfig: makeConfig(inference: { request in
      if request.mode == .forcedCompact {
        entered.continuation.yield(())
        await gate.value
      }
      return Fix.reply("done")
    }, compact: { _ in .init(summary: "folded") }),
    liveness: LivenessTracker(),
    afterLoop: { settled.continuation.yield(()) },
  )
  await actor.activate()
  try await withCallback(of: Void.self) { actor.post(.wake($0)) }
  let reservation = UUID()
  if replacement {
    for await _ in entered.stream { break }
    let state = try #require(await actor.liveState)
    #expect(state.compactRequestClaim != nil)
    #expect(!state.hasSettled)
    let prepared = try await withCallback(of: Bool.self) { actor.post(.prepareArchive(reservation, $0)) }
    #expect(!prepared)
    if prepared { try await withCallback(of: Void.self) { actor.post(.releaseArchive(reservation, $0)) } }
    release.continuation.yield(())
  }
  for await _ in settled.stream { break }
  #expect(try await sessions.pendingCommand(id) == nil)
  let ready = try await withCallback(of: Bool.self) { actor.post(.prepareArchive(reservation, $0)) }
  #expect(ready)
  if ready { try await withCallback(of: Void.self) { actor.post(.archive(reservation, $0)) } }
  await actor.shutdown()
}
