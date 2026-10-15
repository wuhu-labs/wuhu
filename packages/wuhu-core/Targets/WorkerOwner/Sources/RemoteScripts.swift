#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import struct MachineContract.ExecStatus
import struct SessionDomain.SessionID
import struct SessionDomain.SystemNotification
import enum SessionTools.ScriptDataOperation
import struct SessionTools.ScriptModuleSnapshot
import protocol SessionTools.ScriptOwnerClient
import struct SpaceContract.GroupID
import struct SpaceCore.MachineRecord
import struct SpaceCore.Principal
import struct SpaceCore.Rev
import enum SpaceCore.RowEdit
import struct SpaceCore.Rows
import struct SpaceCore.ScriptExecOwner
import struct SpaceTools.FileBytes
import struct SpaceTools.FileVersion
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

extension RemoteExecutionOwner {
  public func principal(of session: SessionID) async throws -> Principal {
    let result: PrincipalSnapshot = try await rpc.call("script.principal", SessionIDRequest(id: session))
    return result.value
  }

  public func moduleSnapshot(for session: SessionID) async throws -> ScriptModuleSnapshot {
    let result: ModuleSnapshot = try await rpc.call("script.module-snapshot", SessionIDRequest(id: session))
    return result.value
  }

  public func moduleBytes(path: String, shown: String, group: GroupID, snapshot: ScriptModuleSnapshot) async throws -> Data {
    let result: Data = try await rpc.call("script.module-bytes", ModuleBytesRequest(path: path, shown: shown, group: group, snapshot: .init(snapshot)))
    return result
  }

  public func query(_ sql: String, parameters: [JSONValue], byteLimit: Int, session: SessionID) async throws -> Rows {
    let result: RowsSnapshot = try await rpc.call("script.query", QueryRequest(sql: sql, parameters: parameters, byteLimit: byteLimit, session: session))
    return try result.value()
  }

  public func dataOperation(_ operation: ScriptDataOperation, input: JSONValue, session: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.data", ScriptDataRequest(operation: operation.rawValue, input: input, session: session))
    return result
  }

  public func commitRows(_ path: String, edits: [RowEdit], session: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.commit-rows", CommitRowsRequest(path: path, edits: edits.map(RowEditSnapshot.init), session: session))
    return result
  }

  public func readBytes(_ path: String, rev: Int?, byteLimit: Int, session: SessionID) async throws -> FileBytes {
    let result: FileBytesSnapshot = try await rpc.call("script.read-bytes", ReadBytesRequest(path: path, rev: rev, byteLimit: byteLimit, session: session))
    return result.value
  }

  public func writeBytes(_ path: String, data: Data, ifMatch: String?, session: SessionID) async throws -> FileVersion {
    let result: FileVersionSnapshot = try await rpc.call("script.write-bytes", WriteBytesRequest(path: path, data: data, ifMatch: ifMatch, session: session))
    return result.value
  }

  public func checkout(_ path: String, rev: Int, ifMatch: String?, session: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.checkout", CheckoutRequest(path: path, rev: rev, ifMatch: ifMatch, session: session))
    return result
  }

  public func list(_ path: String, rev: Int?, hidden: Bool, byteLimit: Int, session: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.list", ListRequest(path: path, rev: rev, hidden: hidden, byteLimit: byteLimit, session: session))
    return result
  }

  public func discoveryContext(session: SessionID, contentHost: String?) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.context", DiscoveryContextRequest(session: session, contentHost: contentHost))
    return result
  }

  public func discoveryGroups(session: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.groups", SessionIDRequest(id: session))
    return result
  }

  public func conversation(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.conversation", ScriptArgumentsRequest(arguments: arguments, session: reader))
    return result
  }

  public func directMessage(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.direct-message", ScriptArgumentsRequest(arguments: arguments, session: reader))
    return result
  }

  public func secretNames(in group: String?, session: SessionID) async throws -> [String] {
    let result: [String] = try await rpc.call("script.secret-names", SecretNamesRequest(group: group, session: session))
    return result
  }

  public func secretValue(_ name: String, in group: String?, session: SessionID) async throws -> String {
    let result: String = try await rpc.call("script.secret-value", SecretValueRequest(name: name, group: group, session: session))
    return result
  }

  public func setSecret(_ name: String, value: String, session: SessionID) async throws {
    let _: Bool = try await rpc.call("script.set-secret", SetSecretRequest(name: name, value: value, session: session))
  }

  public func usableMachines(session: SessionID) async throws -> [MachineRecord] {
    let result: [MachineSnapshot] = try await rpc.call("script.machines", SessionIDRequest(id: session))
    return result.map(\.value)
  }

  public func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord? {
    let result: MachineSnapshot? = try await rpc.call("script.resolve-machine", ResolveMachineRequest(reference: reference, session: session))
    return result?.value
  }

  public func ownExecs(session: SessionID) async throws -> [ExecStatus] {
    let result: [ExecStatus] = try await rpc.call("script.own-execs", SessionIDRequest(id: session))
    return result
  }

  public func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus {
    let result: ExecStatus = try await rpc.call("script.own-exec-status", OwnExecRequest(id: id, session: session))
    return result
  }

  public func ownExecToKill(_ id: String, session: SessionID) async throws -> ExecID {
    let result: ExecID = try await rpc.call("script.own-exec-to-kill", OwnExecRequest(id: id, session: session))
    return result
  }

  public func takeScriptExecOwners() async throws -> [ScriptExecOwner] {
    let result: [ScriptExecOwnerSnapshot] = try await rpc.call("script.take-script-exec-owners", EmptyRequest())
    return result.map(\.value)
  }

  public func releaseScriptExecs(script: String) async throws {
    let _: Bool = try await rpc.call("script.release-script-execs", ReleaseScriptRequest(script: script))
  }

  public func notify(session: SessionID, notification: SystemNotification) async throws {
    let _: Bool = try await rpc.call("script.notify", ScriptNotifyRequest(session: session, notification: notification))
  }

  public func identityConfiguration() async throws -> JSONValue {
    let result: JSONValue = try await rpc.call("script.identity-configuration", EmptyRequest())
    return result
  }

  public func channel(_ arguments: [JSONValue], session: SessionID) async -> JSONValue {
    do { return try await rpc.call("script.channel", ScriptArgumentsRequest(arguments: arguments, session: session)) }
    catch { return .object(["error": .string("Parent channel operation failed")]) }
  }
}
