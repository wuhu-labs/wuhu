import ControlledTime
import Dependencies
import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.MachineID
import func MainHub.execHandle
import class MainHub.Hub
import OrderedCollections
import SessionDomain
@testable import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolArguments

/// An exec that outlives its call: `running` past the wait or a message's
/// grace, one message at its end, cancel, and a restart that rejoins it.
@Suite(.timeLimit(.minutes(2))) struct ExecJobTests {
  @Test func pastItsWaitAnExecReturnsRunningAndItsEndArrivesAsOneMessage() async throws {
    try await withToolDeps { time in
      let ackGate = Gate()
      let ackEntered = Box(false)
      let ackFinished = Box(false)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in
        ackEntered.withLock { $0 = true }
        await ackGate.wait()
        ackFinished.withLock { $0 = true }
      })
      var rig = try await ExecJobRig(scripted: scripted)
      let space = rig.space
      let (released, release) = AsyncStream<Void>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            for await _ in released { break }
            try? await exec.send(.stdout, Array("done\n".utf8))
            try? await space.finishExec(exec.start.id, .exited(code: 3))
            await exec.exit(.exited(code: 3))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        let result = try await rig.exec(["wait_seconds": 5], id: "tc-long")
        let handle = try await rig.handle(of: "tc-long")
        #expect(result.output.hasPrefix(#"{"status":"running","id":"\#(handle)","tail":"#))
        #expect(result.output.hasSuffix(#""note":"still running after 5 s; its end arrives as one message, and cancel(\"\#(handle)\") kills it"}"#))
        #expect(rig.owner.runningExecJobs(of: rig.session) == [handle])
        #expect(try await rig.execMessages().isEmpty)

        release.yield(())
        try await until("the end arrives as a message") { try await rig.execMessages().count == 1 }
        #expect(try await rig.execMessages() == ["\(handle) ended with exit code 3:\nworking\ndone\n"])
        try await until("the job is forgotten") { try await rig.space.sessions.execJobs().isEmpty }
        #expect(rig.owner.runningExecJobs(of: rig.session).isEmpty)
        try await until("terminal acknowledgement is held") { ackEntered.value }
        guard case let .failure(ended) = try await rig.world.run("cancel", .object(["id": .string(handle)])) else {
          throw Mismatch("an ended exec accepted cancel while its terminal ack was held")
        }
        #expect(ended.code == "alreadyEnded")
        #expect(scripted.kills.value.isEmpty)
        await rig.owner.closeExecJobs()
        #expect(ackFinished.value, "shutdown joins terminal-ack transport even after the job is forgotten")
        let restarted = try ExecJobRig(after: rig)
        await restarted.owner.adoptExecJobs()
        #expect(restarted.owner.runningExecJobs(of: restarted.session).isEmpty)
        #expect(try await restarted.execMessages().count == 1)
        #expect(scripted.startCount.value == 1)
      }
    }
  }

  @Test func aMessageArrivingDuringTheWaitReturnsRunningEarly() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      let (released, release) = AsyncStream<Void>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            for await _ in released { break }
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        _ = try await rig.space.sessions.post(
          .box(rig.session), messageID: MessageID("m1"), sender: Sender(id: "carol", timeZone: TimeZone(identifier: "UTC")!),
          content: .init(text: "are you there?"),
        )
        let result = try await rig.exec(["wait_seconds": 1800, "max_lifetime_seconds": 3600], id: "tc-grace")
        let handle = try await rig.handle(of: "tc-grace")
        #expect(result.output.hasSuffix(#""note":"a message arrived, so the call gave the turn back; still running; its end arrives as one message, and cancel(\"\#(handle)\") kills it"}"#))
        #expect(rig.owner.runningExecJobs(of: rig.session) == [handle])

        release.yield(())
        try await until("the end arrives as a message") { try await rig.execMessages().count == 1 }
      }
    }
  }

  @Test func aPersonsMessageEndsTheWaitTenSecondsAfterItArrives() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      _ = try await rig.space.sessions.post(
        .box(rig.session), messageID: MessageID("m1"), sender: Sender(id: "carol", timeZone: TimeZone(identifier: "UTC")!),
        content: .init(text: "are you there?"),
      )
      let note = try await rig.waitCut(time, at: 10, id: "tc-direct")
      #expect(note.contains(#""note":"a message arrived, so the call gave the turn back; still running"#))
    }
  }

  @Test func aTimerFiringEndsTheWaitNinetySecondsAfterItArrives() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      @Dependency(\.date) var date
      _ = try await rig.space.sessions.enqueue(rig.session, input: .notification(SystemNotification(
        id: UUID(), timestamp: date.now, kind: .timer, subscriptionID: SubscriptionID("timer.tc-0"), content: .init(text: "tick"),
      )))
      let note = try await rig.waitCut(time, at: 90, id: "tc-timer")
      #expect(note.contains(#""note":"a message arrived, so the call gave the turn back; still running"#))
    }
  }

  @Test func anExecThatEndsWithinTheGraceIsTheCallsResult() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      let (released, release) = AsyncStream<Void>.makeStream()
      _ = try await rig.space.sessions.post(
        .box(rig.session), messageID: MessageID("m1"), sender: Sender(id: "carol", timeZone: TimeZone(identifier: "UTC")!),
        content: .init(text: "are you there?"),
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            for await _ in released { break }
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask {
          await time.advance(by: 5)
          try? await ContinuousClock().sleep(for: .milliseconds(300))
          release.yield(())
        }
        defer { group.cancelAll() }

        let result = try await rig.exec(["wait_seconds": 1800, "max_lifetime_seconds": 3600], id: "tc-quick")
        #expect(result.output == "working\ndone\n")
        #expect(result.exitCode == 0)
        #expect(try await rig.space.sessions.execJobs().isEmpty)
        #expect(try await rig.execMessages().isEmpty)
      }
    }
  }

  @Test func anotherSessionsExecIsNotFound() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      let peer = try await makeSession(rig.space, name: "peer")
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask { await scripted.serve { _ in for await _ in AsyncStream<Void>.makeStream().0 {} } }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        _ = try await rig.exec(["wait_seconds": 5], id: "tc-mine")
        let handle = try await rig.handle(of: "tc-mine")
        var theirs = ToolWorld(rig.world, session: peer)
        guard case let .failure(refused) = try await theirs.run("cancel", .object(["id": .string(handle)])) else {
          throw Mismatch("another session cancelled the exec")
        }
        #expect(refused.code == "notFound")
        #expect(scripted.kills.value.isEmpty)
        #expect(rig.owner.runningExecJobs(of: rig.session) == [handle])
      }
    }
  }

  @Test func anExecThatEndsWithinItsWaitIsTheCallsResult() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("ok\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        let result = try await rig.exec([:], id: "tc-short")
        #expect(result.output == "ok\n")
        #expect(result.exitCode == 0)
        #expect(try await rig.space.sessions.execJobs().isEmpty)
        #expect(try await rig.execMessages().isEmpty)
      }
    }
  }

  @Test func cancelKillsARunningExecAndItsEndIsNotAnnounced() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            try? await until("the kill") { !scripted.kills.value.isEmpty }
            await exec.exit(.signaled(signal: 15))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        _ = try await rig.exec(["wait_seconds": 5], id: "tc-killed")
        let handle = try await rig.handle(of: "tc-killed")
        guard case let .script(cancelled) = try await rig.world.run("cancel", .object(["id": .string(handle)])) else {
          throw Mismatch("cancel failed")
        }
        #expect(cancelled.output == "\(handle) was killed (SIGTERM to its process group, SIGKILL 5 s later); it ended with exit code 143")
        try await until("the job is forgotten") { try await rig.space.sessions.execJobs().isEmpty }
        #expect(try await rig.execMessages().isEmpty)

        guard case let .failure(again) = try await rig.world.run("cancel", .object(["id": .string(handle)])) else {
          throw Mismatch("a second cancel succeeded")
        }
        #expect(again.code == "alreadyEnded")
      }
    }
  }

  @Test func aWaitOfZeroIsRefused() async throws {
    try await withToolDeps { _ in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      guard case let .failure(refused) = try await rig.world.run(
        "exec", .object(["machine": .string(rig.machine.rawValue), "cwd": "/work", "command": "true", "wait_seconds": 0]),
      ) else { throw Mismatch("wait_seconds 0 was accepted") }
      #expect(refused.message == "exec: wait_seconds must be more than 0")
      #expect(refused.code == "invalidArgument")
      #expect(scripted.startCount.value == 0)
    }
  }

  @Test func aMessageThatAlreadyWaitedOutItsGraceCutsTheWaitAtOnce() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let scripted = rig.scripted
      let peer = try await makeSession(rig.space, name: "peer")
      let utc = TimeZone(identifier: "UTC")!
      // A session's DM, then 85 s later a person's message: the DM's 90 s
      // grace ends first, and both arrived before the call began.
      _ = try await rig.space.sessions.post(
        .dm(with: rig.session.rawValue), messageID: MessageID("m1"), sender: Sender(id: peer.rawValue, timeZone: utc),
        senderSession: peer, content: .init(text: "fyi"),
      )
      await time.advance(by: 85)
      _ = try await rig.space.sessions.post(
        .box(rig.session), messageID: MessageID("m2"), sender: Sender(id: "carol", timeZone: utc), content: .init(text: "are you there?"),
      )
      await time.advance(by: 6)
      let returned = Box(false)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask { await scripted.serve { _ in for await _ in AsyncStream<Void>.makeStream().0 {} } }
        // No clock moves from here on, so a grace started afresh would never
        // end; past ten real seconds the clock ticks again to free the call.
        group.addTask {
          let clock = ContinuousClock()
          try? await clock.sleep(for: .seconds(10))
          guard !returned.value else { return }
          Issue.record("the call waited a fresh grace")
          await ticking(time)
        }
        defer { group.cancelAll() }
        let result = try await rig.exec(["wait_seconds": 1800, "max_lifetime_seconds": 3600], id: "tc-late")
        returned.withLock { $0 = true }
        #expect(result.output.contains(#""note":"a message arrived, so the call gave the turn back; still running"#))
      }
    }
  }

  @Test func aServerRestartRejoinsTheRunningExecAndDeliversItsEndOnce() async throws {
    try await withToolDeps { time in
      var first = try await ExecJobRig()
      let scripted = first.scripted
      let (released, release) = AsyncStream<Void>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            for await _ in released { break }
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        let result = try await first.exec(["wait_seconds": 5], id: "tc-restart")
        let handle = try await first.handle(of: "tc-restart")
        #expect(result.output.hasPrefix(#"{"status":"running","id":"\#(handle)""#))

        // The server stops and a new one starts on the same store and machine.
        await first.owner.closeExecJobs()
        let second = try ExecJobRig(after: first)
        #expect(second.owner.runningExecJobs(of: second.session).isEmpty)
        await second.owner.adoptExecJobs()
        #expect(second.owner.runningExecJobs(of: second.session) == [handle])

        release.yield(())
        try await until("the end arrives as a message") { try await second.execMessages().count == 1 }
        #expect(try await second.execMessages() == ["\(handle) ended:\nworking\ndone\n"])
        #expect(scripted.startCount.value == 1, "the restart rejoins the exec, never starts it again")
        #expect(scripted.kills.value.isEmpty)
        try await until("the job is forgotten") { try await second.space.sessions.execJobs().isEmpty }
        #expect(second.owner.runningExecJobs(of: second.session).isEmpty)
      }
    }
  }

  @Test func aRestartedServerThatCannotRejoinTheExecSaysItsOutcomeIsUnknown() async throws {
    try await withToolDeps { time in
      var first = try await ExecJobRig()
      let scripted = first.scripted
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask { await scripted.serve { _ in for await _ in AsyncStream<Void>.makeStream().0 {} } }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }

        _ = try await first.exec(["wait_seconds": 5], id: "tc-lost")
        let handle = try await first.handle(of: "tc-lost")
        await first.owner.closeExecJobs()
        let second = try ExecJobRig(after: first, exec: false)
        await second.owner.adoptExecJobs()
        #expect(try await second.execMessages() == [
          "\(handle) was running when the server restarted, and its outcome is unknown: this server cannot rejoin it",
        ])
        #expect(try await second.space.sessions.execJobs().isEmpty)
        #expect(scripted.startCount.value == 1)
      }
    }
  }
}

