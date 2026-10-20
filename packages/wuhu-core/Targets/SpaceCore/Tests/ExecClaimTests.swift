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

  @Test func reopeningAnOlderExecSchemaAddsNullableToolSpec() async throws {
    let scratch = try ScratchFolder("exec-schema")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    let original = try Space.open(file: file)
    let machine = try await original.addMachine(name: "box").id
    let minted = try await original.mintExec(machine: machine)
    try await original.writer.write { db in
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_spec")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_end_owed")
    }
    try await original.close()
    let reopened = try Space.open(file: file)
    #expect(try await reopened.execRecord(minted.id)?.toolSpec == nil)
    let claimed = try await reopened.claimExec(machine: machine, caller: "caller", toolCallID: ToolCallID("call"), spec: "{}")
    #expect(claimed.record.toolSpec == "{}")
    try await reopened.close()
    let again = try Space.open(file: file)
    #expect(try await again.execRecord(claimed.record.id)?.toolSpec == "{}")
    try await again.close()
  }

  @Test func reopeningMigratesDetachedJobsAndRetainsTheirEmptyTable() async throws {
    let scratch = try ScratchFolder("exec-jobs")
    defer { scratch.remove() }
    let file = scratch.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: file)
    let machine = try await space.addMachine(name: "box").id
    let claim = try await space.claimExec(machine: machine, caller: "caller", toolCallID: ToolCallID("call"))
    let plain = try await space.mintExec(machine: machine, caller: "caller")
    #expect(try await space.setExecEndOwed(plain.id, caller: "caller", owed: true) == false)
    let script = try await space.mintScriptExec(machine: machine, session: "caller", script: "script")
    #expect(try await space.setExecEndOwed(script.id, caller: "caller", owed: true) == false)
    try await space.finishExec(claim.record.id, .exited(code: 0))
    try await space.writer.write { db in
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_spec")
      try db.execute(sql: "ALTER TABLE machine_execs DROP COLUMN tool_end_owed")
      try db.execute(sql: "CREATE TABLE exec_jobs (exec_id TEXT PRIMARY KEY, spec TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO exec_jobs (exec_id, spec) VALUES (?, ?)", arguments: [claim.record.id.rawValue, "{}"])
    }
    try await space.close()
    let reopened = try Space.open(file: file)
    let owed = try #require(try await reopened.owedExecs().first)
    #expect(owed.id == claim.record.id)
    #expect(owed.terminal == .exited(code: 0))
    #expect(owed.toolSpec == "{}")
    #expect(owed.toolEndOwed)
    #expect(try await reopened.execRecord(plain.id)?.toolEndOwed == false)
    #expect(try await reopened.writer.read { db in try db.tableExists("exec_jobs") })
    #expect(try await reopened.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exec_jobs") } == 0)
    try await reopened.close()
    let again = try Space.open(file: file)
    #expect(try await again.owedExecs() == [owed])
    #expect(try await again.setExecEndOwed(owed.id, caller: "caller", owed: false))
    #expect(try await again.owedExecs().isEmpty)
    try await again.close()
    let delivered = try Space.open(file: file)
    #expect(try await delivered.owedExecs().isEmpty)
    #expect(try await delivered.execRecord(owed.id)?.toolEndOwed == false)
    #expect(try await delivered.writer.read { db in try db.tableExists("exec_jobs") })
    #expect(try await delivered.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exec_jobs") } == 0)
    try await delivered.close()
  }

  @Test func forgettingOwedEndsOnlyAffectsTheCallersToolExecs() async throws {
    let space = try makeExecSpace()
    let machine = try await space.addMachine(name: "box").id
    let own = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("own"))
    let terminal = try await space.claimExec(machine: machine, caller: "caller", toolCallID: .init("terminal"))
    let foreign = try await space.claimExec(machine: machine, caller: "peer", toolCallID: .init("foreign"))
    let plain = try await space.mintExec(machine: machine, caller: "caller")
    let script = try await space.mintScriptExec(machine: machine, session: "caller", script: "script")
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
