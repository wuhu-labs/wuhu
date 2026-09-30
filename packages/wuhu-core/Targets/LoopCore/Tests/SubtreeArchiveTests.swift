import Foundation
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

@Suite struct SubtreeArchiveTests {
  @Test func forceIncludesAChildCreatedByAToolAlreadyInFlight() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let entered = Box(false)
      let lateChild = Box<SessionID?>(nil)
      let config = makeConfig(inference: { _ in
        entered.withLock { $0 = true }
        do {
          try await ContinuousClock().sleep(for: .seconds(3600))
        } catch is CancellationError {
          let child = try await Task {
            let child = try await sessions.createSession(group: .shared, title: "late child", kind: .task, parent: root, createdBy: root.rawValue, executor: .contractor(name: "retired"))
            _ = try await sessions.enqueue(child, input: Fix.message("late work"))
            return child
          }.value
          lateChild.withLock { $0 = child }
          throw CancellationError()
        }
        throw UnexpectedCall("inference survived interruption")
      })
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("start"), to: root)
        try await until("root running") { entered.value }
        try await service.archive(root, force: true)
        let child = try #require(lateChild.value)
        #expect(try await sessions.record(root).lifecycle.isArchived)
        #expect(try await sessions.record(child).lifecycle.isArchived)
      }
    }
  }

  @Test func concurrentOverlappingArchivesFinishWithoutStrandingAReservation() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig())
      do {
        async let one: Void = service.archive(root)
        async let two: Void = service.archive(child)
        _ = try await (one, two)
        #expect(try await sessions.record(root).lifecycle.isArchived)
        #expect(try await sessions.record(child).lifecycle.isArchived)
        try await service.unarchive(child)
        #expect(try await sessions.record(child).lifecycle == .live)
      } catch {
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }

  @Test func refusalNamesEveryBusyDescendantAndForceArchivesLeavesFirst() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let child = try await sessions.createSession(
        group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test),
      )
      let leaf = try await sessions.createSession(
        group: .shared, title: "busy leaf", kind: .task, parent: child, createdBy: child.rawValue, executor: .kernel(.test),
      )
      let sibling = try await sessions.createSession(
        group: .shared, title: "busy sibling", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test),
      )
      let topLevel = try await sessions.createSession(group: .shared, title: "top level", kind: .agent, createdBy: child.rawValue, model: .test)
      _ = try await sessions.enqueue(leaf, input: Fix.message("queued"))
      _ = try await sessions.enqueue(sibling, input: Fix.message("queued", message: "sibling"))
      let writes = Box<[SessionID]>([])
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig(inference: Fix.hanging)) { id in
        SessionRepo(sessions: sessions, id: id, archiveWrite: { store, id, grace in
          if id == child { #expect(try await store.record(leaf).lifecycle.isArchived) }
          if id == root {
            for descendant in [child, leaf, sibling] { #expect(try await store.record(descendant).lifecycle.isArchived) }
          }
          #expect(try await store.record(root).lifecycle == .live)
          writes.withLock { $0.append(id) }
          return try await store.archive(id, grace: grace)
        })
      }
      do {
        do {
          try await service.archive(root)
          Issue.record("busy subtree was archived")
        } catch let error as SubtreeArchiveBusy {
          #expect(Set(error.sessions.map(\.id)) == Set([leaf, sibling]))
          #expect(error.message.contains("\(leaf.rawValue) (busy leaf)"))
          #expect(error.message.contains("\(sibling.rawValue) (busy sibling)"))
        }
        #expect(writes.value.isEmpty)
        for id in [root, child, leaf, sibling] { #expect(try await sessions.record(id).lifecycle == .live) }
        try await service.archive(root, force: true)
        for id in [root, child, leaf, sibling] { #expect(try await sessions.record(id).lifecycle.isArchived) }
        #expect(writes.value == (try await sessions.archiveSubtree(root)).map(\.id))
        #expect(try await sessions.record(leaf).hold == .interrupted)
        #expect(try await sessions.record(sibling).hold == .interrupted)
        #expect(try await sessions.record(topLevel).lifecycle == .live)
        try await service.archive(root, force: true)
        #expect(writes.value == (try await sessions.archiveSubtree(root)).map(\.id))
        try await service.unarchive(root)
        #expect(try await sessions.record(root).lifecycle == .live)
        #expect(try await sessions.record(child).lifecycle.isArchived)
      } catch {
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }

  @Test func forceInterruptsARunningKernelLeaf() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .agent, createdBy: "owner", model: .test)
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let leaf = try await sessions.createSession(group: .shared, title: "running leaf", kind: .task, parent: child, createdBy: child.rawValue, executor: .kernel(.test))
      let entered = Box(false)
      let gate = Latch()
      let config = makeConfig(inference: { _ in
        entered.withLock { $0 = true }
        await gate.wait(unless: { Task.isCancelled })
        try Task.checkCancellation()
        throw UnexpectedCall("inference survived interruption")
      })
      try await runService(sessions, config) { service in
        _ = try await service.enqueue(item: Fix.message("start"), to: leaf)
        try await until("leaf running") { entered.value }
        await #expect(throws: SubtreeArchiveBusy(sessions: [ArchiveBusySession(id: leaf, title: "running leaf")])) {
          try await service.archive(root)
        }
        for id in [root, child, leaf] { #expect(try await sessions.record(id).lifecycle == .live) }
        try await service.archive(root, force: true)
        for id in [root, child, leaf] { #expect(try await sessions.record(id).lifecycle.isArchived) }
        #expect(try await sessions.record(leaf).hold == .interrupted)
      }
    }
  }

  @Test func forceClosesQueuedRequestsAndDeliversFinalsOutsideTheSubtree() async throws {
    try await withKernelDeps { _ in
      let sessions = try Space.inMemory().sessions
      let requester = try await sessions.createSession(group: .shared, title: "requester", kind: .agent, createdBy: "owner", executor: .contractor(name: "retired"))
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .task, parent: requester, createdBy: requester.rawValue, executor: .kernel(.test))
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let rootRequest = MessageID("root-request")
      let childRequest = MessageID("child-request")
      let rootDelivery = try await sessions.openRequest(on: root, from: requester, messageID: rootRequest, text: "work", deadline: anchor.addingTimeInterval(60))
      let childDelivery = try await sessions.openRequest(on: child, from: root, messageID: childRequest, text: "work", deadline: anchor.addingTimeInterval(60))
      try await sessions.markInterrupted(root)
      try await sessions.markInterrupted(child)
      let service = await SessionService(sessions: sessions, loopConfig: makeConfig())
      do {
        try await service.archive(root, force: true)
        for (id, delivery, request) in [(root, rootDelivery, rootRequest), (child, childDelivery, childRequest)] {
          let messages = try await sessions.messages(conversation: delivery.message.conversation)
          let final = try #require(messages.first { $0.kind == .final })
          #expect(final.requestID == RequestID(request.rawValue))
          #expect(final.senderSession == id)
          #expect(final.content.text.contains("archived before reporting"))
          #expect(try await sessions.settleState(id).openRequests.isEmpty)
          _ = try await sessions.drainQueue(id)
          #expect(try await sessions.settleState(id).openRequests.isEmpty)
        }
        #expect(try await sessions.record(requester).lifecycle == .live)
        #expect(try await sessions.hydrate(requester).undrained.contains { entry in
          guard case let .message(message) = entry.input else { return false }
          return message.kind == .final && message.requestID == RequestID(rootRequest.rawValue)
        })
        #expect(try await sessions.armedSubscriptions(requester).isEmpty)
        #expect(try await sessions.armedSubscriptions(root).isEmpty)
      } catch {
        await service.registry.stop()
        throw error
      }
      await service.registry.stop()
    }
  }
}

private extension SessionLifecycle {
  var isArchived: Bool {
    if case .archived = self { true } else { false }
  }
}