/// Moves the controlled clock a second at a time until cancelled.
private func ticking(_ time: TimeControl) async {
  let clock = ContinuousClock()
  while !Task.isCancelled {
    await time.advance(by: 1)
    try? await clock.sleep(for: .milliseconds(2))
  }
}

private struct ExecJobRig {
  let space: Space
  let session: SessionID
  let machine: MachineID
  let scripted: ScriptedExecMachine
  var world: ToolWorld
  let owner: Hub

  init(scripted: ScriptedExecMachine = ScriptedExecMachine()) async throws {
    let space = try Space.inMemory()
    try self.init(
      space: space, session: try await makeSession(space), machine: try await space.addMachine(name: "box").id,
      scripted: scripted, exec: true,
    )
  }

  /// The next server: the same store and machine under a new owner, with
  /// or without a way to reach execs.
  init(after previous: ExecJobRig, exec: Bool = true) throws {
    try self.init(space: previous.space, session: previous.session, machine: previous.machine, scripted: previous.scripted, exec: exec)
  }

  private init(space: Space, session: SessionID, machine: MachineID, scripted: ScriptedExecMachine, exec: Bool) throws {
    self.space = space
    self.session = session
    self.machine = machine
    self.scripted = scripted
    let executor = SessionRuntime.toolExecutor(owner: Hub(space: space, machines: FakeMachineFS().seam, exec: exec ? scripted.backend(space) : nil))
    world = ToolWorld(executor: executor, session: session)
    owner = try #require(executor.owner as? Hub)
  }

