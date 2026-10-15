#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import enum JSONValue.JSONValue
import protocol MachineChannel.FrameTransport
import struct MachineContract.MachineID
import struct SessionDomain.SessionID
import struct SessionTools.ScriptMachineAccess
import protocol SessionTools.ScriptOwnerClient
import enum SpaceTools.ToolRunError
import struct WorkerProtocol.WorkerCall
import struct WorkerProtocol.WorkerProtocolError

actor ParentMachines {
  struct Connection { let transport: any FrameTransport; var streaming = false }
  private var connections: [UUID: Connection] = [:]
  private var stopped = false
  private var connecting = 0

  func invoke(_ call: WorkerCall, owner: any ScriptOwnerClient) async throws -> JSONValue {
    try await ownerReply {
      switch call.operation {
      case "machine.attached":
        let request = try ownerDecode(SessionIDRequest.self, call.payload)
        let access = try access(owner, request.id)
        let usable = try await Set(owner.usableMachines(session: request.id).map(\.id))
        return try await ownerEncode(access.files.attached().intersection(usable))
      case "machine.vfs":
        let request = try ownerDecode(MachineVFSRequest.self, call.payload)
        try await requireMachine(request.machine, session: request.session, owner: owner)
        return try await ownerEncode(access(owner, request.session).files.vfs(request.machine, request.operation))
      case "machine.search":
        let request = try ownerDecode(MachineSearchRequest.self, call.payload)
        try await requireMachine(request.machine, session: request.session, owner: owner)
        return try await ownerEncode(access(owner, request.session).files.search(request.machine, request.query))
      case "machine.mint-script":
        let request = try ownerDecode(ExecMintRequest.self, call.payload)
        try await requireMachine(request.machine, session: request.session, owner: owner)
        return try await ownerEncode(ExecSnapshot(access(owner, request.session).exec.mintScript(request.machine, request.session, request.script)))
      case "machine.claim":
        let request = try ownerDecode(ExecClaimRequest.self, call.payload)
        try await requireMachine(request.machine, session: request.session, owner: owner)
        return try await ownerEncode(ExecClaimSnapshot(access(owner, request.session).exec.claim(request.machine, request.session, request.call)))
      case "machine.status":
        let request = try ownerDecode(ExecAccessRequest.self, call.payload)
        _ = try await owner.ownExecStatus(request.id.rawValue, session: request.session)
        return try await ownerEncode(access(owner, request.session).exec.status(request.id).map(ExecSnapshot.init))
      case "machine.kill":
        let request = try ownerDecode(ExecAccessRequest.self, call.payload)
        let id = try await owner.ownExecToKill(request.id.rawValue, session: request.session)
        try await access(owner, request.session).exec.kill(id)
        return .bool(true)
      case "machine.connect":
        let request = try ownerDecode(ExecAccessRequest.self, call.payload)
        _ = try await owner.ownExecStatus(request.id.rawValue, session: request.session)
        guard !stopped else { throw WorkerProtocolError(.unavailable, message: "Machine incarnation is closed") }
        guard connections.count + connecting < 1024 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many machine connections") }
        connecting += 1
        defer { connecting -= 1 }
        let transport = try await access(owner, request.session).exec.connect(request.id)
        guard !stopped else { transport.close(); throw CancellationError() }
        if Task.isCancelled { transport.close(); throw CancellationError() }
        let id = call.id
        connections[id] = .init(transport: transport)
        return try ownerEncode(id)
      case "machine.send":
        let request = try ownerDecode(FrameRequest.self, call.payload)
        guard let connection = connections[request.id] else { throw WorkerProtocolError(.invalidMessage, message: "Unknown machine connection") }
        try await connection.transport.send(Array(request.frame))
        return .bool(true)
      case "machine.close":
        let request = try ownerDecode(StreamRequest.self, call.payload)
        connections.removeValue(forKey: request.id)?.transport.close()
        return .bool(true)
      default: throw WorkerProtocolError(.invalidMessage, message: "Unknown parent machine operation")
      }
    }
  }

  func stream(_ id: UUID) throws -> Body {
    guard let connection = connections[id], !connection.streaming else { throw WorkerProtocolError(.invalidMessage, message: "Unknown machine stream") }
    connections[id]?.streaming = true
    return .stream(ParentMachineFrames(transport: connection.transport, finished: { await self.cancel(id) }))
  }

  func cancel(_ id: UUID) { connections.removeValue(forKey: id)?.transport.close() }

  func stop() {
    stopped = true
    for connection in connections.values { connection.transport.close() }
    connections.removeAll()
  }

  private func access(_ owner: any ScriptOwnerClient, _ session: SessionID) throws -> ScriptMachineAccess {
    guard let result = owner.scriptMachines(for: session) else { throw ToolRunError.failed(code: .unavailable, message: "Machine access is unavailable", hint: nil) }
    return result
  }

  private func requireMachine(_ machine: MachineID, session: SessionID, owner: any ScriptOwnerClient) async throws {
    guard try await owner.resolveMachine(machine.rawValue, session: session) != nil else { throw ToolRunError.failed(code: .notFound, message: "Unknown machine", hint: nil) }
  }
}

private struct ParentMachineFrames: AsyncSequence, Sendable {
  typealias Element = Data
  let transport: any FrameTransport
  let finished: @Sendable () async -> Void
  struct AsyncIterator: AsyncIteratorProtocol {
    let transport: any FrameTransport
    let finished: @Sendable () async -> Void
    var source: AsyncStream<[UInt8]>.Iterator
    var ended = false
    mutating func next() async throws -> Data? {
      guard !ended else { return nil }
      let record: OwnerRecord
      if let frame = await source.next() {
        record = try .init(value: ownerEncode(Data(frame)), fault: nil, ended: false)
      } else {
        ended = true
        transport.close()
        await finished()
        try Task.checkCancellation()
        record = .init(value: nil, fault: nil, ended: true)
      }
      var data = try JSONEncoder().encode(record)
      data.append(0x0A)
      return data
    }
  }

  func makeAsyncIterator() -> AsyncIterator { .init(transport: transport, finished: finished, source: transport.inbound.makeAsyncIterator()) }
}
