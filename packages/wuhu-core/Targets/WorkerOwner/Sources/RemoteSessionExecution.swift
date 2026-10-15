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

public struct RemoteSessionExecution: SessionExecutionClient {
  private let rpc: OwnerRPC
  public init(client: WorkerClient) { rpc = .init(client: client) }
  public func wake(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.wake", SessionIDRequest(id: id))
  }

  public func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int {
    let result: Int = try await rpc.call("execution.enqueue", EnqueueRequest(id: id, input: item))
    return result
  }

  public func interrupt(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.interrupt", SessionIDRequest(id: id))
  }

  public func resume(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.resume", SessionIDRequest(id: id))
  }

  public func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool {
    let result: Bool = try await rpc.call("execution.prepare-archive", ReservationRequest(id: id, reservation: reservation))
    return result
  }

  public func releaseArchive(_ id: SessionID, reservation: UUID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.release-archive", ReservationRequest(id: id, reservation: reservation))
  }

  public func archive(_ id: SessionID, reservation: UUID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.archive", ReservationRequest(id: id, reservation: reservation))
  }

  public func unarchive(_ id: SessionID) async throws -> Void {
    let _: Bool = try await rpc.call("execution.unarchive", SessionIDRequest(id: id))
  }

  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    let result: RestartSnapshot = try await rpc.call("execution.restart", RestartRequest(id: id, executor: executor.map(ExecutorSnapshot.init), note: note, modelRoute: modelRoute))
    return try result.restart()
  }

  public func yieldAssignment(_ id: SessionID) async throws {
    try await rpc.client.requireCapability(ExecutionWorkerBootstrap.handoffCapability)
    let _: Bool = try await rpc.call("execution.yield-assignment", SessionIDRequest(id: id))
  }

  public func discard(_ id: SessionID) async {
    _ = try? await rpc.call("execution.discard", SessionIDRequest(id: id)) as Bool
  }

  public func drain() async {
    let (parking, continuation) = AsyncStream<Void>.makeStream()
    for await _ in parking {}
    continuation.finish()
    await shutdown()
  }

  public func shutdown() async {
    let cleanup = Task { [rpc] in
      _ = try? await rpc.call("execution.shutdown", EmptyRequest()) as Bool
    }
    await cleanup.value
  }
}

struct ReservationRequest: Codable, Sendable { let id: SessionID; let reservation: UUID }
