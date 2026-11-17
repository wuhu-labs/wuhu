import Crypto
import Dependencies
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import MachineChannel
import struct MachineContract.ExecID
import struct MachineContract.MachineID
@testable import Machines
import MachinesContract
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.Verdict
import Serve
@testable import SpaceCore
import SpaceFS
import SpaceIDs
import struct SpaceIDs.SessionID
import StructuredQueries
import Wuwei

/// A machine at a chosen id, with a live exec key — the id the test's own box socket addresses. A machine that exists
/// takes the new key in place of its old one.
public func seedBoxKey(space: Space, machine: String, worker: Worker? = nil) async throws -> String {
  @Dependency(\.date) var date
  let pubkey = Curve25519.Signing.PrivateKey().pubkeyLabel
  let now = date.now
  _ = try await (worker ?? space.worker).call(MachineCell.ID(machine)) { cell in
    guard var row = cell.db.rows(MachineRow.where { $0.id.eq(machine) }).first else {
      return try cell.create(group: .shared, scope: .owner, at: now, credential: .key(pubkey, enrolledBy: nil))
    }
    row.pubkey = pubkey; row.enrolledAt = SQLiteDateFormat.string(from: now); row.enrolledBy = nil
    try cell.db.execute(MachineRow.update(row))
  }
  return pubkey
}

public struct MachineFixtureError: Error {
  public var what: String
  public init(_ what: String) { self.what = what }
}

/// A box socket on the machine's worker, driven by `client`: the machine reaches `.attached` while `body` runs.
public func withMachineBox<R>(
  space: Space, hub: MachineHub, machine: MachineID, client: FetchClient,
  _ body: () async throws -> R,
) async throws -> R {
  let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
  guard let link = await BoxLink(worker: space.worker, machine: machine.rawValue, pubkey: pubkey, connection: UUID(), streams: 1024, buffers: space.machineFamily.buffers, prepare: {
    try await hub.prepare($0, machine: machine.rawValue)
  }) else { throw MachineFixtureError("the machine box did not attach") }
  return try await withThrowingTaskGroup(of: Void.self) { tasks in
    tasks.addTask { await link.run(client: client) }
    defer { link.close(); tasks.cancelAll() }
    guard try await realPollUntil({ try await space.machineFamily.machineDescription(machine) != nil }) else {
      throw MachineFixtureError("the machine never described itself")
    }
    return try await body()
  }
}

/// An exec's in-process caller leg: what the WebSocket route hands a dialing client.
public func connectExecCaller(_ id: ExecID, space: Space, hub: MachineHub) async throws -> any FrameTransport {
  guard let record = try await space.machineFamily.execRecord(id) else { throw MachineHubError.execNotFound(id) }
  let (server, client) = WebSocket.pair()
  let leg: ExecLeg = if let caller = record.caller { .session(SessionID(rawValue: caller)) } else { .person(try await space.ensureDevPerson().account) }
  _ = try? hub.callerScope.run("in-process-exec-caller") {
    await hub.runCallerSession(record, socket: server, leg: leg)
  }
  return WebSocketTransport(client)
}

public func watchSpaceTables(_ tables: [String], in space: Space) async -> (changes: AsyncStream<Void>, cancel: @Sendable () -> Void) {
  let (changes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let cancel = await space.observations.regions(tables, wake)
  wake.yield(())
  return (changes, cancel)
}

public func testFileOperations(in space: Space) async throws -> [(machine: String, row: MachineFileOperation)] {
  let machines = try await space.machineFamily.machines()
  return space.worker.read { reader in
    machines.flatMap { machine in
      reader.cell(MachineCell.ID(machine.id.rawValue)).fileOperationsForTest().map { (machine.id.rawValue, $0) }
    }
  }
}

extension MachineCell {
  public func fileOperationsForTest() -> [MachineFileOperation] { db.rows(MachineFileOperation.all) }
}

public func waitForMachineDescription(_ cell: MachineCell.ID, in space: Space) async throws {
  let watch = await watchSpaceTables(["machine_presence"], in: space)
  defer { watch.cancel() }
  for await _ in watch.changes {
    if space.worker.cell(cell).db.rows(MachinePresence.all).first?.state == "attached" { return }
  }
  try Task.checkCancellation()
  throw CancellationError()
}

public func setExecTerminalFixture(space: Space, exec: ExecID, terminal: ExecTerminalState) async throws {
  guard let record = try await space.machineFamily.execRecord(exec) else { throw MachineFixtureError("no exec \(exec.rawValue)") }
  try await space.worker.call(MachineCell.ID(record.machine.rawValue)) { cell in
    guard var row = cell.operation(exec.rawValue) else { throw MachineFixtureError("no exec row \(exec.rawValue)") }
    row.opened = terminal != .reaped
    row.state = "retired"
    row.delivered = true
    row.flights = [:]
    row.stopAt = nil
    row.answerAt = nil
    row.stop = terminal == .cancelled ? "callerCancelled" : nil
    let termination: JSONValue?
    switch terminal {
    case let .exited(code): termination = ["tag": "exit", "code": .number(Double(code))]
    case let .signaled(signal): termination = ["tag": "signal", "signal": .number(Double(signal))]
    case .cancelled, .machineLost, .reaped: termination = nil
    }
    row.snapshot = termination.map {
      OperationSnapshot(operation: row.request.operation, verdict: Verdict(.completed, result: ["termination": $0]), terminalToken: UUID(), finalOffsets: ["stdout": .zero, "stderr": .zero], outputConsumed: true)
    }
    try cell.save(row)
  }
  guard try await space.machineFamily.execRecord(exec)?.terminal == terminal else {
    throw MachineFixtureError("exec \(exec.rawValue) did not reach \(terminal)")
  }
}

/// Rows the program never wrote, as old data is: put there on a connection of their own, which the owner guard on the
/// space's writer does not see.
extension Space {
  public func plant(_ sql: String, arguments: [any MigrationValue?] = []) throws {
    try RawDatabase.open(databasePath) { try $0.execute(sql: sql, arguments: arguments) }
  }
}

/// The caller a principal acts as, from the server's own mapping.
public func testMachineCaller(_ principal: Principal, space: Space) -> MachineCaller {
  let kind: MachineCaller.Kind = switch principal.actor {
  case let .session(id): .session(id)
  case let .person(persona, account): .person(persona: persona, account: account)
  case let .observer(observer): .observer(group: observer.group, name: observer.name)
  case let .page(page): .page(group: page.group)
  case .publicReader: .publicReader
  }
  return MachineCaller(kind: kind, group: principal.group, member: principal.member) {
    try await space.reads(for: principal)
  }
}
