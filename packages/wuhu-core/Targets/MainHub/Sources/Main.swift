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

public enum ScriptDiscoveryOperation: Sendable {
  case identity, context, groups, toolRosters
}

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

public protocol Main: Sendable {
  var tracesAttempts: Bool { get }
  func openAttemptTrace(_ id: UUID) async throws -> AttemptTraceSink
  func providerCredentialBinding(_ provider: String) async throws -> CredentialBinding?
  func inferenceToken(audience: URL, session: SessionID) async throws -> String
  func inferenceReadiness(audience: URL) async throws
  func inferenceBindingIdentity(audience: URL, session: SessionID) async throws -> String?
  func promptHome(_ id: SessionID) async throws -> SessionHome
  func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data
  func recordMetric(_ metric: InferenceMetric) async
  func scriptMachines(session: SessionID) async throws -> [ScriptMachineSnapshot]
  func scriptMachineFile(session: SessionID, machine: MachineID, operation: VFSOp) async throws -> VFSResult
  func startScriptExec(session: SessionID, script: ScriptRunID, request: ScriptExecRequest) async throws -> ScriptExecStream
  func scriptExecInput(session: SessionID, script: ScriptRunID, exec: ExecID, input: ScriptExecInput) async throws
  func identityRequest(_ request: Request, session: SessionID) async -> ScriptIdentityReply
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
  func discovery(_ operation: ScriptDiscoveryOperation, session: SessionID) async throws -> JSONValue
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
  func releaseScriptExecs(script: String) async throws
  func killInterruptedExec(session: SessionID, toolCallID: ToolCallID) async
  /// For each urgency, the earliest item in the session's queue that the
  /// model has not seen yet: now, and again after every change.
  func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error>
  // Exec (`execute`, `ownExecs`, `ownExecStatus`, `killInterruptedExec` and
  // the script exec members) and the operator verbs (`setTags`, `control`)
  // stay on Main until the cut that moves exec into the worker; inference and
  // the capabilities scripts reach through `complete`/`capability`
  // (`refuseUnlessLive`, `capabilityDocument`, `capabilityInput`,
  // `recordCompletion`) until the cut that moves them over the API.
  func execute(session: SessionID, call: ToolCall, state: ToolExecutionState) async throws -> ToolResultPayload
  func refuseUnlessLive(_ session: SessionID) async throws
  func setTags(_ caller: SessionID, of target: SessionID, to tags: [String]) async throws
  func control(_ verb: SessionControl.Verb, _ caller: SessionID, of target: SessionID, force: Bool) async throws
  func capabilityDocument(_ path: String) async throws -> Data?
  func capabilityInput(_ raw: String, as session: SessionID, limit: Int) async throws -> Data
  func recordCompletion(_ metric: InferenceMetric) async throws
  func resolveImageDestination(_ raw: String, session: SessionID) async throws -> Address
  func refuseImageDestination(_ destination: Address, session: SessionID) async throws
  func imageReceipt(_ session: SessionID, call: ToolCallID) async throws -> ToolResultPayload?
  func placeImage(_ image: Data, at destination: Address, session: SessionID, call: ToolCallID?) async throws -> ToolResultPayload
  func append(_ session: SessionID, _ event: SessionEvent) async throws -> MainReply
  func modelRoute(_ session: SessionID) async throws -> SessionModelRoute?
  func record(_ session: SessionID) async throws -> SessionRecord
  func hydrate(_ session: SessionID) async throws -> SessionHydration
  func queueHead(_ session: SessionID) async throws -> Int
  func pendingCommand(_ session: SessionID) async throws -> SessionCommand?
  func registeredSubscriptions(_ session: SessionID) async throws -> RegisteredSubscriptions
  func drainQueue(_ session: SessionID) async throws -> QueueDrain
  func claimCompactRequest(_ session: SessionID, generation: Int) async throws -> CompactRequestClaim?
}
