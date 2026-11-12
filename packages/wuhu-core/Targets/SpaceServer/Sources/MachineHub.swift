import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.SpaceSecretStores
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import JSONValue
import Logging
import MachineContract
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import Serve
import func ServerTelemetry.reachedMachine
import struct ServerTelemetry.TraceParent
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import Wuwei

public enum MachineHubError: Error, Equatable, Sendable {
  case machineUnattached(MachineID)
  case execNotFound(ExecID)
}

public actor MachineHub {
  nonisolated let callerScope = TaskScope()
  let space: Space
  let revocationGate: @Sendable (MachineID) async -> Void
  private let tokens: ExecTokens?
  private let secrets: SpaceSecretStores?

  public init(space: Space) {
    self.space = space
    tokens = nil
    secrets = nil
    revocationGate = { _ in }
  }

  init(space: Space, tokens: ExecTokens? = nil, secrets: SpaceSecretStores? = nil, revocationGate: @escaping @Sendable (MachineID) async -> Void = { _ in }) {
    self.space = space
    self.tokens = tokens
    self.secrets = secrets
    self.revocationGate = revocationGate
  }

  private func group(_ machine: MachineID) async throws -> GroupID {
    guard let record = try await space.machine(machine) else { throw MachineHubError.machineUnattached(machine) }
    reachedMachine(machine)
    return record.group
  }

  func requireExecKind(_ machine: MachineID) async throws {
    guard let description = try await space.machineDescription(machine) else { throw OperationError(.machineUnavailable) }
    guard description.kinds.contains(where: { $0.name == "exec.v1" }) || description.availability?["exec.v1"] != nil else {
      throw OperationError(.unknownKind, message: "Machine does not support exec.v1", details: ["kind": "exec.v1"])
    }
  }

  public func admitsCaller(_ record: ExecRecord, leg: ExecLeg) async -> Bool {
    guard let request = try? await space.execRequest(record.id) else { return false }
    if let caller = record.caller {
      let owner: ExecLeg = if let account = Person.account(ofExecCaller: caller) { .person(account) }
      else if Observer.isMember(caller) { .observer(caller) }
      else { .session(SessionID(rawValue: caller)) }
      guard owner == leg else { return false }
    }
    return request.argv.isEmpty && record.terminal == nil
  }

  public func runCallerSession(_ record: ExecRecord, socket: WebSocket, leg: ExecLeg, trace: TraceParent? = nil) async {
    guard await admitsCaller(record, leg: leg) else { socket.close(); return }
    await ExecSocketLink(space: space, record: record, leg: leg).run(socket)
  }

  public func attachedMachines() async -> Set<MachineID> {
    var attached: Set<MachineID> = []
    for group in (try? await space.groups()) ?? [] {
      for id in (try? await space.machineV2Members(group: group.id)) ?? [] {
        if let evidence = try? await space.machineV2PresenceEvidence(id, group: group.id), evidence.state == .attached {
          attached.insert(MachineID(rawValue: id))
        }
      }
    }
    return attached
  }

  public func kill(_ id: ExecID) async throws {
    guard let record = try await space.execRecord(id) else { throw MachineHubError.execNotFound(id) }
    guard record.terminal == nil else { return }
    space.worker.send(MachineCell.ID(record.machine.rawValue)).stop(id.rawValue, reason: "callerCancelled")
  }

  public static let maximumFrameBytes: Int = 16 << 20

  func prepare(_ exec: MachineExec, machine: String) async throws -> StartRequest {
    var input: [String: JSONValue] = ["argv": .array(exec.argv.map(JSONValue.string)), "cwd": .string(exec.cwd), "stdin": .bool(exec.stdin)]
    let env = exec.env.filter { !SessionExecEnvironment.reserved.contains($0.key) }.mapValues(JSONValue.string)
    var values: [String: JSONValue] = [:]
    let names = exec.secrets.filter { !SessionExecEnvironment.reserved.contains($0.key) }
    if !names.isEmpty {
      guard let group = try await space.machine(MachineID(rawValue: machine))?.group,
            let store = try secrets?.group(group.rawValue) else { throw OperationError(.invalidInput, message: "Machine group secrets unavailable") }
      for (variable, name) in names {
        do { values[variable] = .string(try await store.value(of: name)) }
        catch { throw OperationError(.invalidInput, message: "Secret \(name) unavailable in group \(group.rawValue)") }
      }
    }
    if let session = exec.session, let tokens {
      input["sessionCredential"] = try await tokens.credential(session: session, group: exec.group, machine: MachineID(rawValue: machine), exec: ExecID(rawValue: exec.id), timeout: .seconds(min(exec.timeout ?? ExecTokens.longestLife, ExecTokens.longestLife)), issuedAt: exec.createdAt)
    }
    input["env"] = .object(.init(uniqueKeysWithValues: env.map { ($0.key, $0.value) }))
    input["secretValues"] = .object(.init(uniqueKeysWithValues: values.map { ($0.key, $0.value) }))
    return StartRequest(kind: "exec.v1", input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) })), caller: exec.attribution)
  }

  public func vfs(machine: MachineID, op: VFSOp, caller: SessionID? = nil) async throws -> VFSResult {
    _ = try await group(machine)
    return try await MachineFileClient(space: space, machine: machine, caller: space.startCaller(caller)).vfs(op)
  }

  public func copy(from source: CopySource, to target: CopyTarget, caller: SessionID? = nil) async throws -> CopyReceipt {
    if case let .machine(machine, _) = source { _ = try await group(machine) }
    if case let .machine(machine, _, _) = target { _ = try await group(machine) }
    return try await MachineFileTransfer(space: space, caller: space.startCaller(caller)).copy(from: source, to: target)
  }

  public func search(machine: MachineID, query: SearchQuery, caller: SessionID? = nil) async throws -> SearchPage {
    _ = try await group(machine)
    return try await MachineFileClient(space: space, machine: machine, caller: space.startCaller(caller)).search(query)
  }
}
