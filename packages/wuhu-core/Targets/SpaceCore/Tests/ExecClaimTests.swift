import Dependencies
import DeterministicDependencies
import Foundation
import GRDB
import Scratch
import struct SessionDomain.ToolCallID
@testable import SpaceCore
import Testing

private func makeExecSpace() throws -> Space {
  try withDependencies {
    $0.date = .constant(fixedDate)
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
  } operation: {
    try Space.inMemory()
  }
}

@Suite(.deterministicDependencies) struct ExecClaimTests {
  @Test func claimSpecSurvivesRejoinAndOwedEndsSurviveTermination() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let first = try await space.claimExec(machine: machine, caller: "caller", toolCallID: ToolCallID("call"), spec: "{\"lifetime\":60}")
    let retry = try await space.claimExec(machine: machine, caller: "caller", toolCallID: ToolCallID("call"), spec: "{}")
    #expect(retry.rejoined)
    #expect(retry.record.toolSpec == first.record.toolSpec)
    #expect(try await space.execRecord(first.record.id)?.toolSpec == first.record.toolSpec)
    _ = try await space.mintExec(machine: machine, caller: "caller")
    #expect(try await space.owedExecs().isEmpty)
    #expect(try await space.setExecEndOwed(first.record.id, caller: "foreign", owed: true) == false)
    #expect(try await space.setExecEndOwed(first.record.id, caller: "caller", owed: true))
    #expect(try await space.setExecEndOwed(first.record.id, caller: "caller", owed: true))
    #expect(try await space.owedExecs().map(\.id) == [first.record.id])
    try await space.finishExec(first.record.id, .exited(code: 0))
    #expect(try await space.owedExecs().first?.terminal == .exited(code: 0))
    #expect(try await space.setExecEndOwed(first.record.id, caller: "caller", owed: false))
    #expect(try await space.owedExecs().isEmpty)
  }

  @Test func forgettingOwedEndsOnlyAffectsTheCallersToolExecs() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let own = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("own"))
    let terminal = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("terminal"))
    let foreign = try await space.claimExec(machine: machine, caller: "peer", toolCallID: .init("foreign"))
    let plain = try await space.mintExec(machine: machine, caller: "caller")
    let script = try await space.mintScriptExec(machine: machine, caller: "caller", script: "script")
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE machine_execs SET tool_end_owed = 1")
    }
    try await space.finishExec(terminal.record.id, .exited(code: 0))
    #expect(try await space.liveToolExecs(caller: "caller").map(\.id) == [own.record.id])
    try await space.forgetOwedExecs(caller: "caller")
    #expect(try await space.execRecord(own.record.id)?.toolEndOwed == false)
    #expect(try await space.execRecord(terminal.record.id)?.toolEndOwed == false)
    for id in [foreign.record.id, plain.id, script.id] {
      #expect(try await space.execRecord(id)?.toolEndOwed == true)
    }
    try await space.forgetOwedExecs(caller: "caller")
    #expect(try await space.owedExecs().map(\.id) == [foreign.record.id])
  }

  @Test func duplicateClaimIsAbsorbedAndScopedByCaller() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let session = "aaaaaaaa-0000-0000-0000-000000000001"

    let first = try await space.claimExec(machine: machine, caller: session, toolCallID: ToolCallID("tc-1"))
    #expect(first.rejoined == false)
    #expect(first.record.caller == session)
    #expect(first.record.toolCallID == ToolCallID("tc-1"))

    let retry = try await space.claimExec(machine: machine, caller: session, toolCallID: ToolCallID("tc-1"))
    #expect(retry.rejoined == true)
    #expect(retry.record == first.record)

    let sibling = try await space.claimExec(machine: machine, caller: session, toolCallID: ToolCallID("tc-2"))
    #expect(sibling.rejoined == false)
    #expect(sibling.record.id != first.record.id)

    let foreign = try await space.claimExec(
      machine: machine,
      caller: "bbbbbbbb-0000-0000-0000-000000000002",
      toolCallID: ToolCallID("tc-1"),
    )
    #expect(foreign.rejoined == false)
    #expect(foreign.record.id != first.record.id)
  }

  @Test func rejoinAfterTerminalStateSeesTheVerdict() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let session = "aaaaaaaa-0000-0000-0000-000000000001"

    let claim = try await space.claimExec(machine: machine, caller: session, toolCallID: ToolCallID("tc-1"))
    try await space.finishExec(claim.record.id, .reaped)

    let retry = try await space.claimExec(machine: machine, caller: session, toolCallID: ToolCallID("tc-1"))
    #expect(retry.rejoined == true)
    #expect(retry.record.terminal == .reaped)
  }

  @Test func reapVerdictIsStickyAgainstTheRealExit() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id

    let reaped = try await space.mintExec(machine: machine)
    try await space.finishExec(reaped.id, .reaped)
    try await space.finishExec(reaped.id, .signaled(signal: 9))
    #expect(try await space.execRecord(reaped.id)?.terminal == .reaped)

    let cancelled = try await space.mintExec(machine: machine)
    try await space.finishExec(cancelled.id, .cancelled)
    try await space.finishExec(cancelled.id, .exited(code: 3))
    #expect(try await space.execRecord(cancelled.id)?.terminal == .exited(code: 3))
  }

  @Test func scriptOwnersSurviveOnlyUntilTheyAreTaken() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let session = "aaaaaaaa-0000-0000-0000-000000000001"

    let running = try await space.mintScriptExec(machine: machine, caller: session, script: "s1")
    #expect(running.caller == session)
    #expect(running.toolCallID == nil)
    #expect(try await space.execRecord(running.id) == running)
    let finished = try await space.mintScriptExec(machine: machine, caller: session, script: "s1")
    try await space.finishExec(finished.id, .exited(code: 0))
    let released = try await space.mintScriptExec(machine: machine, caller: session, script: "s2")
    try await space.releaseScriptExecs(script: "s2", caller: session)
    let other = try await space.mintScriptExec(machine: machine, caller: "bbbbbbbb", script: "s3")

    let owners = try await space.takeScriptExecOwners()
    #expect(owners == [
      ScriptExecOwner(script: "s1", session: session, live: [running.id]),
      ScriptExecOwner(script: "s3", session: "bbbbbbbb", live: [other.id]),
    ])
    #expect(try await space.execRecord(released.id)?.terminal == nil, "releasing an owner row leaves the exec alone")
    #expect(try await space.takeScriptExecOwners().isEmpty)
  }
}
