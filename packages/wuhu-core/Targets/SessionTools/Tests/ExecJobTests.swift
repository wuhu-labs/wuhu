import ControlledTime
import Dependencies
import DeterministicDependencies
import Foundation
import JSONValue
import Logging
import MachineChannel
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import func MainHub.execHandle
import class MainHub.Hub
import OrderedCollections
import SessionDomain
@testable import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolArguments

/// An exec that outlives its call: `running` past the wait or a message's
/// grace, one message at its end, cancel, and a restart that rejoins it.
@Suite(.deterministicDependencies, .timeLimit(.minutes(2))) struct ExecJobTests {
  @Test func migratedJobSpecsUseTheAuthoritativeClaimedID() throws {
    let stored = #"{"start":{"id":"ex_original","cwd":"/work","command":["sh","-c","echo done"],"window":65636,"maxOutput":100,"timeout":60},"machine":"box","lifetime":60,"defaultLifetime":false}"#
    let spec = try JSONDecoder().decode(ExecJobSpec.self, from: Data(stored.utf8))
    let start = spec.start(id: ExecID(rawValue: "ex_claimed"))
    #expect(start.id.rawValue == "ex_claimed")
    #expect(start.cwd == "/work")
    #expect(start.command == ["sh", "-c", "echo done"])
    #expect(start.window == 65636)
    #expect(start.maxOutput == 100)
    #expect(start.timeout == 60)
  }

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
        #expect(rig.executor.runningExecJobs(of: rig.session) == [handle])
        #expect(try await rig.execMessages().isEmpty)

        release.yield(())
        try await until("the end arrives as a message") { try await rig.execMessages().count == 1 }
        #expect(try await rig.execMessages() == ["\(handle) ended with exit code 3:\nworking\ndone\n"])
        try await until("the job is forgotten") { rig.jobs.jobs(of: rig.session).isEmpty }
        #expect(rig.executor.runningExecJobs(of: rig.session).isEmpty)
        try await until("terminal acknowledgement is held") { ackEntered.value }
        guard case let .failure(ended) = try await rig.world.run("cancel", .object(["id": .string(handle)])) else {
          throw Mismatch("an ended exec accepted cancel while its terminal ack was held")
        }
        #expect(ended.code == "alreadyEnded")
        #expect(scripted.kills.value.isEmpty)
        await rig.jobs.close()
        #expect(ackFinished.value, "shutdown joins terminal-ack transport even after the job is forgotten")
        let restarted = try ExecJobRig(after: rig)
        await restarted.executor.adoptExecJobs(of: restarted.session)
        #expect(restarted.executor.runningExecJobs(of: restarted.session).isEmpty)
        #expect(try await restarted.execMessages().count == 1)
        #expect(scripted.startCount.value == 1)
      }
    }
  }

  @Test(arguments: [false, true])
  func anUncommittedRunningResultRetriesIntoTheExitResult(_ exitsBeforeRetry: Bool) async throws {
    try await withToolDeps { time in
      let acknowledgements = Box(0)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in acknowledgements.withLock { $0 += 1 } })
      let rig = try await ExecJobRig(scripted: scripted)
      let release = Gate()
      let callID = "tc-running-retry"
      let arguments = ToolArguments(.object([
        "machine": .string(rig.machine.rawValue), "cwd": .string("/work"), "command": .string("make"), "wait_seconds": .number(5),
      ]))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            await release.wait()
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 7))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        guard case let .exec(first) = try await rig.world.retry("exec", arguments, id: callID) else { throw Mismatch("exec failed") }
        #expect(JSONValue.parse(first.output)?.object?["status"]?.stringValue == "running")
        let job = try #require(rig.jobs.job(rig.session, .init(callID)))
        #expect(job.phase == .detaching)
        #expect(rig.executor.runningExecJobs(of: rig.session).isEmpty)
        if exitsBeforeRetry {
          release.open()
          try await until("the uncommitted running result retains the exit") { job.ended.value != nil }
        }
        #expect(try await rig.execMessages().isEmpty)
        #expect(acknowledgements.value == 0)
        let result = try await withThrowingTaskGroup(of: ToolResultPayload.self) { retry in
          retry.addTask {
            var world = rig.world
            return try await world.run("exec", arguments, id: callID)
          }
          if !exitsBeforeRetry {
            try await until("the retry takes its end back") { job.phase == .awaited }
            release.open()
          }
          let result = try await retry.next()
          return try #require(result)
        }
        guard case let .exec(ended) = result else { throw Mismatch("retry did not return the exit") }
        #expect(ended.output == "working\ndone\n")
        #expect(ended.exitCode == 7)
        #expect(try await rig.execMessages().isEmpty)
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
        #expect(try await rig.space.execRecord(job.id)?.toolEndOwed == false)
        try await until("the retried exit is acknowledged once") { acknowledgements.value == 1 }
        #expect(scripted.startCount.value == 1)
        await rig.jobs.close()
        #expect(acknowledgements.value == 1)
      }
    }
  }

  @Test func anUncommittedRunningResultCanCutAgainBeforeItsOneEndMessage() async throws {
    try await withToolDeps { time in
      let acknowledgements = Box(0)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in acknowledgements.withLock { $0 += 1 } })
      var rig = try await ExecJobRig(scripted: scripted)
      let release = Gate()
      let callID = "tc-running-recut"
      let arguments = ToolArguments(.object([
        "machine": .string(rig.machine.rawValue), "cwd": .string("/work"), "command": .string("make"), "wait_seconds": .number(5),
      ]))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            await release.wait()
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        guard case let .exec(first) = try await rig.world.retry("exec", arguments, id: callID) else { throw Mismatch("exec failed") }
        #expect(JSONValue.parse(first.output)?.object?["status"]?.stringValue == "running")
        let second = try await rig.exec(["wait_seconds": 3], id: callID)
        #expect(JSONValue.parse(second.output)?.object?["status"]?.stringValue == "running")
        let job = try #require(rig.jobs.job(rig.session, .init(callID)))
        #expect(job.phase == .detached)
        #expect(rig.executor.runningExecJobs(of: rig.session) == [job.handle])
        #expect(try await rig.execMessages().isEmpty)
        release.open()
        try await until("the committed running retry gets one end message") { try await rig.execMessages().count == 1 }
        #expect(try await rig.execMessages() == ["\(job.handle) ended:\nworking\ndone\n"])
        try await until("the detached exit is acknowledged once") { acknowledgements.value == 1 }
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
        #expect(scripted.startCount.value == 1)
        await rig.jobs.close()
        #expect(acknowledgements.value == 1)
      }
    }
  }

  @Test func aBufferedExitWaitsForTheRunningResultToCommitBeforeItsNotice() async throws {
    try await withToolDeps { time in
      let acknowledgements = Box(0)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in acknowledgements.withLock { $0 += 1 } })
      let rig = try await ExecJobRig(scripted: scripted)
      let release = Gate()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            await release.wait()
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        let outcome = try await rig.executor.execute(session: rig.session, call: .init(
          id: "tc-buffered-running", name: "exec", arguments: .object([
            "machine": .string(rig.machine.rawValue), "cwd": .string("/work"), "command": .string("make"), "wait_seconds": .number(5),
          ]),
        ), state: .init())
        guard case let .exec(running) = outcome.payload else { throw Mismatch("exec failed") }
        #expect(JSONValue.parse(running.output)?.object?["status"]?.stringValue == "running")
        let job = try #require(rig.jobs.job(rig.session, .init("tc-buffered-running")))
        release.open()
        try await until("the uncommitted running result buffers its end") { job.ended.value != nil }
        #expect(try await rig.execMessages().isEmpty)
        #expect(acknowledgements.value == 0)
        #expect(outcome.committed != nil)
        await outcome.committed?()
        #expect(try await rig.execMessages() == ["\(job.handle) ended:\ndone\n"])
        try await until("the buffered exit is acknowledged after commit") { acknowledgements.value == 1 }
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
        await rig.jobs.close()
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
        #expect(rig.executor.runningExecJobs(of: rig.session) == [handle])

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
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
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
        #expect(rig.executor.runningExecJobs(of: rig.session) == [handle])
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
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
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
        try await until("the job is forgotten") { rig.jobs.jobs(of: rig.session).isEmpty }
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
        await first.jobs.close()
        let second = try ExecJobRig(after: first)
        #expect(second.executor.runningExecJobs(of: second.session).isEmpty)
        await second.executor.adoptExecJobs(of: second.session)
        #expect(second.executor.runningExecJobs(of: second.session) == [handle])

        release.yield(())
        try await until("the end arrives as a message") { try await second.execMessages().count == 1 }
        #expect(try await second.execMessages() == ["\(handle) ended:\nworking\ndone\n"])
        #expect(scripted.startCount.value == 1, "the restart rejoins the exec, never starts it again")
        #expect(scripted.kills.value.isEmpty)
        try await until("the job is forgotten") { second.jobs.jobs(of: second.session).isEmpty }
        #expect(second.executor.runningExecJobs(of: second.session).isEmpty)
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
        await first.jobs.close()
        let second = try ExecJobRig(after: first, exec: false)
        await second.executor.adoptExecJobs(of: second.session)
        #expect(try await second.execMessages() == [
          "\(handle) was running when the server restarted, and its outcome is unknown: this server cannot rejoin it",
        ])
        #expect(second.jobs.jobs(of: second.session).isEmpty)
        #expect(scripted.startCount.value == 1)
      }
    }
  }

  @Test func bootAdoptionLeavesAnUncommittedToolCallForTheLoopToRejoin() async throws {
    try await withToolDeps { time in
      var rig = try await ExecJobRig()
      let callID = "tc-pending"
      let spec = ExecJobSpec(
        cwd: "/work",
        command: ["sh", "-c", "make"],
        env: nil,
        secrets: nil,
        maxOutput: 1 << 20,
        machine: rig.machine.rawValue,
        lifetime: 1800,
        defaultLifetime: true,
      )
      let claim = try await rig.space.claimExec(
        machine: rig.machine,
        caller: rig.session.rawValue,
        toolCallID: .init(callID),
        spec: String(decoding: JSONEncoder().encode(spec), as: UTF8.self),
      )
      #expect(try await rig.space.setExecEndOwed(claim.record.id, caller: rig.session.rawValue, owed: true))
      let item = TranscriptItem.assistant(AssistantEntry(
        id: UUID(), timestamp: anchor,
        content: [.toolCall(.init(id: callID, name: "exec", arguments: .object(["machine": .string(rig.machine.rawValue), "cwd": "/work", "command": "make"])))],
        stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:],
      ))
      try await rig.space.sessions.append(rig.session, items: [item], inputOrigin: Transcript(items: [item]).cacheWarmingInputOrigin)
      await rig.executor.adoptExecJobs(of: rig.session)
      #expect(rig.jobs.jobs(of: rig.session).isEmpty)
      #expect(try await rig.space.execRecord(claim.record.id)?.toolEndOwed == true)
      #expect(rig.scripted.startCount.value == 0)
      #expect(try await rig.execMessages().isEmpty)
      let scripted = rig.scripted
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            #expect(exec.start.id == claim.record.id)
            try? await exec.send(.stdout, Array("rejoined\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        let result = try await rig.exec([:], id: callID)
        #expect(result.output == "rejoined\n")
        #expect(scripted.startCount.value == 1)
        #expect(try await rig.execMessages().isEmpty)
        #expect(try await rig.handle(of: callID) == execHandle(claim.record.id))
        #expect(try await rig.space.execRecord(claim.record.id)?.toolEndOwed == false)
      }
    }
  }

  @Test(arguments: [nil, "not-json"] as [String?])
  func bootAdoptionWithoutADecodableSpecAnnouncesUnknownOnce(_ spec: String?) async throws {
    try await withToolDeps { _ in
      let rig = try await ExecJobRig()
      let claim = try await rig.space.claimExec(
        machine: rig.machine,
        caller: rig.session.rawValue,
        toolCallID: .init("tc-legacy"),
        spec: spec,
      )
      #expect(try await rig.space.setExecEndOwed(claim.record.id, caller: rig.session.rawValue, owed: true))
      await rig.executor.adoptExecJobs(of: rig.session)
      await rig.executor.adoptExecJobs(of: rig.session)
      #expect(try await rig.execMessages() == [
        "\(execHandle(claim.record.id)) was running when the server restarted, and its outcome is unknown: this server cannot rejoin it",
      ])
      #expect(try await rig.space.execRecord(claim.record.id)?.toolEndOwed == false)
      #expect(rig.executor.runningExecJobs(of: rig.session).isEmpty)
      #expect(rig.scripted.startCount.value == 0)
      #expect(rig.scripted.kills.value.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func restartRecoversATerminalExecWhoseEndWasNotDelivered(_ afterNoticeAppend: Bool) async throws {
    try await withToolDeps { time in
      let acknowledgements = Box(0)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in acknowledgements.withLock { $0 += 1 } })
      var first = try await ExecJobRig(scripted: scripted)
      let release = Gate()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            try? await exec.send(.stdout, Array("working\n".utf8))
            await release.wait()
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        _ = try await first.exec(["wait_seconds": 5], id: "tc-delivery-crash")
        let record = try #require(try await first.space.execRecord(caller: first.session.rawValue, toolCallID: .init("tc-delivery-crash")))
        let handle = execHandle(record.id)
        #expect(record.toolEndOwed)
        if afterNoticeAppend {
          scripted.failDelivered.withLock { $0 = true }
        } else {
          try await first.space.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_exec_notice BEFORE INSERT ON session_queue BEGIN SELECT RAISE(FAIL, 'injected notice failure'); END")
          }
        }
        release.open()
        try await until("the failed end delivery retires its local job") { first.jobs.jobs(of: first.session).isEmpty }
        #expect(try await first.space.execRecord(record.id)?.terminal == .exited(code: 0))
        #expect(try await first.space.execRecord(record.id)?.toolEndOwed == true)
        #expect(try await first.execMessages().count == (afterNoticeAppend ? 1 : 0))
        #expect(acknowledgements.value == 0)
        await first.jobs.close()
        if afterNoticeAppend {
          scripted.failDelivered.withLock { $0 = false }
        } else {
          try await first.space.writer.write { db in try db.execute(sql: "DROP TRIGGER fail_exec_notice") }
        }
        let second = try ExecJobRig(after: first)
        await second.executor.adoptExecJobs(of: second.session)
        try await until("the terminal exec's owed end is delivered") {
          try await second.space.execRecord(record.id)?.toolEndOwed == false
        }
        #expect(try await second.execMessages() == ["\(handle) ended:\nworking\ndone\n"])
        #expect(scripted.startCount.value == 1)
        try await until("the recovered terminal stream is acknowledged") { acknowledgements.value == 1 }
        await second.executor.adoptExecJobs(of: second.session)
        #expect(try await second.execMessages().count == 1)
        #expect(second.jobs.jobs(of: second.session).isEmpty)
        await second.jobs.close()
      }
    }
  }

  @Test func archiveAcknowledgesACancelledEndWithoutDeliveryAccess() async throws {
    try await withToolDeps { time in
      let acknowledgements = Box(0)
      let scripted = ScriptedExecMachine(onTerminalAck: { _ in acknowledgements.withLock { $0 += 1 } })
      var rig = try await ExecJobRig(scripted: scripted)
      let release = Gate()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            await release.wait()
            await exec.exit(.signaled(signal: 15))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        _ = try await rig.exec(["wait_seconds": 5], id: "tc-archive-ack")
        let record = try #require(try await rig.space.execRecord(caller: rig.session.rawValue, toolCallID: .init("tc-archive-ack")))
        _ = try await rig.space.sessions.archive(rig.session, grace: .zero)
        scripted.failDelivered.withLock { $0 = true }
        await rig.executor.cancelExecJobs(of: rig.session)
        try await rig.space.forgetOwedExecs(caller: rig.session.rawValue)
        release.open()
        try await until("the archived cancelled end is acknowledged") { acknowledgements.value == 1 }
        await rig.jobs.close()
        #expect(rig.jobs.jobs(of: rig.session).isEmpty)
        #expect(try await rig.space.execRecord(record.id)?.toolEndOwed == false)
        #expect(try await rig.execMessages().isEmpty)
        await rig.executor.adoptExecJobs(of: rig.session)
        #expect(acknowledgements.value == 1)
        #expect(scripted.kills.value == [record.id])
      }
    }
  }

  @Test(arguments: [false, true])
  func anArchivedCallerDropsItsLocalJobEvenIfDeliveryCleanupIsRefused(_ cleanupRefused: Bool) async throws {
    try await withToolDeps { time in
      var first = try await ExecJobRig()
      let scripted = first.scripted
      let release = Gate()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await scripted.pump() }
        group.addTask {
          await scripted.serve { exec in
            await release.wait()
            try? await exec.send(.stdout, Array("done\n".utf8))
            await exec.exit(.exited(code: 0))
          }
        }
        group.addTask { await ticking(time) }
        defer { group.cancelAll() }
        _ = try await first.exec(["wait_seconds": 5], id: "tc-archived")
        let record = try #require(try await first.space.execRecord(caller: first.session.rawValue, toolCallID: .init("tc-archived")))
        await first.jobs.close()
        _ = try await first.space.sessions.archive(first.session, grace: .zero)
        scripted.failDelivered.withLock { $0 = cleanupRefused }
        let second = try ExecJobRig(after: first)
        let messages = Box<[String]>([])
        let log = Logger(label: "test.exec") { _ in ExecEndLogHandler(messages: messages) }
        try await ToolExecutor.$execLog.withValue(log) {
          await second.executor.adoptExecJobs(of: second.session)
          #expect(second.jobs.jobs(of: second.session).count == 1)
          release.open()
          try await until("the terminal append refusal retires the local job") { second.jobs.jobs(of: second.session).isEmpty }
          await second.jobs.close()
          #expect(messages.value.count == 1)
          #expect(messages.value.first?.contains("could not record its end") == true)
          #expect(try await second.execMessages().isEmpty)
          #expect(try await second.space.execRecord(record.id)?.toolEndOwed == cleanupRefused)
          // Main's archive bookkeeping does not need the caller's token.
          try await second.space.forgetOwedExecs(caller: second.session.rawValue)
          #expect(try await second.space.execRecord(record.id)?.toolEndOwed == false)
          await second.executor.adoptExecJobs(of: second.session)
          #expect(second.jobs.jobs(of: second.session).isEmpty)
          #expect(messages.value.count == 1)
        }
      }
    }
  }

  @Test func cancelWithoutALocalJobRequiresAnOwnedToolExec() async throws {
    try await withToolDeps { _ in
      var rig = try await ExecJobRig()
      let peer = try await makeSession(rig.space, name: "peer")
      let plain = try await rig.space.mintExec(machine: rig.machine, caller: rig.session.rawValue)
      let script = try await rig.space.mintScriptExec(machine: rig.machine, caller: rig.session.rawValue, script: .init("script"))
      let foreign = try await rig.space.claimExec(machine: rig.machine, caller: peer.rawValue, toolCallID: .init("tc-peer"))
      for id in [plain.id, script.id, foreign.record.id] {
        let refused = try await rig.world.run("cancel", .object(["id": .string(execHandle(id))]))
        #expect(try failure(refused).code == "notFound")
      }
      #expect(rig.scripted.kills.value.isEmpty)
      let owned = try await rig.space.claimExec(machine: rig.machine, caller: rig.session.rawValue, toolCallID: .init("tc-unmapped"))
      let handle = execHandle(owned.record.id)
      guard case let .script(killed) = try await rig.world.run("cancel", .object(["id": .string(handle)])) else {
        throw Mismatch("an owned tool exec could not be killed without a local job")
      }
      #expect(killed.output == "\(handle) was sent SIGTERM to its process group, and gets SIGKILL 5 s later")
      #expect(rig.scripted.kills.value == [owned.record.id])
      let ended = try await rig.world.run("cancel", .object(["id": .string(handle)]))
      #expect(try failure(ended).code == "alreadyEnded")
      #expect(rig.scripted.kills.value.count == 1)
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
  let executor: ToolExecutor
  let jobs = ExecJobs()

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
    let executor = scripted.executor(owner: Hub(space: space, machines: FakeMachineFS().seam), jobs: jobs, reachable: exec)
    world = ToolWorld(executor: executor, session: session)
    self.executor = executor
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

private struct ExecEndLogHandler: LogHandler {
  let messages: Box<[String]>
  var logLevel: Logger.Level = .trace
  var metadata: Logger.Metadata = [:]

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { metadata[key] }
    set { metadata[key] = newValue }
  }

  func log(event: LogEvent) {
    messages.withLock { $0.append(event.message.description) }
  }
}
