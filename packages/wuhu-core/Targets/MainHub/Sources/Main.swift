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
  func principal(of session: SessionID) async throws -> Principal
  func usableMachines(session: SessionID) async throws -> [MachineRecord]
  func resolveMachine(_ reference: String, session: SessionID) async throws -> MachineRecord?
  func ownExecs(session: SessionID) async throws -> [ExecStatus]
  func ownExecStatus(_ id: String, session: SessionID) async throws -> ExecStatus
  func releaseScriptExecs(script: String) async throws
  /// For each urgency, the earliest item in the session's queue that the
  /// model has not seen yet: now, and again after every change.
  func owedExecs() async throws -> [ExecRecord]
  func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error>
  // Scripts' exec transport and operator verbs remain main's; per-call exec
  // jobs and tool dispatch belong to the worker.
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
