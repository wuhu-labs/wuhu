#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import protocol MachineChannel.FrameTransport
import struct MachineContract.MachineID
import enum MachineContract.SearchResult
import enum MachineContract.VFSResult
import struct SessionDomain.SessionID
import struct SessionTools.ExecBackend
import struct SessionTools.ScriptMachineAccess
import struct SpaceCore.ExecClaim
import struct SpaceCore.ExecRecord
import struct SpaceTools.MachineSeam
import struct WorkerProtocol.WorkerCall

extension RemoteExecutionOwner {
  public func scriptMachines(for session: SessionID) -> ScriptMachineAccess? {
    guard machinesEnabled else { return nil }
    let files = MachineSeam(vfs: { [rpc] machine, operation in
      try await rpc.call("machine.vfs", MachineVFSRequest(session: session, machine: machine, operation: operation)) as VFSResult
    }, search: { [rpc] machine, query in
      try await rpc.call("machine.search", MachineSearchRequest(session: session, machine: machine, query: query)) as SearchResult
    }, attached: { [rpc] in
      (try? await rpc.call("machine.attached", SessionIDRequest(id: session))) ?? Set<MachineID>()
    })
    let exec = ExecBackend(claim: { [rpc] machine, caller, call in
      let result: ExecClaimSnapshot = try await rpc.call("machine.claim", ExecClaimRequest(session: caller, machine: machine, call: call))
      return try result.value()
    }, connect: { [rpc] id in
      let connection: UUID = try await rpc.call("machine.connect", ExecAccessRequest(session: session, id: id))
      let body = try await rpc.client.stream(WorkerCall(operation: "machine.frames", payload: ownerEncode(StreamRequest(id: connection))))
      let reader = OwnerRecordReader<Data>(body)
      let inbound = AsyncStream<[UInt8]>(unfolding: {
        do { return try await reader.next().map(Array.init) }
        catch { return nil }
      })
      return RemoteMachineFrames(rpc: rpc, id: connection, inbound: inbound)
    }, status: { [rpc] id in
      let result: ExecSnapshot? = try await rpc.call("machine.status", ExecAccessRequest(session: session, id: id))
      return try result?.value()
    }, mintScript: { [rpc] machine, caller, script in
      let result: ExecSnapshot = try await rpc.call("machine.mint-script", ExecMintRequest(session: caller, machine: machine, script: script))
      return try result.value()
    }, kill: { [rpc] id in
      let _: Bool = try await rpc.call("machine.kill", ExecAccessRequest(session: session, id: id))
    })
    return .init(files: files, exec: exec)
  }
}

private struct RemoteMachineFrames: FrameTransport {
  let rpc: OwnerRPC
  let id: UUID
  let inbound: AsyncStream<[UInt8]>
  func send(_ frame: [UInt8]) async throws {
    let _: Bool = try await rpc.call("machine.send", FrameRequest(id: id, frame: Data(frame)))
  }

  func close() {
    Task { let _: Bool? = try? await rpc.call("machine.close", StreamRequest(id: id)) }
  }
}
