#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import protocol LoopCore.SessionExecutionClient
import enum SessionDomain.QueueInput
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import struct SpaceCore.SessionRestart
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerClient
import struct WorkerProtocol.WorkerProtocolError

public struct SessionExecutionEndpoint: Sendable {
  private let execution: any SessionExecutionClient
  public init(execution: any SessionExecutionClient) { self.execution = execution }
  public func invoke(_ call: WorkerCall) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation {
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
      case "execution.shutdown":
        await execution.shutdown()
        return .bool(true)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown worker execution operation")
      }
    }
  }
}
