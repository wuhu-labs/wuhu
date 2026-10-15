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

struct ParentScriptEndpoint: Sendable {
  let owner: any ScriptOwnerClient
  func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation {
      case "script.principal":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(try PrincipalSnapshot(await owner.principal(of: request.id)))
      case "script.module-snapshot":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(ModuleSnapshot(await owner.moduleSnapshot(for: request.id)))
      case "script.module-bytes":
        let request = try ownerDecode(ModuleBytesRequest.self, call.payload)
        return try ownerEncode(await owner.moduleBytes(path: request.path, shown: request.shown, group: request.group, snapshot: request.snapshot.value))
      case "script.query":
        let request = try ownerDecode(QueryRequest.self, call.payload)
        return try ownerEncode(RowsSnapshot(await owner.query(request.sql, parameters: request.parameters, byteLimit: request.byteLimit, session: request.session)))
      case "script.data":
        let request = try ownerDecode(ScriptDataRequest.self, call.payload)
        return try ownerEncode(await owner.dataOperation(try scriptOperation(request.operation), input: request.input, session: request.session))
      case "script.commit-rows":
        let request = try ownerDecode(CommitRowsRequest.self, call.payload)
        return try ownerEncode(await owner.commitRows(request.path, edits: request.edits.map { try $0.value() }, session: request.session))
      case "script.read-bytes":
        let request = try ownerDecode(ReadBytesRequest.self, call.payload)
        return try ownerEncode(FileBytesSnapshot(await owner.readBytes(request.path, rev: request.rev, byteLimit: request.byteLimit, session: request.session)))
      case "script.write-bytes":
        let request = try ownerDecode(WriteBytesRequest.self, call.payload)
        return try ownerEncode(FileVersionSnapshot(await owner.writeBytes(request.path, data: request.data, ifMatch: request.ifMatch, session: request.session)))
      case "script.checkout":
        let request = try ownerDecode(CheckoutRequest.self, call.payload)
        return try ownerEncode(await owner.checkout(request.path, rev: request.rev, ifMatch: request.ifMatch, session: request.session))
      case "script.list":
        let request = try ownerDecode(ListRequest.self, call.payload)
        return try ownerEncode(await owner.list(request.path, rev: request.rev, hidden: request.hidden, byteLimit: request.byteLimit, session: request.session))
      case "script.context":
        let request = try ownerDecode(DiscoveryContextRequest.self, call.payload)
        return try ownerEncode(await owner.discoveryContext(session: request.session, contentHost: request.contentHost))
      case "script.groups":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(await owner.discoveryGroups(session: request.id))
      case "script.conversation":
        let request = try ownerDecode(ScriptArgumentsRequest.self, call.payload)
        return try ownerEncode(await owner.conversation(request.arguments, reader: request.session))
      case "script.direct-message":
        let request = try ownerDecode(ScriptArgumentsRequest.self, call.payload)
        return try ownerEncode(await owner.directMessage(request.arguments, reader: request.session))
      case "script.secret-names":
        let request = try ownerDecode(SecretNamesRequest.self, call.payload)
        return try ownerEncode(await owner.secretNames(in: request.group, session: request.session))
      case "script.secret-value":
        let request = try ownerDecode(SecretValueRequest.self, call.payload)
        return try ownerEncode(await owner.secretValue(request.name, in: request.group, session: request.session))
      case "script.set-secret":
        let request = try ownerDecode(SetSecretRequest.self, call.payload)
        try await owner.setSecret(request.name, value: request.value, session: request.session)
        return .bool(true)
      case "script.machines":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(await owner.usableMachines(session: request.id).map(MachineSnapshot.init))
      case "script.resolve-machine":
        let request = try ownerDecode(ResolveMachineRequest.self, call.payload)
        return try ownerEncode(await owner.resolveMachine(request.reference, session: request.session).map(MachineSnapshot.init))
      case "script.own-execs":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        return try ownerEncode(await owner.ownExecs(session: request.id))
      case "script.own-exec-status":
        let request = try ownerDecode(OwnExecRequest.self, call.payload)
        return try ownerEncode(await owner.ownExecStatus(request.id, session: request.session))
      case "script.own-exec-to-kill":
        let request = try ownerDecode(OwnExecRequest.self, call.payload)
        return try ownerEncode(await owner.ownExecToKill(request.id, session: request.session))
      case "script.take-script-exec-owners":
        return try ownerEncode(await owner.takeScriptExecOwners().map(ScriptExecOwnerSnapshot.init))
      case "script.release-script-execs":
        let request = try ownerDecode(ReleaseScriptRequest.self, call.payload)
        try await owner.releaseScriptExecs(script: request.script)
        return .bool(true)
      case "script.notify":
        let request = try ownerDecode(ScriptNotifyRequest.self, call.payload)
        try await owner.notify(session: request.session, notification: request.notification)
        return .bool(true)
      case "script.identity-configuration":
        return try ownerEncode(await owner.identityConfiguration())
      case "script.channel":
        let request = try ownerDecode(ScriptArgumentsRequest.self, call.payload)
        return await owner.channel(request.arguments, session: request.session)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent script operation")
      }
    }
  }
}

private func scriptOperation(_ raw: String) throws -> ScriptDataOperation {
  guard let value = ScriptDataOperation(rawValue: raw) else { throw WorkerProtocolError(.invalidMessage, message: "Invalid script data operation") }
  return value
}
