import Dependencies
import Foundation
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

@Suite struct ExecClaimTests {
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

  @Test func reapedExecsQueueTheirKillForTheMachine() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id

    let record = try await space.mintExec(machine: machine)
    try await space.finishExec(record.id, .reaped)
    #expect(try await space.pendingKills(machine: machine).map(\.id) == [record.id])

    try await space.markKillDelivered(record.id)
    #expect(try await space.pendingKills(machine: machine).isEmpty)
  }

  // A machine-lost exec may still run on the box; the hub decides at connect
  // whether a caller resumes it or it gets the kill.
  @Test func machineLostExecsQueueTheirKillToo() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id

    let lost = try await space.mintExec(machine: machine)
    try await space.finishExec(lost.id, .machineLost)
    let exited = try await space.mintExec(machine: machine)
    try await space.finishExec(exited.id, .exited(code: 0))
    #expect(try await space.pendingKills(machine: machine).map(\.id) == [lost.id])
  }

  @Test func scriptOwnersSurviveOnlyUntilTheyAreTaken() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let session = "aaaaaaaa-0000-0000-0000-000000000001"

    let running = try await space.mintScriptExec(machine: machine, session: session, script: "s1")
    #expect(running.caller == session)
    #expect(running.toolCallID == nil)
    #expect(try await space.execRecord(running.id) == running)
    let finished = try await space.mintScriptExec(machine: machine, session: session, script: "s1")
    try await space.finishExec(finished.id, .exited(code: 0))
    let released = try await space.mintScriptExec(machine: machine, session: session, script: "s2")
    try await space.releaseScriptExecs(script: "s2")
    let other = try await space.mintScriptExec(machine: machine, session: "bbbbbbbb", script: "s3")

    let owners = try await space.takeScriptExecOwners()
    #expect(owners == [
      ScriptExecOwner(script: "s1", session: session, live: [running.id]),
      ScriptExecOwner(script: "s3", session: "bbbbbbbb", live: [other.id]),
    ])
    #expect(try await space.execRecord(released.id)?.terminal == nil, "releasing an owner row leaves the exec alone")
    #expect(try await space.takeScriptExecOwners().isEmpty)
  }
}
