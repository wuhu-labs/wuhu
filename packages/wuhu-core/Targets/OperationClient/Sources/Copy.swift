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

/// One file, from a machine or the caller's bytes to a machine or back to the caller, over transient operations: a `read.v1`
/// pinned to the version a `stat.v1` found, feeding a `stagedWrite.v1` chunk by chunk as the read delivers them. Nothing touches
/// the operation store. A failure abandons both operations, and an abandoned staged write removes its stage.
public func copyFile(
  from source: CopySource,
  to target: CopyTarget,
  caller: StartRequest.Caller? = nil,
  operations: @Sendable (MachineID) async throws -> MachineOperations,
) async throws -> CopyReceipt {
  let scope = "machine-copy/" + UUID().uuidString
  let size: Int
  let pinned: (operations: MachineOperations, machine: MachineID, path: String, token: String)?
  switch source {
  case let .bytes(bytes): size = bytes.count; pinned = nil
  case let .machine(machine, path):
    let files = try await operations(machine)
    let entry = try await refusing(.source, machine) {
      try decodeEntry(await files.call(machine.rawValue, .init(scope: scope, key: "stat"), .init(kind: "stat.v1", input: ["path": .string(path)], caller: caller), transient: true))
    }
    guard entry.kind == .file else { throw CopyRefusal.sourceNotAFile }
    size = entry.size
    pinned = (files, machine, path, entry.token)
  }
  let sink: (operation: Operation, machine: MachineID)?
  var collected: [UInt8] = []
  switch target {
  case let .caller(limit):
    guard size <= limit else { throw CopyRefusal.sourceTooLarge(size: size, limit: limit) }
    collected.reserveCapacity(size)
    sink = nil
  case let .machine(machine, path, replace):
    let files = try await operations(machine)
    let start = StartRequest(kind: "stagedWrite.v1", input: object(["path": .string(path), "replace": .bool(replace)]), caller: caller)
    let operation = try await refusing(.target, machine) { try await files.transient(.init(scope: scope, key: "target"), machine: machine.rawValue, start: start) }
    sink = (operation, machine)
  }
  do {
    var hash = SHA256()
    var count = 0
    func land(_ data: Data) async throws {
      try Task.checkCancellation()
      guard data.count <= size - count else { throw CopyRefusal.sourceChanged }
      hash.update(data: data); count += data.count
      if let sink { try await deliver(sink.operation, sink.machine, "data", .init(data: data)) } else { collected += data }
    }
    switch source {
    case let .bytes(bytes):
      for offset in stride(from: 0, to: bytes.count, by: 64 * 1024) { try await land(Data(bytes[offset ..< min(bytes.count, offset + 64 * 1024)])) }
    case .machine:
      let read = pinned!
      let start = StartRequest(kind: "read.v1", input: object(["path": .string(read.path), "ifMatch": .string(read.token)]), caller: caller)
      _ = try await refusing(.source, read.machine, pinned: true) {
        try await read.operations.call(read.machine.rawValue, .init(scope: scope, key: "source"), start, transient: true) { payload in
          guard let data = payload.data else { throw OperationError(.invalidResponse) }
          try await land(data)
        }
      }
    }
    guard count == size else { throw CopyRefusal.sourceChanged }
    let sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard let sink else { return CopyReceipt(bytes: count, sha256: sha256, landing: .caller(collected)) }
    try await deliver(sink.operation, sink.machine, "data", .init(data: Data()), end: true)
    try await deliver(sink.operation, sink.machine, "commit", .init(records: [object(["bytes": .string(String(count)), "sha256": .string(sha256)])]), end: true)
    let token = try await refusing(.target, sink.machine) { try version(MachineOperations.result(await sink.operation.verdict(), operation: sink.operation.id)) }
    return CopyReceipt(bytes: count, sha256: sha256, landing: .machine(token: token))
  } catch {
    try? await sink?.operation.abandon("copyFailed")
    throw error
  }
}

/// A write to the staged target; once the target has ended, its verdict says why.
private func deliver(_ operation: Operation, _ machine: MachineID, _ channel: String, _ payload: ChannelPayload, end: Bool = false) async throws {
  try await refusing(.target, machine) {
    do { try await operation.write(channel, payload, end: end) } catch let error as OperationError where error.code == .operationEnded {
      _ = try MachineOperations.result(await operation.verdict(), operation: operation.id)
      throw error
    }
  }
}

/// `body`, with what the machine at `end` said about its file turned into the copy's refusal. Once `pinned` to a version the
/// source was seen at, a source gone or no longer a file has changed.
private func refusing<T>(_ end: CopyRefusal.End, _ machine: MachineID, pinned: Bool = false, _ body: () async throws -> T) async throws -> T {
  do { return try await body() } catch let error as OperationError {
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
