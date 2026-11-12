#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import enum JSONValue.JSONValue
import struct MachineContract.CopyReceipt
import enum MachineContract.CopyRefusal
import enum MachineContract.CopySource
import enum MachineContract.CopyTarget
import struct MachineContract.MachineID
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import SpaceCore

struct MachineFileTransfer: Sendable {
  let space: Space
  let caller: StartRequest.Caller?

  nonisolated(nonsending) func copy(from source: CopySource, to target: CopyTarget) async throws -> CopyReceipt {
    let size: Int
    let pinned: (client: MachineFileClient, path: String, token: String)?
    switch source {
    case let .bytes(bytes): size = bytes.count; pinned = nil
    case let .machine(machine, path):
      let client = MachineFileClient(space: space, machine: machine, caller: caller)
      let entry = try await refusing(.source, machine) {
        try decodeEntry(await client.call(.init(kind: "stat.v1", input: ["path": .string(path)], caller: caller)))
      }
      guard entry.kind == .file else { throw CopyRefusal.sourceNotAFile }
      size = entry.size
      pinned = (client, path, entry.token)
    }
    let sink: (connection: MachineFileConnection, machine: MachineID)?
    var collected: [UInt8] = []
    switch target {
    case let .caller(limit):
      guard size <= limit else { throw CopyRefusal.sourceTooLarge(size: size, limit: limit) }
      collected.reserveCapacity(size)
      sink = nil
    case let .machine(machine, path, replace):
      let client = MachineFileClient(space: space, machine: machine, caller: caller)
      let start = StartRequest(kind: "stagedWrite.v1", input: object(["path": .string(path), "replace": .bool(replace)]), caller: caller)
      sink = (try client.connect(start), machine)
    }
    defer { sink?.connection.close() }
    if let sink { try await refusing(.target, sink.machine) { try await sink.connection.ready() } }
    var hash = SHA256()
    var count = 0
    func land(_ data: Data) async throws {
      try Task.checkCancellation()
      guard data.count <= size - count else { throw CopyRefusal.sourceChanged }
      hash.update(data: data); count += data.count
      if let sink { try await deliver(sink.connection, sink.machine, "data", .init(data: data)) }
      else { collected += data }
    }
    switch source {
    case let .bytes(bytes):
      for offset in stride(from: 0, to: bytes.count, by: 65536) {
        try await land(Data(bytes[offset ..< min(bytes.count, offset + 65536)]))
      }
    case .machine:
      let read = pinned!
      let start = StartRequest(kind: "read.v1", input: object(["path": .string(read.path), "ifMatch": .string(read.token)]), caller: caller)
      if sink != nil {
        try await readAhead(read.client, start: start, consume: land)
      } else {
        _ = try await refusing(.source, read.client.machine, pinned: true) {
          try await read.client.call(start) { payload in
            guard let data = payload.data else { throw OperationError(.invalidResponse) }
            try await land(data)
          }
        }
      }
    }
    guard count == size else { throw CopyRefusal.sourceChanged }
    let sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard let sink else { return CopyReceipt(bytes: count, sha256: sha256, landing: .caller(collected)) }
    try await deliver(sink.connection, sink.machine, "data", .init(data: Data()), end: true)
    let token = try await refusing(.target, sink.machine) {
      do { try await sink.connection.write("commit", .init(records: [object(["bytes": .string(String(count)), "sha256": .string(sha256)])]), end: true) }
      catch let error as OperationError where error.code == .operationEnded {}
      return try machineFileVersion(await sink.connection.result())
    }
    return CopyReceipt(bytes: count, sha256: sha256, landing: .machine(token: token))
  }
}

private nonisolated(nonsending) func deliver(_ connection: MachineFileConnection, _ machine: MachineID, _ channel: String, _ payload: ChannelPayload, end: Bool = false) async throws {
  try await refusing(.target, machine) {
    do { try await connection.write(channel, payload, end: end) }
    catch let error as OperationError where error.code == .operationEnded {
      _ = try await connection.result()
      throw error
    }
  }
}

private nonisolated(nonsending) func refusing<T>(_ end: CopyRefusal.End, _ machine: MachineID, pinned: Bool = false, _ body: () async throws -> T) async throws -> T {
  do { return try await body() }
  catch let error as OperationError {
    switch error.code {
    case .unknownKind, .kindUnavailable: throw CopyRefusal.unsupported(machine)
    case .fileChanged where end == .source: throw CopyRefusal.sourceChanged
    case .fileUnavailable:
      guard case let .object(details)? = error.details, let number = details["errno"]?.intValue else {
        throw end == .source ? pinned ? CopyRefusal.sourceChanged : CopyRefusal.sourceNotAFile : error
      }
      if details["lookup"] == .bool(true) || number == 2 { throw pinned ? CopyRefusal.sourceChanged : CopyRefusal.missing(end) }
      if number == 17, end == .target { throw CopyRefusal.targetExists }
      throw CopyRefusal.io(end, errno: number)
    default: throw error
    }
  }
}

nonisolated(nonsending) func readAhead(_ client: MachineFileClient, start: StartRequest, consume: (Data) async throws -> Void) async throws {
  let chunks = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let demand = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
  try await withThrowingTaskGroup(of: Void.self) { group in
    defer {
      group.cancelAll()
      demand.continuation.finish()
      chunks.continuation.finish()
    }
    group.addTask {
      var requested = demand.stream.makeAsyncIterator()
      do {
        _ = try await refusing(.source, client.machine, pinned: true) {
          try await client.call(start) { payload in
            guard let data = payload.data else { throw OperationError(.invalidResponse) }
            precondition(data.count <= 65536)
            switch chunks.continuation.yield(data) {
            case .enqueued: break
            case .terminated: throw CancellationError()
            case .dropped: preconditionFailure("Source advanced without copy demand")
            @unknown default: preconditionFailure("Unknown copy stream result")
            }
            _ = await requested.next()
            try Task.checkCancellation()
          }
        }
        chunks.continuation.finish()
      } catch {
        chunks.continuation.finish(throwing: error)
        throw error
      }
    }
    for try await chunk in chunks.stream {
      demand.continuation.yield(())
      try await consume(chunk)
    }
    try await group.waitForAll()
  }
}
