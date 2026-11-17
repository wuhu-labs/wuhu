#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import AgentsContract
import struct Credentials.SpaceSecretStores
import Crypto
import Dependencies
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import GroupContract
import JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import MachinesContract
import struct OperationProtocol.MachineDescription
import struct SessionDomain.ToolCallID
import SpaceFS
import SpaceIDs
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import Synchronization
import TenancyContract
import Wuwei

/// The machine family's entry point: what the server builds and hands the machine routes, the hub and other families'
/// clients. It owns the worker wiring the machine cells and their clients need.
public struct Machines: Sendable {
  public let worker: Worker
  let date: DateGenerator
  let rng: WithRandomNumberGenerator
  public let tenancy: TenancyClient
  let groups: GroupClient
  let notes: GroupNotes
  /// A session's summary, for an exec's home and its start attribution.
  let sessions: @Sendable (SessionID) async -> SessionSummary?
  public let credentials: ExecCredentials?
  let secrets: SpaceSecretStores?

  public init(
    worker: Worker,
    tenancy: TenancyClient,
    groups: GroupClient,
    notes: GroupNotes,
    sessions: @escaping @Sendable (SessionID) async -> SessionSummary?,
    credentials: ExecCredentials? = nil,
    secrets: SpaceSecretStores? = nil,
  ) {
    @Dependency(\.date) var date
    @Dependency(\.withRandomNumberGenerator) var rng
    self.worker = worker
    self.date = date
    self.rng = rng
    self.tenancy = tenancy
    self.groups = groups
    self.notes = notes
    self.sessions = sessions
    self.credentials = credentials
    self.secrets = secrets
  }

  /// Gives the worker the machine kinds and the clients other families and the machine routes reach; call before the
  /// worker starts.
  public func register() {
    // A worker registers its machine kinds once; a worker that reuses an id is a different worker.
    guard machinesRegistered.withLock({ $0.insert(ObjectIdentifier(worker)).inserted }) else { return }
    worker.provide(MachineBuffers(worker: worker.id))
    worker.provide(MachineCells(machine: { reading, id in reading.cell(MachineCell.ID(id.rawValue)) }))
    worker.provide(MachinesCells(directory: { $0.cell(MachineDirectoryCell.ID(machineDirectoryKey)) }))
    worker.provide(directory)
    for kind: Registration in [.cell(MachineCell.self), .cell(MachineDirectoryCell.self), .job(MachineReleaseJob.self)] {
      worker.register(kind)
    }
  }

  var directoryCell: MachineDirectoryCell { worker.cell(MachineDirectoryCell.ID(machineDirectoryKey)) }

  public func machine(_ id: MachineID) async throws -> MachineRecord? {
    worker.cell(MachineCell.ID(id.rawValue)).record()
  }

  public func machine(named name: String) async throws -> MachineRecord? {
    directoryCell.machine(named: name)
  }

  public func resolveMachine(_ reference: String) async throws -> MachineRecord? {
    if let record = try await machine(MachineID(rawValue: reference)) { return record }
    return try await machine(named: reference)
  }

  // The dial-in oracle: resolves only through the machine's live key, so clearing it is what revokes the machine.
  public func machine(pubkey: String) async throws -> MachineID? {
    directoryCell.row(pubkey: pubkey).map { MachineID(rawValue: $0.id) }
  }

  public func machines() async throws -> [MachineRecord] {
    directoryCell.machines()
  }

  /// The machines `group` may use, by the same switch that admits a single one.
  public func machines(usableFrom group: GroupID) async throws -> [MachineRecord] {
    directoryCell.machines(usableFrom: group)
  }

  /// A machine `group` may not use resolves as no machine at all.
  public func resolveMachine(_ reference: String, usableFrom group: GroupID) async throws -> MachineRecord? {
    guard let record = try await resolveMachine(reference) else { return nil }
    guard try await canUse(record, from: group) else { return nil }
    return record
  }

  /// Whether `group` may use `record`: `owner` is its own group alone; `reachable` is every group with write in its
  /// owner group.
  public func canUse(_ record: MachineRecord, from group: GroupID) async throws -> Bool {
    directoryCell.canUse(record, from: group)
  }

  public func machineDescription(_ machine: MachineID) async throws -> MachineDescription? {
    worker.cell(MachineCell.ID(machine.rawValue)).attachedDescription()
  }

  public func machineV2Members(group: GroupID) async throws -> [String] {
    directoryCell.machineV2Members(group: group)
  }

  public func machineV2PresenceEvidence(_ machine: String, group: GroupID) async throws -> MachineV2PresenceEvidence? {
    worker.cell(MachineCell.ID(machine)).presenceEvidence(group: group)
  }

  public func execRequest(_ id: ExecID) async throws -> MachineExec? {
    directoryCell.execRequest(id)
  }

  public func execRecord(_ id: ExecID) async throws -> ExecRecord? {
    directoryCell.execRecord(id)
  }

  public func execRecord(caller: String, toolCallID: ToolCallID) async throws -> ExecRecord? {
    directoryCell.execRecord(caller: caller, toolCallID: toolCallID)
  }

  public func liveExecs() async throws -> [ExecRecord] {
    directoryCell.liveExecs()
  }

  public func liveToolExecs(caller: String) async throws -> [ExecRecord] {
    directoryCell.liveToolExecs(caller: caller)
  }

  public func liveScriptExecs(script: String, caller: String) async throws -> [ExecID] {
    directoryCell.liveScriptExecs(script: script, caller: caller)
  }

  func storedPath(_ raw: String, mutating: Bool) async throws -> String {
    guard let path = try? SpacePath(validating: raw), path.components.count >= 3, path.components.starts(with: machineNotesRoot) else { return raw }
    guard let machine = directoryCell.machineFolder(path.components[2]) else {
      throw mutating ? SpaceError.alreadyExists(raw) : SpaceError.notFound(raw)
    }
    return try SpacePath(components: machineNotesRoot + [machine] + path.components.dropFirst(3)).rawValue
  }

  func folderList(_ group: GroupID) async throws -> [MachineFolder] {
    directoryCell.machineFolders(group: group)
  }

  public var buffers: MachineBuffers { worker.read { $0.dependency(MachineBuffers.self) } }

  /// The client other families and the routes reach out of step.
  public var directory: MachineDirectory {
    MachineDirectory(
      machine: { try await machine($0) },
      usable: { directoryCell.machines(usableFrom: $0) },
      resolve: { try await resolveMachine($0) },
      resolveUsable: { try await resolveMachine($0, usableFrom: $1) },
      canUse: { directoryCell.canUse($0, from: $1) },
      exec: { directoryCell.execRecord($0) },
      liveExecs: { directoryCell.liveExecs() },
      liveToolExecs: { directoryCell.liveToolExecs(caller: $0) },
      reserveExec: { try await reserveExec(machine: $0, caller: $1, group: $2, script: $3, toolCall: $4) },
    )
  }

  func randomSuffix(_ count: Int) -> String {
    rng { randomAlphanumericSuffix(count, using: &$0) }
  }
}

private let machineDirectoryKey = "machines"
private let machinesRegistered = Mutex<Set<ObjectIdentifier>>([])
let machineNotesRoot = ["_", "machines"]
