import Foundation
import JSONValue
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import SessionDomain
@testable import SessionTools
import SpaceCore
import SystemFiles
import Testing
import struct WuhuAI.ToolArguments

private func key(_ id: SessionID) -> String { id.rawValue }

private let utc = TimeZone(identifier: "UTC")!

private func makeTask(_ space: Space, parent: SessionID, name: String = "task") async throws -> SessionID {
  try await space.sessions.createSession(
    group: .shared,
    title: name,
    kind: .task,
    parent: parent,
    createdBy: parent.rawValue,
    executor: .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
  )
}

struct MessagingTests {
  @Test func sendMessageWithNoTargetPostsIntoTheOwnBox() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space, name: "a"))

      let sent = try await world.run("send_message", .object(["message": .string("a note")]))
      guard case let .sendMessage(outcome) = sent else {
        throw Mismatch("expected a send outcome, got \(sent)")
      }
      #expect(outcome.conversationID == ConversationID(key(world.session)))
      #expect(try await space.sessions.messages(conversation: outcome.conversationID).count == 1)
      #expect(try await space.sessions.hydrate(world.session).undrained.isEmpty, "a post never wakes its poster")
    }
  }

  @Test func sendMessageToAnotherSessionIsAlwaysADM() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let a = try await makeSession(space, name: "a")
      let b = try await makeSession(space, name: "b")
      let task = try await makeTask(space, parent: a)
      var world = ToolWorld(executor: executor, session: a)

      let toAgent = try await world.run("send_message", .object([
        "message": .string("status?"), "session": .string(key(b)),
      ]))
      guard case let .sendMessage(agentPost) = toAgent else {
        throw Mismatch("expected a send outcome, got \(toAgent)")
      }
      #expect(agentPost.conversationID != ConversationID(key(b)))
      #expect(try await space.sessions.conversation(agentPost.conversationID).kind == .dmSession)
      #expect(try await space.sessions.hydrate(b).undrained.count == 1)
      #expect(
        try await space.sessions.messages(conversation: ConversationID(key(b))).isEmpty,
        "an agent's box is not a session-to-session channel",
      )

      let toTask = try await world.run("send_message", .object([
        "message": .string("how goes it"), "session": .string(key(task)),
      ]))
      guard case let .sendMessage(taskPost) = toTask else {
        throw Mismatch("expected a send outcome, got \(toTask)")
      }
      #expect(taskPost.conversationID != ConversationID(key(task)))
      let dm = try await space.sessions.conversation(taskPost.conversationID)
      #expect(dm.kind == .dmSession)
    }
  }

  @Test func sendMessageWantsAtMostOneTarget() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let a = try await makeSession(space, name: "a")
      var world = ToolWorld(executor: ToolExecutor(space: space), session: a)

      let both = try await world.run("send_message", .object([
        "message": .string("x"), "session": .string(key(a)), "conversation": .string(key(a)),
      ]))
      #expect(try failureMessage(both).contains("at most one"))

      let unknown = try await world.run("send_message", .object([
        "message": .string("x"), "session": .string("no-such-session"),
      ]))
      #expect(try failureMessage(unknown).contains("unknown session"))
    }
  }

  @Test func sendMessageAttachesSpaceAndMachineFilesByPath() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS()
      machineFS.put("/clips/demo.mp4", "not really a video", mtime: 1)
      let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      _ = try await space.fs(.shared).write("/shots/shot.png", Data(png), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: machineFS.seam), session: try await makeSession(space, name: "a"))

      let sent = try await world.run("send_message", .object([
        "message": .string("look"),
        "attachments": .array(["/shots/shot.png", .string("machines://\(machineA.rawValue)/clips/demo.mp4")]),
      ]))
      guard case let .sendMessage(outcome) = sent else {
        throw Mismatch("expected a send outcome, got \(sent)")
      }
      let message = try #require(try await space.sessions.messages(conversation: outcome.conversationID).first)
      let attachments = message.content.attachments
      let paths = attachments.map(\.path)
      #expect(attachments == [
        .image(path: paths[0], mimeType: "image/png", size: png.count),
        .file(path: paths[1], mimeType: "video/mp4", size: 18),
      ])
      #expect(paths.allSatisfy { $0.hasPrefix("/_/conversations/\(outcome.conversationID.rawValue)/attachments/") })
      #expect(try await space.fs(.shared).read(paths[1]).1 == Data("not really a video".utf8))
    }
  }

  @Test func sendMessageCopiesASystemFileIntoTheConversation() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space, name: "a"))
      let skill = try await SystemFiles.vfs.read("/skills/monitor/SKILL.md").1

      let sent = try await world.run("send_message", .object([
        "message": .string("read this"),
        "attachments": .array(["wuhu://system/skills/monitor/SKILL.md"]),
      ]))
      guard case let .sendMessage(outcome) = sent else {
        throw Mismatch("expected a send outcome, got \(sent)")
      }
      let message = try #require(try await space.sessions.messages(conversation: outcome.conversationID).first)
      #expect(message.content.attachments.count == 1)
      guard case let .file(path: path, mimeType: _, size: size)? = message.content.attachments.first else {
        throw Mismatch("expected a file attachment, got \(message.content.attachments)")
      }
      #expect(path.hasPrefix("/_/conversations/\(outcome.conversationID.rawValue)/attachments/"))
      #expect(path.hasSuffix("/SKILL.md"))
      #expect(size == skill.count)
      #expect(try await space.fs(.shared).read(path).1 == skill)
    }
  }

  @Test func aMachineFileOverOneReadFrameIsReadInRanges() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS()
      let frame = VFSDefaults.maxReadBytes
      let clip = (0 ..< 2 * frame + 3).map { UInt8(truncatingIfNeeded: $0) }
      machineFS.put("/clips/long.mp4", bytes: clip, mtime: 1)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: machineFS.seam), session: try await makeSession(space, name: "a"))

      let sent = try await world.run("send_message", .object([
        "message": .string("the long take"),
        "attachments": .array([.string("machines://\(machineA.rawValue)/clips/long.mp4")]),
      ]))
      guard case let .sendMessage(outcome) = sent else {
        throw Mismatch("expected a send outcome, got \(sent)")
      }
      let message = try #require(try await space.sessions.messages(conversation: outcome.conversationID).first)
      let path = try #require(message.content.attachments.first?.path)
      #expect(message.content.attachments == [.file(path: path, mimeType: "video/mp4", size: clip.count)])
      #expect(try await space.fs(.shared).read(path).1 == Data(clip))
      #expect(machineFS.reads.withLock { $0 } == [
        .read(path: "/clips/long.mp4", offset: 0, length: frame),
        .read(path: "/clips/long.mp4", offset: frame, length: frame),
        .read(path: "/clips/long.mp4", offset: 2 * frame, length: 3),
      ])
    }
  }

  @Test func anAgentBuiltBeforeRangedReadsIsToldToUpgradeForAFileOverOneFrame() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS(ranges: false)
      machineFS.put("/clips/long.mp4", bytes: Array(repeating: 1, count: VFSDefaults.maxReadBytes + 1), mtime: 1)
      machineFS.put("/clips/short.mp4", bytes: Array(repeating: 2, count: VFSDefaults.maxReadBytes), mtime: 1)
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: machineFS.seam), session: try await makeSession(space, name: "a"))

      let long = try await world.run("send_message", .object([
        "message": .string("x"), "attachments": .array([.string("machines://\(machineA.rawValue)/clips/long.mp4")]),
      ]))
      #expect(try failureMessage(long).contains("upgrade the machine agent"))

      let short = try await world.run("send_message", .object([
        "message": .string("x"), "attachments": .array([.string("machines://\(machineA.rawValue)/clips/short.mp4")]),
      ]))
      guard case .sendMessage = short else {
        throw Mismatch("expected a file within one frame to attach from an older agent, got \(short)")
      }
    }
  }

  @Test(arguments: [(3, 1), (4, 2)])
  func aFileThatShrankUnderAnOlderAgentWhileKeepingItsMtimeIsRefusedNotStitched(stat: Int, now: Int) async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS(ranges: false)
      let half = VFSDefaults.maxReadBytes / 2
      machineFS.put("/clips/take.mp4", bytes: Array(repeating: 1, count: stat * half), mtime: 1)
      machineFS.replacedAfterStat.withLock {
        $0["/clips/take.mp4"] = .init(mtime: 1, content: Array(repeating: 2, count: now * half))
      }
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: machineFS.seam), session: try await makeSession(space, name: "a"))

      let sent = try await world.run("send_message", .object([
        "message": .string("x"), "attachments": .array([.string("machines://\(machineA.rawValue)/clips/take.mp4")]),
      ]))
      #expect(try failureMessage(sent).contains("changed while it was being read"))
      #expect(try await space.sessions.messages(conversation: ConversationID(key(world.session))).isEmpty)
    }
  }

  @Test func sendMessageRefusesAttachmentsItCannotTakeBeforeReadingThem() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write("/a.txt", Data("a".utf8), ifMatch: nil)
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space, name: "a"))

      let nine = try await world.run("send_message", .object([
        "message": .string("x"), "attachments": .array(Array(repeating: "/a.txt", count: 9)),
      ]))
      #expect(try failureMessage(nine).contains("at most 8 attachments"))

      let missing = try await world.run("send_message", .object([
        "message": .string("x"), "attachments": .array(["/gone.txt"]),
      ]))
      #expect(try failureMessage(missing).contains("not a file in the space"))
      #expect(try await space.sessions.messages(conversation: ConversationID(key(world.session))).isEmpty)
    }
  }

  @Test func aDuplicateSendIsAbsorbedByItsReceipt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let a = try await makeSession(space, name: "a")
      let b = try await makeSession(space, name: "b")
      var world = ToolWorld(executor: executor, session: b)

      let arguments: ToolArguments = .object(["message": .string("hello"), "session": .string(key(a))])
      let first = try await world.run("send_message", arguments, id: "tc-post")
      let retried = try await world.retry("send_message", arguments, id: "tc-post")
      #expect(first == retried)
      guard case let .sendMessage(post) = first else {
        throw Mismatch("expected a send outcome, got \(first)")
      }
      #expect(try await space.sessions.messages(conversation: post.conversationID).count == 1)
      #expect(try await space.sessions.hydrate(a).undrained.count == 1)
    }
  }

  @Test func aDuplicateSendWhoseMachineFileIsGoneIsStillAbsorbedByItsReceipt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let machineFS = FakeMachineFS()
      machineFS.put("/clips/a.mp4", bytes: [1, 2, 3], mtime: 1)
      let a = try await makeSession(space, name: "a")
      let b = try await makeSession(space, name: "b")
      var world = ToolWorld(executor: ToolExecutor(space: space, machines: machineFS.seam), session: b)

      let arguments: ToolArguments = .object([
        "message": .string("the clip"), "session": .string(key(a)),
        "attachments": .array([.string("machines://\(machineA.rawValue)/clips/a.mp4")]),
      ])
      let first = try await world.run("send_message", arguments, id: "tc-clip")
      machineFS.files.withLock { $0["/clips/a.mp4"] = nil }
      machineFS.reads.withLock { $0 = [] }
      let retried = try await world.retry("send_message", arguments, id: "tc-clip")
      #expect(first == retried)
      #expect(machineFS.reads.withLock { $0 }.isEmpty)
      guard case let .sendMessage(post) = first else {
        throw Mismatch("expected a send outcome, got \(first)")
      }
      #expect(try await space.sessions.messages(conversation: post.conversationID).count == 1)
    }
  }

  @Test func replyTargetMustNameAMessageInTheSameConversation() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let a = try await makeSession(space, name: "a")
      let b = try await makeSession(space, name: "b")
      var world = ToolWorld(executor: executor, session: a)

      _ = try await space.sessions.post(
        .box(b), messageID: MessageID("elsewhere"),
        sender: .init(id: "morgan", timeZone: utc), content: .init(text: "over there"),
      )
      let foreign = try await world.run("send_message", .object([
        "message": .string("x"), "reply_target": .string("elsewhere"),
      ]))
      #expect(try failureMessage(foreign).contains("another conversation"))

      let unknown = try await world.run("send_message", .object([
        "message": .string("x"), "reply_target": .string("nope"),
      ]))
      #expect(try failureMessage(unknown).contains("unknown message"))
    }
  }

  @Test func requestOpensOneDutyAndRefusesASecond() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let parent = try await makeSession(space, name: "parent")
      let task = try await makeTask(space, parent: parent)
      var world = ToolWorld(executor: executor, session: parent)

      let opened = try await world.run("request", .object([
        "task": .string(key(task)), "message": .string("do the thing"),
      ]))
      guard case let .request(outcome) = opened else {
        throw Mismatch("expected a request outcome, got \(opened)")
      }
      #expect(outcome.task == task)
      _ = try await space.sessions.drainQueue(task)

      let second = try await world.run("request", .object([
        "task": .string(key(task)), "message": .string("and another"),
      ]))
      #expect(try failureMessage(second).contains("still open"))
    }
  }

  @Test func onlyTheCreatorMayRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let parent = try await makeSession(space, name: "parent")
      let stranger = try await makeSession(space, name: "stranger")
      let task = try await makeTask(space, parent: parent)
      var world = ToolWorld(executor: executor, session: stranger)

      let refused = try await world.run("request", .object([
        "task": .string(key(task)), "message": .string("do the thing"),
      ]))
      #expect(try failureMessage(refused).contains("only the parent"))
    }
  }

  @Test func reportProgressKeepsTheRequestOpenAndFinalClosesIt() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let parent = try await makeSession(space, name: "parent")
      let task = try await makeTask(space, parent: parent)
      var parentWorld = ToolWorld(executor: executor, session: parent)
      var taskWorld = ToolWorld(executor: executor, session: task)

      let opened = try await parentWorld.run("request", .object([
        "task": .string(key(task)), "message": .string("do the thing"),
      ]))
      guard case let .request(request) = opened else {
        throw Mismatch("expected a request outcome, got \(opened)")
      }
      _ = try await space.sessions.drainQueue(task)

      let progress = try await taskWorld.run("report", .object([
        "request_id": .string(request.requestID.rawValue),
        "kind": .string("progress"),
        "content": .string("halfway"),
      ]))
      guard case let .report(reported) = progress else {
        throw Mismatch("expected a report outcome, got \(progress)")
      }
      #expect(reported.kind == .progress)
      #expect(try await space.sessions.settleState(task).openRequests.count == 1)

      let final = try await taskWorld.run("report", .object([
        "request_id": .string(request.requestID.rawValue),
        "kind": .string("final"),
        "content": .string("done"),
      ]))
      guard case .report = final else {
        throw Mismatch("expected a report outcome, got \(final)")
      }
      #expect(try await space.sessions.settleState(task).openRequests.isEmpty)
      #expect(try await space.sessions.hydrate(parent).undrained.count == 2)
    }
  }

  @Test func reportValidatesItsKindAndRequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space)
      let parent = try await makeSession(space, name: "parent")
      let task = try await makeTask(space, parent: parent)
      var world = ToolWorld(executor: executor, session: task)

      let badKind = try await world.run("report", .object([
        "request_id": .string("r1"), "kind": .string("sideways"), "content": .string("x"),
      ]))
      #expect(try failureMessage(badKind).contains("progress or final"))

      let unknown = try await world.run("report", .object([
        "request_id": .string("r1"), "kind": .string("final"), "content": .string("x"),
      ]))
      #expect(try failureMessage(unknown).contains("no open request"))
    }
  }

  @Test func createSessionMintsATaskAndExpectsReplyOpensARequest() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space, resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "high"))
      })
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: executor, session: parent)

      let detached = try await world.run("create_session", .object([
        "title": .string("scout"), "provider": .string("deepseek"), "model": .string("deepseek-v4-pro"),
      ]))
      guard case let .createSession(plain) = detached else {
        throw Mismatch("expected a create outcome, got \(detached)")
      }
      #expect(plain.requestID == nil)
      let record = try await space.sessions.record(plain.sessionID)
      #expect(record.kind == .task)
      #expect(record.parent == parent)

      let briefed = try await world.run("create_session", .object([
        "title": .string("worker"),
        "provider": .string("deepseek"),
        "model": .string("deepseek-v4-pro"),
        "expects_reply": .bool(true),
        "message": .string("go do it"),
      ]))
      guard case let .createSession(withRequest) = briefed else {
        throw Mismatch("expected a create outcome, got \(briefed)")
      }
      let request = try #require(withRequest.requestID)
      _ = try await space.sessions.drainQueue(withRequest.sessionID)
      #expect(try await space.sessions.settleState(withRequest.sessionID).openRequests[request] != nil)

      let missingMessage = try await world.run("create_session", .object([
        "title": .string("nope"),
        "provider": .string("deepseek"),
        "model": .string("deepseek-v4-pro"),
        "expects_reply": .bool(true),
      ]))
      #expect(try failureMessage(missingMessage).contains("wants a message"))
    }
  }

  @Test func createSessionDefaultsToTheCallersModelAndExplicitFieldsWin() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let executor = ToolExecutor(space: space, resolveModelExecutor: { provider, model, effort in
        .kernel(ModelSpecifier(provider: provider, model: model, effort: effort ?? "medium"))
      })
      let parent = try await makeSession(space, name: "parent")
      var world = ToolWorld(executor: executor, session: parent)

      let inherited = try await world.run("create_session", .object(["title": "same as me"]))
      guard case let .createSession(child) = inherited else {
        throw Mismatch("expected a create outcome, got \(inherited)")
      }
      #expect(
        try await space.sessions.record(child.sessionID).executor
          == .kernel(.init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")),
      )

      let partial = try await world.run("create_session", .object(["title": "faster", "model": "deepseek-v4-flash"]))
      guard case let .createSession(flash) = partial else {
        throw Mismatch("expected a create outcome, got \(partial)")
      }
      #expect(
        try await space.sessions.record(flash.sessionID).executor
          == .kernel(.init(provider: "deepseek", model: "deepseek-v4-flash", effort: "high")),
      )

      let explicit = try await world.run("create_session", .object([
        "title": "elsewhere", "provider": "openai", "model": "gpt-5.6-luna", "effort": "low",
      ]))
      guard case let .createSession(luna) = explicit else {
        throw Mismatch("expected a create outcome, got \(explicit)")
      }
      #expect(
        try await space.sessions.record(luna.sessionID).executor
          == .kernel(.init(provider: "openai", model: "gpt-5.6-luna", effort: "low")),
      )

      let crossed = try await world.run("create_session", .object(["title": "nope", "provider": "openai"]))
      #expect(
        try failureMessage(crossed).contains("a session wants provider and model"),
        "another provider inherits no model",
      )
    }
  }
}
