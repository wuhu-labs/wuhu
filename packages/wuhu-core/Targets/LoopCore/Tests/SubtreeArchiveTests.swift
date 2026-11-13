import Foundation
@testable import LoopCore
import struct MainHub.ArchiveBusySession
import class MainHub.Hub
import struct MainHub.SubtreeArchiveBusy
import SessionDomain
import SessionTools
import SpaceCore
import Testing

@Suite struct SubtreeArchiveTests {
  @Test func refusalNamesEveryBusyDescendantAndForceArchivesThemAll() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
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
      try await sessions.enqueue(leaf, input: Fix.message("queued"))
      try await sessions.enqueue(sibling, input: Fix.message("queued", message: "sibling"))
      try await runService(space, makeConfig(inference: Fix.hanging)) { service in
        do {
          try await service.archive(root)
          Issue.record("busy subtree was archived")
        } catch let error as SubtreeArchiveBusy {
          #expect(Set(error.sessions.map(\.id)) == Set([leaf, sibling]))
          #expect(error.message.contains("\(leaf.rawValue) (busy leaf)"))
          #expect(error.message.contains("\(sibling.rawValue) (busy sibling)"))
        }
        for id in [root, child, leaf, sibling] { #expect(try await sessions.record(id).lifecycle == .live) }
        try await service.archive(root, force: true)
        try await until("subtree archived") {
          for id in [root, child, leaf, sibling] where try await !sessions.record(id).lifecycle.isArchived { return false }
          return true
        }
        #expect(try await sessions.record(topLevel).lifecycle == .live)
        try await service.unarchive(root)
        try await until("root unarchived") { try await sessions.record(root).lifecycle == .live }
        #expect(try await sessions.record(child).lifecycle.isArchived)
      }
    }
  }

  @Test func forceStopsARunningKernelLeaf() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
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
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("start"), to: leaf)
        try await until("leaf running") { entered.value }
        await #expect(throws: SubtreeArchiveBusy(sessions: [ArchiveBusySession(id: leaf, title: "running leaf")])) {
          try await service.archive(root)
        }
        for id in [root, child, leaf] { #expect(try await sessions.record(id).lifecycle == .live) }
        try await service.archive(root, force: true)
        try await until("subtree archived") {
          for id in [root, child, leaf] where try await !sessions.record(id).lifecycle.isArchived { return false }
          return true
        }
      }
    }
  }

  @Test func forceClosesQueuedRequestsAndDeliversFinalsOutsideTheSubtree() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let requester = try await createRetiredSession(in: space, title: "requester", createdBy: "owner")
      let root = try await sessions.createSession(group: .shared, title: "root", kind: .task, parent: requester, createdBy: requester.rawValue, executor: .kernel(.test))
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: root, createdBy: root.rawValue, executor: .kernel(.test))
      let rootRequest = MessageID("root-request")
      let childRequest = MessageID("child-request")
      let rootDelivery = try await sessions.openRequest(on: root, from: .session(requester), messageID: rootRequest, text: "work")
      let childDelivery = try await sessions.openRequest(on: child, from: .session(root), messageID: childRequest, text: "work")
      try await sessions.markInterrupted(root)
      try await sessions.markInterrupted(child)
      let service = SessionExecution(space: space, loopConfig: makeConfig())
      service.start()
      do {
        try await service.archive(root, force: true)
        for (id, delivery, request) in [(root, rootDelivery, rootRequest), (child, childDelivery, childRequest)] {
          let messages = try await sessions.messages(conversation: delivery.message.conversation)
          let final = try #require(messages.first { $0.kind == .final })
          #expect(final.requestID == RequestID(request.rawValue))
          #expect(final.senderSession == id)
          #expect(final.content.text.contains("archived before reporting"))
          #expect(try sessions.openRequests(id).isEmpty)
          _ = try await sessions.drainQueue(id)
          #expect(try sessions.openRequests(id).isEmpty)
        }
        #expect(try await sessions.record(requester).lifecycle == .live)
        try await until("the final reaches the requester") {
          try await sessions.undrainedInputs(requester).contains { entry in
            guard case let .message(message) = entry.input else { return false }
            return message.kind == .final && message.requestID == RequestID(rootRequest.rawValue)
          }
        }
        #expect(try await sessions.armedSubscriptions(requester).isEmpty)
        #expect(try await sessions.armedSubscriptions(root).isEmpty)
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }

  @Test func aPlainArchiveOfAStoppedChildFailsItsOpenRequest() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let requester = try await createRetiredSession(in: space, title: "requester", createdBy: "owner")
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: requester, createdBy: requester.rawValue, executor: .kernel(.test))
      let delivery = try await sessions.openRequest(on: child, from: .session(requester), messageID: MessageID("r1"), text: "work")
      try await sessions.markInterrupted(child)
      let service = SessionExecution(space: space, loopConfig: makeConfig())
      service.start()
      do {
        try await service.archive(child)
        let messages = try await sessions.messages(conversation: delivery.message.conversation)
        #expect(messages.contains { $0.kind == .final && $0.requestID == RequestID("r1") })
        let rows = try await space.query("SELECT status FROM requests WHERE id = 'r1'", as: .shared(.anonymous))
        #expect(rows.rows == [[.text("failed")]])
      } catch {
        await service.shutdown()
        throw error
      }
      await service.shutdown()
    }
  }
}

extension SubtreeArchiveTests {
  @Test func aParentArchivedWithARequestOpenOnItsChildIsNotStartedOnTheFailure() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let parent = try await sessions.createSession(group: .shared, title: "parent", kind: .agent, createdBy: "owner", model: .test)
      let child = try await sessions.createSession(group: .shared, title: "child", kind: .task, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test))
      _ = try await sessions.openRequest(on: child, from: .session(parent), messageID: MessageID("r1"), text: "work")
      try await sessions.markInterrupted(child)
      try await runService(space, makeConfig(inference: Fix.hanging)) { service in
        try await service.archive(parent)
        try await until("both archived") {
          for id in [parent, child] where try await !sessions.record(id).lifecycle.isArchived { return false }
          return true
        }
        #expect(try await sessions.record(parent).hold == .normal)
      }
    }
  }
}

private extension SessionLifecycle {
  var isArchived: Bool {
    if case .archived = self { true } else { false }
  }
}
