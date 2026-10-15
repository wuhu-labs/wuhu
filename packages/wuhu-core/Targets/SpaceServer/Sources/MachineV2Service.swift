#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import struct Fetch.FetchClient
import enum JSONValue.JSONValue
import MachineChannel
import class OperationClient.OperationClient
import struct OperationClient.OperationOwner
import struct OperationProtocol.OperationError
import struct SessionDomain.SessionID
import struct SpaceContract.GroupID
import struct SpaceCore.ExecRecord
import class SpaceCore.Space

actor MachineV2Service {
  struct ExecEndpoint {
    let endpoint: ChannelEndpoint
    var callers: Set<UUID> = []
    var disconnected: Date?
    var completed: Date?
  }

  var execEndpoints: [String: ExecEndpoint] = [:]
  var execOperations: [String: UUID] = [:]
  var killedExecs: Set<String> = []
  enum ExecJob: Sendable {
    case caller(MachineV2ExecRelay)
    case minted(ExecRecord, Space)
  }

  let relays = AsyncStream<ExecJob>.makeStream()
  private let hub: MachineV2Hub
  private let coordinator: MachineV2Coordinator?
  private var failure: OperationError?

  init(hub: MachineV2Hub, coordinator: MachineV2Coordinator?, failure: OperationError?) {
    self.hub = hub; self.coordinator = coordinator; self.failure = failure
  }

  static func open(space: Space, hub: MachineV2Hub, directory: URL) async -> MachineV2Service {
    var coordinator: MachineV2Coordinator?
    do {
      let key = try await MachineV2KeyStore.loadOrCreate(directory: directory, space: space)
      let prepared = MachineV2Coordinator(space: space, key: key, problemsGroup: .shared, origin: URL(string: "https://machine-v2.internal")!, fetch: { group in
        FetchClient { request in try await hub.fetch(request, usableFrom: group) }
      }, abort: { _, _ in })
      coordinator = prepared
      try await prepared.prepare()
      return .init(hub: hub, coordinator: prepared, failure: nil)
    } catch {
      await coordinator?.shutdown()
      let failure = unavailable(error)
      await hub.fail(failure)
      return .init(hub: hub, coordinator: nil, failure: failure)
    }
  }

  func credential(tokens: ExecTokens, session: SessionID, group: GroupID, owner: OperationOwner, timeout: Duration) async throws -> JSONValue {
    if let failure { throw failure }
    guard let coordinator else { throw OperationError(.storeUnavailable) }
    let previouslyIssued = try await coordinator.credentialIssued(group: group, owner: owner)
    @Dependency(\.date) var date
    return try tokens.credential(session: session, group: group, scope: owner.scope, key: owner.key, timeout: timeout, now: date.now, previouslyIssued: previouslyIssued, reserveAttempt: true, active: {
      try await coordinator.credentialActive(group: group, owner: owner)
    })
  }

  func client(group: GroupID) async throws -> OperationClient {
    if let failure { throw failure }
    guard let coordinator else { throw OperationError(.storeUnavailable) }
    let client = try await coordinator.client(group: group)
    if let failure { throw failure }
    return client
  }

  func run() async throws {
    guard let coordinator else { return }
    do {
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { try await coordinator.run() }
        tasks.addTask {
          await withDiscardingTaskGroup { relays in
            for await job in self.relays.stream {
              relays.addTask {
                switch job {
                case let .caller(relay): await self.serveExec(relay)
                case let .minted(record, space): await self.expireUnconnected(record, space: space)
                }
              }
            }
            relays.cancelAll()
          }
        }
        while try await tasks.next() != nil {}
      }
    } catch is CancellationError { throw CancellationError() }
    catch {
      let error = Self.unavailable(error)
      failure = error
      await hub.fail(error)
      throw error
    }
  }

  func shutdown() async { relays.continuation.finish(); await coordinator?.shutdown() }

  private static func unavailable(_ error: any Error) -> OperationError {
    if let error = error as? OperationError { return error }
    return OperationError(.storeUnavailable, message: "Machine v2 durable state is unavailable")
  }
}
