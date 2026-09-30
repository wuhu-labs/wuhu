import Foundation
import GRDB
import JSONValue
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing
import struct WuhuAI.ToolArguments

// P is a top-level agent in alice, which reads shared; S one in shared; B one
// in bob, which reads nothing else.
@Suite struct GroupToolTests {
  struct Rig {
    let space: Space
    let executor: ToolExecutor
    let p: SessionID
    let s: SessionID
    let b: SessionID
  }

  static let alice = GroupID(rawValue: "alice")
  static let bob = GroupID(rawValue: "bob")

  func makeRig() async throws -> Rig {
    let space = try Space.inMemory()
    try await space.writer.write { db in
      for group in [Self.alice, Self.bob] {
        try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES (?, '2026-01-01T00:00:00.000Z')", arguments: [group.rawValue])
      }
    }
    try await space.addEdge(src: Self.alice, dst: .shared, kind: .read, by: nil)
    return Rig(
      space: space,
      executor: ToolExecutor(space: space),
      p: try await makeSession(space, name: "P", group: Self.alice),
      s: try await makeSession(space, name: "S"),
      b: try await makeSession(space, name: "B", group: Self.bob),
    )
  }

  func task(_ rig: Rig, of parent: SessionID, in group: GroupID) async throws -> SessionID {
    try await rig.space.sessions.createSession(
      group: group, title: "task", kind: .task, parent: parent, createdBy: parent.rawValue,
      executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
    )
  }

  func write(_ rig: Rig, as session: SessionID, _ path: String) async throws -> ToolResultPayload {
    var world = ToolWorld(executor: rig.executor, session: session)
    return try await world.run("write", .object(["path": .string(path), "content": "rules"]))
  }

  @Test func theWriteToolKeepsTheLayerRules() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      let t = try await task(rig, of: rig.p, in: Self.alice)
      guard case .write = try await write(rig, as: t, "/AGENTS.md") else {
        throw Mismatch("a task writes its own group's layer")
      }
      #expect(try await rig.space.fs(Self.alice).read("/AGENTS.md").1 == Data("rules".utf8))

      let st = try await task(rig, of: rig.s, in: .shared)
      let refused = try failureMessage(try await write(rig, as: st, "/AGENTS.md"))
      #expect(refused == "unauthorized: /AGENTS.md is part of the space-wide layer; only an admin of shared writes it (ask a top-level agent or a human admin of shared to make the change)")

