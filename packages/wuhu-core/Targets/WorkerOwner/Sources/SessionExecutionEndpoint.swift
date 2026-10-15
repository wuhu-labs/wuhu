#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import class InferenceKit.AttemptHub
import enum JSONValue.JSONValue
import struct LoopCore.SessionExecution
import protocol LoopCore.SessionExecutionClient
import enum SessionDomain.QueueInput
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import class SessionTools.Scripts
import struct SpaceCore.SessionRestart
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

public struct SessionExecutionEndpoint: Sendable {
  private let execution: any SessionExecutionClient
  private let beforeShutdownReply: @Sendable () async -> Void
  private let scripts: Scripts?
  private let attempts: AttemptHub?
  private let owner: WorkerClient?
  public init(execution: any SessionExecutionClient, scripts: Scripts? = nil, attempts: AttemptHub? = nil, owner: WorkerClient? = nil, beforeShutdownReply: @escaping @Sendable () async -> Void = {}) {
    self.execution = execution; self.scripts = scripts; self.attempts = attempts; self.owner = owner
    self.beforeShutdownReply = beforeShutdownReply
  }

  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation {
      case "execution.inventory":
        guard let execution = execution as? SessionExecution else { throw WorkerProtocolError(.unavailable, message: "Worker inventory is unavailable") }
        let assignments = await execution.inventory()
        let scripts = scripts?.inventory ?? [:]
        let sessions = Set(assignments.map(\.session)).union(scripts.values)
        var inferences: [SessionID: [UUID]] = [:]
        for session in sessions { inferences[session] = attempts?.inFlight(session: session).map(\.key) ?? [] }
        let pending = await owner?.pendingReceipts() ?? []
        return try ownerEncode(WorkerExecutionInventory(assignments: assignments, scripts: scripts, inferences: inferences, pendingOwnerCalls: pending))
      case "execution.wake":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await execution.wake(request.id)
        return .bool(true)
      case "execution.enqueue":
        let request = try ownerDecode(EnqueueRequest.self, call.payload)
        return try await ownerEncode(execution.enqueue(request.input, to: request.id))
      case "execution.interrupt":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await execution.interrupt(request.id)
        return .bool(true)
      case "execution.resume":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await execution.resume(request.id)
        return .bool(true)
      case "execution.prepare-archive":
        let request = try ownerDecode(ReservationRequest.self, call.payload)
        return try await ownerEncode(execution.prepareArchive(request.id, reservation: request.reservation))
      case "execution.release-archive":
        let request = try ownerDecode(ReservationRequest.self, call.payload)
        try await execution.releaseArchive(request.id, reservation: request.reservation)
        return .bool(true)
      case "execution.archive":
        let request = try ownerDecode(ReservationRequest.self, call.payload)
        try await execution.archive(request.id, reservation: request.reservation)
        return .bool(true)
      case "execution.unarchive":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        try await execution.unarchive(request.id)
        return .bool(true)
      case "execution.restart":
        let request = try ownerDecode(RestartRequest.self, call.payload)
        return try ownerEncode(RestartSnapshot(try await execution.restart(request.id, executor: request.executor?.executor(), note: request.note, modelRoute: request.modelRoute)))
      case "execution.discard":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        await execution.discard(request.id)
        return .bool(true)
      case "execution.yield-assignment":
        guard let execution = execution as? SessionExecution else { throw WorkerProtocolError(.unavailable, message: "Assignment handoff is unavailable") }
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        await execution.yieldAssignment(request.id)
        return .bool(true)
      case "execution.shutdown":
        await execution.shutdown()
        await beforeShutdownReply()
        return .bool(true)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown worker execution operation")
      }
    }
  }
}
