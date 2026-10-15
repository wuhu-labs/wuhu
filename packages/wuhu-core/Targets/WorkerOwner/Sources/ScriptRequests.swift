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

struct ModuleBytesRequest: Codable, Sendable { let path: String; let shown: String; let group: GroupID; let snapshot: ModuleSnapshot }
struct QueryRequest: Codable, Sendable { let sql: String; let parameters: [JSONValue]; let byteLimit: Int; let session: SessionID }
struct ScriptDataRequest: Codable, Sendable { let operation: String; let input: JSONValue; let session: SessionID }
struct CommitRowsRequest: Codable, Sendable { let path: String; let edits: [RowEditSnapshot]; let session: SessionID }
struct ReadBytesRequest: Codable, Sendable { let path: String; let rev: Int?; let byteLimit: Int; let session: SessionID }
struct WriteBytesRequest: Codable, Sendable { let path: String; let data: Data; let ifMatch: String?; let session: SessionID }
struct CheckoutRequest: Codable, Sendable { let path: String; let rev: Int; let ifMatch: String?; let session: SessionID }
struct ListRequest: Codable, Sendable { let path: String; let rev: Int?; let hidden: Bool; let byteLimit: Int; let session: SessionID }
struct DiscoveryContextRequest: Codable, Sendable { let session: SessionID; let contentHost: String? }
struct ScriptArgumentsRequest: Codable, Sendable { let arguments: [JSONValue]; let session: SessionID }
struct SecretNamesRequest: Codable, Sendable { let group: String?; let session: SessionID }
struct SecretValueRequest: Codable, Sendable { let name: String; let group: String?; let session: SessionID }
struct SetSecretRequest: Codable, Sendable { let name: String; let value: String; let session: SessionID }
struct ResolveMachineRequest: Codable, Sendable { let reference: String; let session: SessionID }
struct GroupRequest: Codable, Sendable { let group: GroupID }
struct OwnExecRequest: Codable, Sendable { let id: String; let session: SessionID }
struct ReleaseScriptRequest: Codable, Sendable { let script: String }
struct ScriptNotifyRequest: Codable, Sendable { let session: SessionID; let notification: SystemNotification }
