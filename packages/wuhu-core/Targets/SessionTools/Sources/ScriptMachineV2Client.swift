#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationClient.OperationOwner
import OperationProtocol

public struct ScriptMachineV2Client: Sendable {
  private let describeMachine: @Sendable (String) async throws -> MachineDescription
  private let startOperation: @Sendable (String, StartRequest, OperationOwner, Duration?, @Sendable (UUID) -> Void) async throws -> UUID
  private let reconcileOperation: @Sendable (UUID, Int) async throws -> OperationSnapshot
  private let pollOperation: @Sendable (UUID, String?, Int, Bool) async throws -> OperationSnapshot
  private let consumeOutput: @Sendable (UUID, String) async throws -> [ChannelPayload]
  private let writeInput: @Sendable (UUID, String, ChannelPayload, Bool) async throws -> WriteReceipt
  private let stopOperation: @Sendable (UUID, String) async throws -> OperationSnapshot

  public init(
    describe: @escaping @Sendable (String) async throws -> MachineDescription,
    start: @escaping @Sendable (String, StartRequest, OperationOwner, Duration?, @Sendable (UUID) -> Void) async throws -> UUID,
    reconcile: @escaping @Sendable (UUID, Int) async throws -> OperationSnapshot,
    poll: @escaping @Sendable (UUID, String?, Int, Bool) async throws -> OperationSnapshot,
    takeOutput: @escaping @Sendable (UUID, String) async throws -> [ChannelPayload],
    write: @escaping @Sendable (UUID, String, ChannelPayload, Bool) async throws -> WriteReceipt,
    stop: @escaping @Sendable (UUID, String) async throws -> OperationSnapshot,
  ) {
    describeMachine = describe; startOperation = start; reconcileOperation = reconcile
    pollOperation = poll; consumeOutput = takeOutput; writeInput = write; stopOperation = stop
  }

  public func describe(_ machine: String) async throws -> MachineDescription { try await describeMachine(machine) }
  public func start(_ machine: String, request: StartRequest, owner: OperationOwner, timeout: Duration? = nil, onClaim: @Sendable (UUID) -> Void = { _ in }) async throws -> UUID {
    try await startOperation(machine, request, owner, timeout, onClaim)
  }

  public func reconcile(_ id: UUID, holdMs: Int = 0) async throws -> OperationSnapshot { try await reconcileOperation(id, holdMs) }
  public func poll(_ id: UUID, channel: String? = nil, holdMs: Int = 0, terminalAck: Bool = false) async throws -> OperationSnapshot { try await pollOperation(id, channel, holdMs, terminalAck) }
  public func takeOutput(_ id: UUID, channel: String) async throws -> [ChannelPayload] { try await consumeOutput(id, channel) }
  public func write(_ id: UUID, channel: String, payload: ChannelPayload, end: Bool = false) async throws -> WriteReceipt { try await writeInput(id, channel, payload, end) }
  public func stop(_ id: UUID, reason: String) async throws -> OperationSnapshot { try await stopOperation(id, reason) }
}
