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
  /// The session's execs whose ends it is still owed.
  func owedExecs(_ session: SessionID) async throws -> [ExecRecord]
  /// For each urgency, the earliest item in the session's queue that the
  /// model has not seen yet: now, and again after every change.
  func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error>
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
