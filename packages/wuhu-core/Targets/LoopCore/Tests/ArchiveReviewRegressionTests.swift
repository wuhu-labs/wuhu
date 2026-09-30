import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing
import WuhuAI

@Suite struct ArchiveReviewRegressionTests {
  @Test func contractorRestartBetweenPreflightAndWriteFailsWithoutCrashing() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", executor: .contractor(name: "retired"))
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig()) { id in
        SessionRepo(sessions: sessions, id: id, archiveWrite: { store, id, grace in
          if id == child { _ = try await store.restart(root, executor: .kernel(.test), note: nil) }
          return try await store.archive(id, grace: grace)
        })
      }
      do {
        await #expect(throws: SessionError.archiveReservationLost) { try await service.archive(root) }
        #expect(try await sessions.record(root).lifecycle == .live)
        #expect(!sessions.isReservedForArchive(root))
        #expect(!sessions.isReservedForArchive(child))
        try await service.wake(root)
        try await service.archive(root)
        #expect(try await sessions.record(root).lifecycle != .live)
      } catch {
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }

  @Test func reservedParentFinalDoesNotBlockOtherSessionsWorkSignalsOrEnqueue() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let outside = try await sessions.createSession(group: .shared, title: "outside", kind: .agent, createdBy: "owner", model: .test)
      try await sessions.markInterrupted(root)
      try await sessions.markInterrupted(child)
      let delivery = try await sessions.openRequest(on: child, from: root, messageID: .init("reserved-request"), text: "work", deadline: nil)
      let writing = Box(false)
      let outsideRan = Box(false)
      let enqueued = Box(false)
      let gate = Latch()
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        #expect(request.sessionID == outside)
        outsideRan.withLock { $0 = true }
        return Fix.reply("done")
      })) { id in
        SessionRepo(sessions: sessions, id: id, archiveWrite: { store, id, grace in
          if id == child {
            writing.withLock { $0 = true }
            await gate.wait(unless: { Task.isCancelled })
          }
          return try await store.archive(id, grace: grace)
        })
      }
      try await runService(service) { service in
        let archive = Task { try await service.archive(root, force: true) }
        let enqueue = Task {
          try await until("archive write held") { writing.value }
          _ = try await service.enqueue(item: Fix.message("reserved delivery"), to: root)
          enqueued.withLock { $0 = true }
        }
        do {
          try await until("archive write held") { writing.value }
          #expect(try await sessions.messages(conversation: delivery.message.conversation).contains { $0.kind == .final })
          try await until("reserved enqueue returns") { enqueued.value }
          _ = try await sessions.enqueue(outside, input: Fix.message("unrelated work"))
          try await until("unrelated work signal consumed during reservation") { outsideRan.value }
          gate.release()
          _ = try await (archive.value, enqueue.value)
        } catch {
          gate.release()
          archive.cancel()
          enqueue.cancel()
          _ = await archive.result
          _ = await enqueue.result
          throw error
        }
      }
    }
  }

  @Test func failedWriteReleasesReservationAndResynchronizesDeliveredInput() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let writing = Box(false)
      let ran = Box(false)
      let gate = Latch()
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { _ in
        ran.withLock { $0 = true }
        return Fix.reply("done")
      })) { id in
        SessionRepo(sessions: sessions, id: id, archiveWrite: { _, _, _ in
          writing.withLock { $0 = true }
          await gate.wait(unless: { Task.isCancelled })
          throw UnexpectedCall("archive write failed")
        })
      }
      let archive = Task { try await service.archive(root) }
      do {
        try await until("archive write held") { writing.value }
        _ = try await service.enqueue(item: Fix.message("delivered during archive"), to: root)
        #expect(!ran.value)
        gate.release()
        await #expect(throws: UnexpectedCall.self) { try await archive.value }
        try await until("delivery consumed after failed archive") { ran.value }
        #expect(!sessions.isReservedForArchive(root))
        #expect(try await sessions.record(root).lifecycle == .live)
      } catch {
        gate.release()
        archive.cancel()
        _ = await archive.result
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }

  @Test func creationCannotAttachBelowReservedOrArchivedParent() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let writing = Box(false)
      let gate = Latch()
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig()) { id in
        SessionRepo(sessions: sessions, id: id, archiveWrite: { store, id, grace in
          writing.withLock { $0 = true }
          await gate.wait(unless: { Task.isCancelled })
          return try await store.archive(id, grace: grace)
        })
      }
      let archive = Task { try await service.archive(root) }
      do {
        try await until("parent reserved") { writing.value }
        for store in [sessions, space.sessions] {
          await #expect(throws: SessionStoreError.parentUnavailableForCreation(root.rawValue)) {
            try await store.createSession(group: .shared, title: "late child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
          }
        }
        let independent = try await space.sessions.createSession(group: .shared, title: "independent", kind: .agent, createdBy: root.rawValue, model: .test)
        #expect(try await sessions.record(independent).parent == nil)
        gate.release()
        try await archive.value
        await #expect(throws: SessionStoreError.parentUnavailableForCreation(root.rawValue)) {
          try await space.sessions.createSession(group: .shared, title: "after archive", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
        }
        #expect(try await sessions.archiveSubtree(root).map(\.id) == [root])
      } catch {
        gate.release()
        archive.cancel()
        _ = await archive.result
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }

  @Test func refusedArchiveDoesNotConsumeCompactCommandDuringReservation() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let one = try await sessions.createSession(group: .shared, title: "one", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let two = try await sessions.createSession(group: .shared, title: "two", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let children = [one, two].sorted { $0.rawValue < $1.rawValue }
      let compact = children[0]
      let busy = children[1]
      try await sessions.requestCommand(compact, .compact(instructions: nil))
      _ = try await sessions.enqueue(busy, input: Fix.message("busy"))
      let pendingRead = Box(false)
      let busyRead = Box(false)
      let compactRan = Box(false)
      let pendingGate = Latch()
      let busyGate = Latch()
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: { request in
        guard request.sessionID == compact else { return try await Fix.hanging(request) }
        if request.mode == .forcedCompact {
          compactRan.withLock { $0 = true }
          return Fix.reply("folded", calls: [.init(id: "archive-compact", name: "compact", arguments: .object(["summary": .string("kept")]))])
        }
        return Fix.reply("done")
      })) { id in
        SessionRepo(sessions: sessions, id: id, queueHeadRead: { store, id in
          if id == busy, !busyRead.value {
            busyRead.withLock { $0 = true }
            await busyGate.wait(unless: { Task.isCancelled })
          }
          return try await store.queueHead(id)
        }, pendingCommandRead: { store, id in
          let command = try await store.pendingCommand(id)
          if id == compact, !pendingRead.value {
            pendingRead.withLock { $0 = true }
            await pendingGate.wait(unless: { Task.isCancelled })
          }
          return command
        })
      }
      try await service.wake(compact)
      let archive = Task {
        try await until("compact pending read held") { pendingRead.value }
        try await service.archive(root)
      }
      do {
        try await until("archive checked busy sibling after reserving compact session") { busyRead.value }
        #expect(sessions.isReservedForArchive(compact))
        pendingGate.release()
        try await holds("compact remains pending while reserved") {
          try await sessions.pendingCommand(compact) != nil && !compactRan.value
        }
        busyGate.release()
        await #expect(throws: SubtreeArchiveBusy.self) { try await archive.value }
        try await until("compact runs after refused archive releases reservation") { compactRan.value }
        #expect(try await sessions.pendingCommand(compact) == nil)
        #expect(try await sessions.record(compact).lifecycle == .live)
      } catch {
        pendingGate.release()
        busyGate.release()
        archive.cancel()
        _ = await archive.result
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }
}