  mutating func exec(_ extra: OrderedDictionary<String, JSONValue>, id: String) async throws -> ExecResult {
    var arguments: OrderedDictionary<String, JSONValue> = ["machine": .string(machine.rawValue), "cwd": "/work", "command": "make"]
    for (key, value) in extra { arguments[key] = value }
    guard case let .exec(result) = try await world.run("exec", ToolArguments(.object(arguments)), id: id) else {
      throw Mismatch("exec failed")
    }
    return result
  }

  /// Runs an exec that never ends while the clock stands still, then moves
  /// it to just short of `seconds` and on to `seconds`: the call must return
  /// only at the second step. Returns the call's output.
  mutating func waitCut(_ time: TimeControl, at seconds: Double, id: String) async throws -> String {
    let scripted = scripted
    let past = Box(false)
    var this = self
    let output = try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await scripted.pump() }
      group.addTask { await scripted.serve { _ in for await _ in AsyncStream<Void>.makeStream().0 {} } }
      group.addTask {
        await time.advance(by: seconds - 1)
        try? await ContinuousClock().sleep(for: .milliseconds(500))
        past.withLock { $0 = true }
        await time.advance(by: 1)
      }
      defer { group.cancelAll() }
      let result = try await this.exec(["wait_seconds": 1800, "max_lifetime_seconds": 3600], id: id)
      #expect(past.value, "the call returned before \(seconds) s")
      return result.output
    }
    self = this
    return output
  }

  func handle(of call: String) async throws -> String {
    let record = try #require(try await space.execRecord(caller: session.rawValue, toolCallID: ToolCallID(call)))
    return execHandle(record.id)
  }

  func execMessages() async throws -> [String] {
    try await space.sessions.hydrate(session).undrained.compactMap { entry in
      guard case let .notification(notification) = entry.input, notification.kind == .exec else { return nil }
      return notification.content.text
    }
  }
}
