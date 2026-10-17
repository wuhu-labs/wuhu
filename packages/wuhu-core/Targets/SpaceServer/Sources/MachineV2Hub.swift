#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchTunnel
import struct MachineContract.MachineID
import struct OperationProtocol.OperationError
import struct SpaceContract.GroupID
import SpaceCore

actor MachineV2Hub {
  struct Credential: Sendable {
    let pubkey: String
    let machines: Set<String>
  }

  struct Route: Sendable {
    let connection: UUID
    let credential: Credential
    let client: FetchClient
    let streams: Int
    let abort: @Sendable () -> Void
  }

  let space: Space
  /// Runs between a self-revoke's verified handshake and its transaction; tests park a revoke here.
  let revocationGate: @Sendable (MachineID) async -> Void
  var routes: [String: Route] = [:]
  private var failure: OperationError?
  init(space: Space, revocationGate: @escaping @Sendable (MachineID) async -> Void = { _ in }) {
    self.space = space
    self.revocationGate = revocationGate
  }

  func fail(_ error: OperationError) {
    failure = error
    let previous = routes.values
    routes = [:]
    for route in previous { route.abort() }
  }

  func checkAvailable() throws { if let failure { throw failure } }

  func authorize(_ credential: Credential) async throws {
    try checkAvailable()
    guard let id = try await space.machine(pubkey: credential.pubkey),
          credential.machines == [id.rawValue],
          let machine = try await space.machine(id),
          try await space.machineV2Members(group: machine.group).contains(id.rawValue)
    else {
      throw OperationError(.machineNotAuthorized)
    }
    try checkAvailable()
  }

  func attach(_ credential: Credential, client: FetchClient, streams: Int = TunnelLimits().streams, abort: @escaping @Sendable () -> Void) async throws -> UUID {
    try await authorize(credential)
    let connection = UUID()
    let replaced = credential.machines.compactMap { routes[$0] }
    for machine in credential.machines { routes[machine] = Route(connection: connection, credential: credential, client: client, streams: streams, abort: abort) }
    for route in replaced { route.abort() }
    return connection
  }

  func remove(_ connection: UUID) {
    routes = routes.filter { $0.value.connection != connection }
  }

  func kick(_ machine: MachineID) {
    guard let route = routes[machine.rawValue] else { return }
    route.abort()
    remove(route.connection)
  }

  /// How many exchanges the machine's live tunnel carries at once; nil without one.
  func streams(_ machine: String) -> Int? { routes[machine]?.streams }

  func fetch(_ request: Request, usableFrom group: GroupID) async throws -> Response {
    try checkAvailable()
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"],
          let machine = try await space.resolveMachine(path[3], usableFrom: group), machine.id.rawValue == path[3],
          try await space.machineV2Members(group: machine.group).contains(path[3]) else { throw OperationError(.unknownMachine) }
    guard let route = routes[path[3]] else {
      guard let evidence = try await space.machineV2PresenceEvidence(path[3], group: machine.group) else { throw OperationError(.unknownMachine) }
      let detached = evidence.state == .detached
      let observed = evidence.observedAt
      throw OperationError(.machineUnavailable, message: "No live Machine v2 tunnel route", details: [
        "state": detached ? "detached" : "lost", "started": false,
        detached ? "leftAt" : "silentSince": .number(observed.timeIntervalSince1970),
      ])
    }
    guard route.credential.machines.contains(path[3]) else { throw OperationError(.machineNotAuthorized) }
    try await authorize(route.credential)
    return try await route.client(request)
  }

  func run(_ credential: Credential, transport: TunnelTransport, streams: Int = TunnelLimits().streams) async {
    do {
      let tunnel = try Tunnel(over: transport, limits: .init(streams: streams))
      let connection = try await attach(credential, client: tunnel.client, streams: streams, abort: transport.abort)
      do { try await tunnel.run() } catch {}
      remove(connection)
    } catch { transport.abort() }
  }
}
