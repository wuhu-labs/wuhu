#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FetchTunnel
import enum MachineContract.MachineV2Connect
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import SpaceCore

extension MachineHub {
  struct Credential: Sendable {
    let pubkey: String
    let machines: Set<String>
  }

  func authorize(_ credential: Credential) async throws {
    guard let id = try await space.machine(pubkey: credential.pubkey),
          credential.machines == [id.rawValue],
          let machine = try await space.machine(id),
          try await space.machineV2Members(group: machine.group).contains(id.rawValue)
    else { throw OperationError(.machineNotAuthorized) }
  }

  func boxLink(_ credential: Credential, streams: Int) -> BoxLink? {
    let machine = credential.machines.first!
    return BoxLink(worker: space.worker, machine: machine, pubkey: credential.pubkey, connection: UUID(), streams: streams, buffers: space.machineBuffers, authorizeStart: {
      try await self.authorize(credential)
    }, prepare: { exec in
      try await self.prepare(exec, machine: machine)
    })
  }

  func run(_ credential: Credential, transport: TunnelTransport, boxLink: BoxLink, streams: Int = TunnelLimits().streams) async {
    defer { boxLink.close() }
    do {
      try await authorize(credential)
      let tunnel = try Tunnel(over: transport, limits: .init(bodyBytes: OperationLimits.maxFileResponseBytes, streams: streams))
      await withTaskGroup(of: Void.self) { tasks in
        tasks.addTask { try? await tunnel.run() }
        tasks.addTask { await boxLink.run(client: tunnel.client) }
        _ = await tasks.next()
        tasks.cancelAll(); boxLink.close(); transport.abort()
      }
    } catch { transport.abort() }
  }
}
