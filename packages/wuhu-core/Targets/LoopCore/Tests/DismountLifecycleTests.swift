#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct DismountLifecycleTests {
  enum Teardown: CaseIterable, Sendable {
    case shutdown, restart, archive
  }

  @Test(arguments: Teardown.allCases)
  func cancelledLooperCannotEnterCompactRequestAfterDismount(teardown: Teardown) async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "teardown", kind: .agent, createdBy: "morgan", model: .test)
      let entered = AsyncStream<Void>.makeStream()
      let cancelled = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let gate = Task { for await _ in release.stream { break } }
      let remounted = AsyncStream<Void>.makeStream()
      let releaseRemount = AsyncStream<Void>.makeStream()
      let remountGate = Task { for await _ in releaseRemount.stream { break } }
      defer {
        entered.continuation.finish()
        cancelled.continuation.finish()
        release.continuation.finish()
        remounted.continuation.finish()
        releaseRemount.continuation.finish()
        remountGate.cancel()
        gate.cancel()
      }
      let pendingReads = Box(0)
      let passes = Box(0)
      let actor = SessionActor(
        id: id,
        main: InProcessMainClient { message in
          let store = InProcessMainClient(sessions: sessions)
          guard case .read(let id, .pendingCommand) = message else { return try await store.send(message) }
          pendingReads.withLock { $0 += 1 }
          return try await store.send(.read(id, .pendingCommand))
        },
        loopConfig: makeConfig(),
        liveness: LivenessTracker(),
        beforeCompactRequest: {
          let pass = passes.withLock { $0 += 1; return $0 }
          guard pass == 1 else {
            remounted.continuation.yield(())
            await remountGate.value
            return
          }
          await withTaskCancellationHandler {
            entered.continuation.yield(())
            await gate.value
          } onCancel: {
            cancelled.continuation.yield(())
          }
        },
      )
      await actor.activate()
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      for await _ in entered.stream { break }
      let looper = try #require(await actor.looperTask)
      let reservation = UUID()
      let stopping = Task {
        switch teardown {
        case .shutdown:
          await actor.shutdown()
        case .restart:
          _ = try await withCallback(of: SessionRestart.self) { actor.post(.restart(nil, nil, nil, $0)) }
        case .archive:
          let prepared = try await withCallback(of: Bool.self) { actor.post(.prepareArchive(reservation, $0)) }
          #expect(prepared)
          try await withCallback(of: Void.self) { actor.post(.archive(reservation, $0)) }
        }
      }
      for await _ in cancelled.stream { break }
      #expect(await actor.liveState == nil)
      #expect(looper.isCancelled)
      try await stopping.value
      #expect(try await sessions.record(id).work == .noWork)
      if teardown != .shutdown {
        if teardown == .archive {
          try await withCallback(of: Void.self) { actor.post(.releaseArchive(reservation, $0)) }
          try await withCallback(of: Void.self) { actor.post(.unarchive($0)) }
        }
        try await withCallback(of: Void.self) { actor.post(.wake($0)) }
        for await _ in remounted.stream { break }
        let newLooper = try #require(await actor.looperTask)
        release.continuation.yield(())
        await looper.value
        #expect(pendingReads.value == 0)
        let state = try #require(await actor.liveState)
        #expect(state.lastUpdatedByLoopAt == nil)
        #expect(!state.claimingCompactRequest)
        await actor.shutdown()
        releaseRemount.continuation.yield(())
        await newLooper.value
      } else {
        release.continuation.yield(())
        await looper.value
      }
      #expect(pendingReads.value == 0)
    }
  }

  @Test func lateWorkCleanupCannotClearRemountedWork() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let id = try await sessions.createSession(group: .shared, title: "overlapping loops", kind: .agent, createdBy: "morgan", model: .test)
      let entered = AsyncStream<Int>.makeStream()
      let oldRelease = AsyncStream<Void>.makeStream()
      let newRelease = AsyncStream<Void>.makeStream()
      let oldGate = Task { for await _ in oldRelease.stream { break } }
      let newGate = Task { for await _ in newRelease.stream { break } }
      defer {
        entered.continuation.finish()
        oldRelease.continuation.finish()
        newRelease.continuation.finish()
        oldGate.cancel()
        newGate.cancel()
      }
      let attempts = Box(0)
      let actorReference = Box<SessionActor?>(nil)
      let actor = SessionActor(
        id: id,
        main: InProcessMainClient(sessions: sessions),
        loopConfig: makeConfig(),
        liveness: LivenessTracker(),
        beforeCompactRequest: {
          guard let actor = actorReference.value else {
            Issue.record("actor reference not installed")
            return
          }
          let attempt = attempts.withLock { $0 += 1; return $0 }
          _ = await actor.runLongRunningTask {
            entered.continuation.yield(attempt)
            if attempt == 1 { await oldGate.value } else { await newGate.value }
          }
        },
      )
      actorReference.withLock { $0 = actor }
      defer { actorReference.withLock { $0 = nil } }
      await actor.activate()
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      var iterator = entered.stream.makeAsyncIterator()
      #expect(await iterator.next() == 1)
      let oldLooper = try #require(await actor.looperTask)
      _ = try await withCallback(of: SessionRestart.self) { actor.post(.restart(nil, nil, nil, $0)) }
      try await withCallback(of: Void.self) { actor.post(.wake($0)) }
      #expect(await iterator.next() == 2)
      let newLooper = try #require(await actor.looperTask)
      let newWork = try #require(await actor.longRunningTask)
      oldRelease.continuation.yield(())
      await oldLooper.value
      #expect(await actor.longRunningTask?.id == newWork.id)
      #expect(await actor.liveState?.lastUpdatedByLoopAt == nil)
      #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.isEmpty)
      await actor.shutdown()
      #expect(newWork.task.isCancelled)
      newRelease.continuation.yield(())
      await newLooper.value
      #expect(try await sessions.hydrate(id).transcript.kernel.assistantEntries.isEmpty)
    }
  }
}
