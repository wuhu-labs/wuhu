#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FetchTunnel
import enum MachineContract.MachineV2Connect
import MachinesContract
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits

extension MachineHub {
  struct Credential: Sendable {
    let pubkey: String
    let machines: Set<String>
  }

  func authorize(_ credential: Credential) async throws {
    guard let id = try await machines.machine(pubkey: credential.pubkey),
          credential.machines == [id.rawValue],
          let machine = try await machines.machine(id),
          try await machines.machineV2Members(group: machine.group).contains(id.rawValue)
    else { throw OperationError(.machineNotAuthorized) }
  }

  func boxLink(_ credential: Credential, streams: Int) async -> BoxLink? {
    let machine = credential.machines.first!
    return await BoxLink(worker: machines.worker, machine: machine, pubkey: credential.pubkey, connection: UUID(), streams: streams, buffers: machines.buffers, authorizeStart: {
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
