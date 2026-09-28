import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct SessionTreeTests {
  private func root(_ store: SessionStore, _ title: String = "root") async throws -> SessionID {
    try await store.createSession(group: .shared, title: title, kind: .agent, createdBy: "morgan", model: .test)
  }

  private func child(_ store: SessionStore, of parent: SessionID, kind: SessionKind = .task) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "child", kind: kind, parent: parent, createdBy: parent.rawValue, executor: .kernel(.test),
    )
  }

  @Test func `an agent child has a parent and a box`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await root(rig.store)
    let agent = try await child(rig.store, of: parent, kind: .agent)
    let record = try await rig.store.record(agent)
    #expect(record.kind == .agent)
    #expect(record.parent == parent)
    #expect(try await rig.store.conversation(ConversationID(agent.rawValue)).kind == .box)
  }

  @Test func `an agent child answers its parent's request like a task`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await root(rig.store)
    let agent = try await child(rig.store, of: parent, kind: .agent)
    let request = try await rig.store.openRequest(
      on: agent, from: parent, messageID: MessageID("r1"), text: "look into it", deadline: nil,
    )
    #expect(request.enqueued == [agent])
    _ = try await rig.store.drainQueue(agent)
    let final = try await rig.store.report(
      agent, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "done",
    )
    #expect(final.enqueued == [parent])
    _ = try await rig.store.drainQueue(agent)
    #expect(try await rig.store.settleState(agent).openRequests.isEmpty)
  }

  @Test func `a root cannot report`() async throws {
    let rig = try MovingClockSpace()
    let agent = try await root(rig.store)
    await #expect(throws: SessionStoreError.noParent(agent.rawValue)) {
      _ = try await rig.store.report(agent, request: RequestID("r1"), kind: .final, messageID: MessageID("f1"), text: "x")
    }
  }

  @Test func `a replayed request is the open one, not a second`() async throws {
    let rig = try MovingClockSpace()
    let parent = try await root(rig.store)
    let task = try await child(rig.store, of: parent)
    _ = try await rig.store.openRequest(on: task, from: parent, messageID: MessageID("r1"), text: "go", deadline: nil)
    _ = try await rig.store.drainQueue(task)
    let replay = try await rig.store.openRequest(
      on: task, from: parent, messageID: MessageID("r1"), text: "go", deadline: nil,
    )
    #expect(replay.replayed)
    await #expect(throws: SessionStoreError.requestAlreadyOpen("r1")) {
      _ = try await rig.store.openRequest(on: task, from: parent, messageID: MessageID("r2"), text: "go", deadline: nil)
    }
  }

  @Test func `a session at level 17 is refused`() async throws {
    let rig = try MovingClockSpace()
    var chain = [try await root(rig.store)]
    for _ in 2 ... SessionStore.depthLimit {
      chain.append(try await child(rig.store, of: chain.last!))
    }
    #expect(chain.count == 16)
    await #expect(throws: SessionStoreError.tooDeep(chain.last!.rawValue)) {
      _ = try await child(rig.store, of: chain.last!)
    }
    _ = try await child(rig.store, of: chain[chain.count - 2])
  }

  @Test func `creation takes a title the way set_title does`() async throws {
    let rig = try MovingClockSpace()
    let id = try await rig.store.createSession(group: .shared, title: "  Scout \n", kind: .agent, createdBy: "morgan", model: .test)
    #expect(try await rig.store.record(id).title == "Scout")
    for title in ["", "two\nlines", String(repeating: "x", count: SessionStore.titleLimit + 1)] {
      await #expect(throws: SessionStoreError.unusableTitle(title)) {
        _ = try await rig.store.createSession(group: .shared, title: title, kind: .agent, createdBy: "morgan", model: .test)
      }
    }
  }

  @Test func `tags are replaced whole, archived or not`() async throws {
    let rig = try MovingClockSpace()
    let id = try await rig.store.createSession(
      group: .shared,
      title: "coder", kind: .agent, tags: ["wuhu:1", "coder"], createdBy: "morgan", model: .test,
    )
    let before = try await rig.store.record(id).lastActivityAt
    try await rig.store.setTags(id, to: ["wuhu:13"])
    let retagged = try await rig.store.record(id)
    #expect(retagged.tags == ["wuhu:13"])
    #expect(retagged.lastActivityAt == before, "a retag is not activity")
    _ = try await rig.store.archive(id, grace: .seconds(60))
    try await rig.store.setTags(id, to: [])
    #expect(try await rig.store.record(id).tags == [])
    await #expect(throws: SessionStoreError.unknownSession("nobody-here-at-all")) {
      try await rig.store.setTags(SessionID("nobody-here-at-all"), to: ["x"])
    }
  }

  @Test func `a session controls itself and its descendants, nothing else`() async throws {
    let rig = try MovingClockSpace()
    let top = try await root(rig.store)
    let middle = try await child(rig.store, of: top, kind: .agent)
    let leaf = try await child(rig.store, of: middle)
    let other = try await root(rig.store, "other")
    for (actor, target) in [(leaf, leaf), (middle, leaf), (top, leaf), (top, middle)] {
      try await rig.store.refuseControl(of: target, by: actor)
    }
    for (actor, target) in [(leaf, middle), (middle, top), (other, leaf), (leaf, other)] {
      await #expect(throws: SessionStoreError.notInCharge(target.rawValue, actor: actor.rawValue)) {
        try await rig.store.refuseControl(of: target, by: actor)
      }
    }
  }
}
