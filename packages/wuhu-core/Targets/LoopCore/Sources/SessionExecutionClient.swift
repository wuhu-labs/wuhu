#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum SessionDomain.QueueInput
import enum SessionDomain.SessionExecutor
import struct SessionDomain.SessionID
import struct SessionDomain.SessionModelRoute
import protocol SpaceCore.SessionExecutionOwnerClient
import struct SpaceCore.SessionRestart

public protocol SessionExecutionClient: Sendable {
  func wake(_ id: SessionID) async throws
  func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int
  func interrupt(_ id: SessionID) async throws
  func resume(_ id: SessionID) async throws
  func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool
  func releaseArchive(_ id: SessionID, reservation: UUID) async throws
  func archive(_ id: SessionID, reservation: UUID) async throws
  func unarchive(_ id: SessionID) async throws
  func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart
  func discard(_ id: SessionID) async
  func drain() async
  func shutdown() async
}

public struct SessionExecution: SessionExecutionClient {
  let registry: SessionRegistry
  private let liveness = LivenessTracker()

  public init(owner: any SessionExecutionOwnerClient, loopConfig: LoopConfig) async {
    await self.init(makeRepo: { SessionRepo(owner: owner, id: $0) }, loopConfig: loopConfig)
  }

  init(makeRepo: @escaping @Sendable (SessionID) -> SessionRepo, loopConfig: LoopConfig) async {
    registry = SessionRegistry(makeRepo: makeRepo, loopConfig: loopConfig, liveness: liveness)
    await registry.activate()
  }

  private func send(_ action: SessionActor.ExternalAction, to id: SessionID) {
    Task { [registry] in await registry.post(action, to: id) }
  }

  public func wake(_ id: SessionID) async throws {
    try await withCallback(of: Void.self) { send(.wake($0), to: id) }
  }

  public func enqueue(_ item: QueueInput, to id: SessionID) async throws -> Int {
    try await withCallback(of: Int.self) { send(.enqueue(item, $0), to: id) }
  }

  public func interrupt(_ id: SessionID) async throws {
    try await withCallback(of: Void.self) { send(.interrupt($0), to: id) }
  }

  public func resume(_ id: SessionID) async throws {
    try await withCallback(of: Void.self) { send(.resume($0), to: id) }
  }

  public func prepareArchive(_ id: SessionID, reservation: UUID) async throws -> Bool {
    try await withCallback(of: Bool.self) { send(.prepareArchive(reservation, $0), to: id) }
  }

  public func releaseArchive(_ id: SessionID, reservation: UUID) async throws {
    try await withCallback(of: Void.self) { send(.releaseArchive(reservation, $0), to: id) }
  }

  public func archive(_ id: SessionID, reservation: UUID) async throws {
    try await withCallback(of: Void.self) { send(.archive(reservation, $0), to: id) }
  }

  public func unarchive(_ id: SessionID) async throws {
    try await withCallback(of: Void.self) { send(.unarchive($0), to: id) }
  }

  public func restart(_ id: SessionID, executor: SessionExecutor?, note: String?, modelRoute: SessionModelRoute?) async throws -> SessionRestart {
    try await withCallback(of: SessionRestart.self) { send(.restart(executor, note, modelRoute, $0), to: id) }
  }

  public func discard(_ id: SessionID) async { await registry.discard(id) }
  public func drain() async { await liveness.drain() }
  public func shutdown() async { await registry.stop() }
}
