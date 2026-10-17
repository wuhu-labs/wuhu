#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Credentials
import Fetch
import InferenceKit
import JSONValue
import MachineContract
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceFS
import SpaceTools
import WuhuAI

public enum ScriptDataOperation: String, Sendable {
  case createTable = "table.create", tableSchema = "table.schema", alterTable = "table.alter"
  case instantiateTemplate = "new", remove = "rm", readAttributes = "attributes.read", patchAttributes = "attributes.patch"
  case stat, history, move = "mv", find, grep
}

public struct ScriptModuleSnapshot: Sendable {
  public let revision: Rev
  public let acting: GroupID
  public let readable: Set<GroupID>
  public init(revision: Rev, acting: GroupID, readable: Set<GroupID>) {
    self.revision = revision; self.acting = acting; self.readable = readable
  }
}

public struct ScriptIdentityReply: Sendable {
  public let response: Result<Response, any Error>
  public let protectedValues: [String]
  public init(response: Result<Response, any Error>, protectedValues: [String]) { self.response = response; self.protectedValues = protectedValues }
}

public protocol ScriptOwnerClient: Sendable {
  func scriptMachines(for session: SessionID) -> ScriptMachineAccess?
  func identityRequest(_ request: Request, session: SessionID) async -> ScriptIdentityReply
  func identityConfiguration() async throws -> JSONValue
  func principal(of session: SessionID) async throws -> Principal
  func moduleSnapshot(for session: SessionID) async throws -> ScriptModuleSnapshot
  func moduleBytes(path: String, shown: String, group: GroupID, snapshot: ScriptModuleSnapshot) async throws -> Data
  func query(_ sql: String, parameters: [JSONValue], byteLimit: Int, session: SessionID) async throws -> Rows
  func observe(_ sql: String, parameters: [JSONValue], session: SessionID) async throws -> AsyncThrowingStream<Rows, any Error>
  func watch(_ glob: String, from: Rev?, session: SessionID) async throws -> AsyncThrowingStream<JSONValue, any Error>
  func dataOperation(_ operation: ScriptDataOperation, input: JSONValue, session: SessionID) async throws -> JSONValue
  func commitRows(_ path: String, edits: [RowEdit], session: SessionID) async throws -> JSONValue
  func readBytes(_ path: String, rev: Int?, byteLimit: Int, session: SessionID) async throws -> FileBytes
  func writeBytes(_ path: String, data: Data, ifMatch: String?, session: SessionID) async throws -> FileVersion
  func checkout(_ path: String, rev: Int, ifMatch: String?, session: SessionID) async throws -> JSONValue
  func list(_ path: String, rev: Int?, hidden: Bool, byteLimit: Int, session: SessionID) async throws -> JSONValue
  func discoveryContext(session: SessionID, contentHost: String?) async throws -> JSONValue
  func discoveryGroups(session: SessionID) async throws -> JSONValue
  func channel(_ arguments: [JSONValue], session: SessionID) async -> JSONValue
  func conversation(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue
  func directMessage(_ arguments: [JSONValue], reader: SessionID) async throws -> JSONValue
  func secretNames(in group: String?, session: SessionID) async throws -> [String]
  func secretValue(_ name: String, in group: String?, session: SessionID) async throws -> String
  func setSecret(_ name: String, value: String, session: SessionID) async throws
  func usableMachines(session: SessionID) async throws -> [MachineRecord]
  func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord?
  func ownExecs(session: SessionID) async throws -> [ExecStatus]
  func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus
  func ownExecToKill(_ id: String, session: SessionID) async throws -> ExecID
  func takeScriptExecOwners() async throws -> [ScriptExecOwner]
  func releaseScriptExecs(script: String) async throws
  func notify(session: SessionID, notification: SystemNotification) async throws
}

public protocol ToolOwnerClient: ScriptOwnerClient {
  func scopeContext(_ id: SessionID, toolCallID: ToolCallID) async throws -> ScopeContext?
  func killInterruptedExec(session: SessionID, toolCallID: ToolCallID) async
  /// For each urgency, the earliest item in the session's queue that the
  /// model has not seen yet: now, and again after every change.
  func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error>
  func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload
  func refuseUnlessLive(_ session: SessionID) async throws
  func spawn(_ caller: SessionID, _ call: ToolCallID, _ order: SpawnOrder) async throws -> Spawned
  func sendMessage(_ caller: SessionID, _ call: ToolCallID, _ arguments: SendMessageArguments) async throws -> ToolResultPayload
  func request(_ caller: SessionID, _ call: ToolCallID, _ arguments: RequestArguments) async throws -> ToolResultPayload
  func setTags(_ caller: SessionID, of target: SessionID, to tags: [String]) async throws
  func control(_ verb: SessionControl.Verb, _ caller: SessionID, of target: SessionID, force: Bool) async throws
  func capabilityDocument(_ path: String) async throws -> Data?
  func capabilityInput(_ raw: String, as session: SessionID, limit: Int) async throws -> Data
  func recordCompletion(_ metric: InferenceMetric) async throws
  func resolveImageDestination(_ raw: String, session: SessionID) async throws -> Address
  func refuseImageDestination(_ destination: Address, session: SessionID) async throws
  func imageReceipt(_ session: SessionID, call: ToolCallID) async throws -> ToolResultPayload?
  func placeImage(_ image: Data, at destination: Address, session: SessionID, call: ToolCallID?, state: ToolExecutionState?) async throws -> ToolResultPayload
}
