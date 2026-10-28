import TaskLifetime
#if canImport(FoundationEssentials)
  import struct FoundationEssentials.UUID
#else
  import struct Foundation.UUID
#endif
import struct Credentials.SpaceSecretStores
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import Logging
import MachineContract
import struct OperationProtocol.OperationError
import Serve
import func ServerTelemetry.reachedMachine
import struct ServerTelemetry.TraceParent
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore

public enum MachineHubError: Error, Equatable, Sendable {
  case machineUnattached(MachineID)
  case execNotFound(ExecID)
}

public actor MachineHub {
  nonisolated let callerScope = TaskScope()
  let space: Space
  private var service: MachineV2Service?
  private let tokens: ExecTokens?
  private let secrets: SpaceSecretStores?

  public init(space: Space) {
    self.space = space
    tokens = nil
    secrets = nil
  }

  init(space: Space, tokens: ExecTokens?, secrets: SpaceSecretStores? = nil) {
    self.space = space
    self.tokens = tokens
    self.secrets = secrets
  }

  func configureV2(_ service: MachineV2Service) { self.service = service }

  private func operationsService() throws -> MachineV2Service {
    guard let service else { throw OperationError(.machineUnavailable) }
    return service
  }

  private func group(_ machine: MachineID) async throws -> GroupID {
    guard let record = try await space.machine(machine) else { throw MachineHubError.machineUnattached(machine) }
    reachedMachine(machine)
    return record.group
  }

  func requireExecKind(_ machine: MachineID) async throws {
    let description = try await operationsService().operations(group: group(machine)).describe(machine.rawValue)
    guard description.kinds.contains(where: { $0.name == "exec.v1" }) || description.availability?["exec.v1"] != nil else {
      throw OperationError(.unknownKind, message: "Machine does not support exec.v1", details: ["kind": "exec.v1"])
    }
  }

  public func admitsCaller(_ record: ExecRecord, leg: ExecLeg) async -> Bool {
    guard let service else { return false }
    return await service.admits(record, leg: leg)
  }

  public func runCallerSession(_ record: ExecRecord, socket: WebSocket, leg: ExecLeg, trace: TraceParent? = nil) async {
    guard let service else { socket.close(); return }
    await service.runCaller(record, socket: socket, leg: leg, space: space, tokens: tokens, secrets: secrets, trace: trace)
  }

  public func noteMinted(_ record: ExecRecord) async {
    await service?.noteMinted(record, space: space)
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

  public func releaseScript(_ script: String, caller: String) async {
    do {
      for exec in try await space.liveScriptExecs(script: script, caller: caller) {
        do { try await kill(exec) } catch { Logger(label: "wuhu.exec").error("could not kill script \(script)'s exec \(exec.rawValue): \(error)") }
      }
      try await space.releaseScriptExecs(script: script, caller: caller)
    } catch {
      Logger(label: "wuhu.exec").error("could not release script \(script)'s machine processes: \(error)")
    }
  }

  public func kill(_ id: ExecID) async throws {
    guard let record = try await space.execRecord(id) else { throw MachineHubError.execNotFound(id) }
    guard record.terminal == nil else { return }
    try await operationsService().killExec(record)
    try await space.finishExec(id, .cancelled)
  }

  public static let maximumFrameBytes: Int = 16 << 20

  public func vfs(machine: MachineID, op: VFSOp, caller: SessionID? = nil) async throws -> VFSResult {
    try await operationsService().operations(group: group(machine)).vfs(machine: machine.rawValue, op: op, owner: .init(scope: "machine-tools/" + UUID().uuidString, key: "operation"), caller: space.startCaller(caller))
  }

  public func search(machine: MachineID, query: SearchQuery, caller: SessionID? = nil) async throws -> SearchPage {
    try await operationsService().operations(group: group(machine)).search(machine: machine.rawValue, query: query, caller: space.startCaller(caller))
  }
}