      let foreign = try failureMessage(try await write(rig, as: rig.b, "wuhu://alice.localspace/AGENTS.md"))
      #expect(foreign.hasPrefix("notFound: "))
    }
  }

  @Test func sendMessageToASessionInAnUnreadGroupIsAnUnknownSession() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      var world = ToolWorld(executor: rig.executor, session: rig.s)
      let sent = try await world.run("send_message", .object(["message": "hi", "session": .string(rig.p.rawValue)]))
      #expect(try failureMessage(sent) == "unknown session: \(rig.p.rawValue)")
      let missing = try await world.run("send_message", .object(["message": "hi", "session": "no-such-session"]))
      #expect(try failureMessage(missing) == "unknown session: no-such-session")
    }
  }

  @Test func aDMsMemberReadsItsAttachmentsInAGroupItDoesNotRead() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      _ = try await write(rig, as: rig.p, "/note.md")
      var p = ToolWorld(executor: rig.executor, session: rig.p)
      let sent = try await p.run("send_message", .object([
        "message": "see", "session": .string(rig.s.rawValue), "attachments": ["/note.md"],
      ]))
      guard case let .sendMessage(receipt) = sent else { throw Mismatch("send_message failed: \(sent)") }
      #expect(try await rig.space.sessions.conversation(receipt.conversationID).group == Self.alice)
      let stored = try #require(try await rig.space.sessions.message(receipt.messageID)?.content.attachments.first?.path)
      #expect(try await rig.space.fs(Self.alice).read(stored).1 == Data("rules".utf8))
      let delivered = try #require(try await rig.space.sessions.undrainedInputs(rig.s).compactMap {
        if case let .message(message) = $0.input { message.content.attachments.first?.path } else { nil }
      }.last)
      #expect(delivered == "wuhu://alice.localspace" + stored)

      var s = ToolWorld(executor: rig.executor, session: rig.s)
      guard case let .read(read) = try await s.run("read", .object(["path": .string(delivered)])) else {
        throw Mismatch("a DM member reads its attachment")
      }
      #expect(read.content.contains("rules"))
      guard case .sendMessage = try await s.run("send_message", .object([
        "message": "back", "session": .string(rig.p.rawValue), "attachments": .array([.string(delivered)]),
      ])) else { throw Mismatch("a DM member re-attaches its attachment") }

      var b = ToolWorld(executor: rig.executor, session: rig.b)
      #expect(try failureMessage(try await b.run("read", .object(["path": .string(delivered)]))).hasPrefix("notFound: "))
      #expect(try failureMessage(try await s.run("read", .object(["path": "wuhu://alice.localspace/note.md"]))).hasPrefix("notFound: "))
    }
  }

  @Test func manipulateUIIsForTopLevelAgentsOnly() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      let t = try await task(rig, of: rig.p, in: Self.alice)
      let child = try await rig.space.sessions.createSession(
        group: Self.alice, title: "child", kind: .agent, parent: rig.p, createdBy: rig.p.rawValue,
        executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )
      let arguments: ToolArguments = .object(["device": "no-such-device", "payload": .object(["sidebar": "everything"])])
      for session in [t, child] {
        var world = ToolWorld(executor: rig.executor, session: session)
        #expect(
          try failureMessage(try await world.run("manipulate_ui", arguments))
            == "manipulate_ui is for top-level agents; a task or child agent may not drive a device",
        )
      }
      for session in [rig.p, rig.s] {
        var world = ToolWorld(executor: rig.executor, session: session)
        #expect(try failureMessage(try await world.run("manipulate_ui", arguments)).hasPrefix("unknown device: no-such-device"))
      }
    }
  }

  @Test func aMachineIsUsableOnlyFromAGroupThatReadsItsGroup() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      let hers = try await rig.space.addMachine(name: "hers", group: Self.alice)
      _ = try await rig.space.addMachine(name: "common")
      let machineFS = FakeMachineFS()
      machineFS.attached.withLock { $0 = [hers.id] }
      machineFS.put("/x.txt", "hi", mtime: 1)
      let executor = ToolExecutor(space: rig.space, machines: machineFS.seam)

      func roster(_ session: SessionID) async throws -> [String] {
        var world = ToolWorld(executor: executor, session: session)
        guard case let .machines(result) = try await world.run("machines", .object([:])) else {
          throw Mismatch("machines failed")
        }
        return result.machines.compactMap(\.name).sorted()
      }
      #expect(try await roster(rig.p) == ["common", "hers"])
      #expect(try await roster(rig.s) == ["common"])
      #expect(try await roster(rig.b) == [])

      var s = ToolWorld(executor: executor, session: rig.s)
      #expect(try failureMessage(try await s.run("read", .object(["path": "machines://hers/x.txt"]))) == "unknown machine: hers")
      var p = ToolWorld(executor: executor, session: rig.p)
      let read = try await p.run("read", .object(["path": "machines://hers/x.txt"]))
      if case let .failure(failure) = read { Issue.record("P reads its own group's machine: \(failure.message)") }
    }
  }

  @Test func archiveIsForTheSessionItsCreatorAndAdminsButForceCannotArchiveSelf() async throws {
    try await withToolDeps { _ in
      let rig = try await makeRig()
      let performed = Box<[SessionID]>([])
      let executor = ToolExecutor(space: rig.space, control: SessionControl { _, id, _ in performed.withLock { $0.append(id) } })
      let st = try await task(rig, of: rig.s, in: .shared)
      let other = try await makeSession(rig.space, name: "S2")
      let theirs = try await task(rig, of: other, in: .shared)

      try await executor.control(.archive, rig.s, of: theirs)
      for (caller, target) in [(st, rig.s), (rig.p, rig.s), (st, theirs)] {
        do {
          try await executor.control(.archive, caller, of: target)
          Issue.record("\(caller.rawValue) archived \(target.rawValue)")
        } catch let problem as ToolProblem {
          #expect(problem.message == "\(caller.rawValue) may not archive or unarchive session \(target.rawValue): only the session itself, its creator and admins of its group may")
        }
      }
      do {
        try await executor.control(.archive, st, of: st, force: true)
        Issue.record("script force-archived itself")
      } catch let problem as ToolProblem {
        #expect(problem.message.contains("can't force-archive itself"))
      }
      try await executor.control(.archive, st, of: st)
      try await executor.control(.unarchive, st, of: st)
      #expect(performed.value == [theirs, st, st])
    }
  }
}
