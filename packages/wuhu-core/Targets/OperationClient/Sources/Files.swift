#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import enum JSONValue.JSONValue
import struct MachineContract.MachineEntry
import struct MachineContract.MachineError
import enum MachineContract.MachineErrorCode
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import struct OperationProtocol.Verdict

public extension MachineOperations {
  /// One file call on a machine, mapped to the VFS contract: file-level failures are `.error` results, everything else throws.
  func vfs(machine: String, op: VFSOp, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws -> VFSResult {
    do {
      switch op {
      case let .stat(path):
        return try await .entry(entry: stat(machine: machine, path: path, owner: owner, caller: caller))
      case let .ls(path):
        return try await .entries(entries: list(machine: machine, path: path, owner: owner, caller: caller))
      case let .write(path, data, token):
        return try await .written(token: writeFile(machine: machine, path: path, data: Data(data.bytes), ifMatch: token, owner: owner, caller: caller))
      case let .mkdir(path):
        try await mkdir(machine: machine, path: path, owner: owner, caller: caller)
        return .ok
      case let .rm(path, token):
        try await remove(machine: machine, path: path, ifMatch: token, owner: owner, caller: caller)
        return .ok
      case let .mv(from, to):
        try await move(machine: machine, from: from, to: to, owner: owner, caller: caller)
        return .ok
      case let .read(path, offset, length):
        guard (offset ?? 0) >= 0, (length ?? 0) >= 0 else { return .error(error: .init(code: .invalidArgument, message: "Read range must not be negative")) }
        if let length, length > VFSDefaults.maxReadBytes { return .error(error: .init(code: .tooLarge, message: "Read exceeds the wire bound")) }
        let (token, bytes) = try await readFile(machine: machine, path: path, offset: offset ?? 0, length: length, owner: owner, caller: caller)
        return .file(token: token, data: .init([UInt8](bytes)))
      }
    } catch let error as OperationError {
      let code: MachineErrorCode
      switch error.code {
      case .fileChanged: code = .conflict
      case .invalidInput: code = .invalidArgument
      case .resultTooLarge, .inputTooLarge, .recordTooLarge: code = .tooLarge
      case .fileUnavailable:
        if case let .object(fields)? = error.details, let number = fields["errno"]?.intValue {
          code = fields["lookup"] == .bool(true) ? .notFound : (number == 17 ? .conflict : .io)
        } else { code = .io }
      default: throw error
      }
      return .error(error: MachineError(code: code, message: error.message.isEmpty ? error.code.rawValue : error.message))
    }
  }

  internal func stat(machine: String, path: String, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws -> MachineEntry {
    try await decodeEntry(call(machine, owner, .init(kind: "stat.v1", input: ["path": .string(path)], caller: caller)))
  }

  internal func list(machine: String, path: String, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws -> [MachineEntry] {
    var entries: [MachineEntry] = []
    var bytes = 0
    _ = try await call(machine, owner, .init(kind: "list.v1", input: ["path": .string(path)], caller: caller)) { payload in
      for record in payload.records ?? [] {
        bytes += record.jsonString().utf8.count
        guard bytes <= VFSDefaults.maxReadBytes else { throw OperationError(.resultTooLarge) }
        try entries.append(decodeEntry(record))
      }
    }
    return entries.sorted { $0.name < $1.name }
  }

  internal func mkdir(machine: String, path: String, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws {
    _ = try await call(machine, owner, .init(kind: "mkdir.v1", input: ["path": .string(path)], caller: caller))
  }

  internal func remove(machine: String, path: String, ifMatch: String? = nil, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws {
    var input: [String: JSONValue] = ["path": .string(path)]
    if let ifMatch { input["ifMatch"] = .string(ifMatch) }
    _ = try await call(machine, owner, .init(kind: "remove.v1", input: object(input), caller: caller))
  }

  internal func move(machine: String, from: String, to: String, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws {
    _ = try await call(machine, owner, .init(kind: "move.v1", input: ["from": .string(from), "to": .string(to)], caller: caller))
  }

  internal func readFile(machine: String, path: String, offset: Int = 0, length: Int? = nil, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws -> (token: String, data: Data) {
    var input: [String: JSONValue] = ["path": .string(path), "offset": .string(String(offset))]
    if let length { input["length"] = .string(String(length)) }
    var bytes = Data()
    let result = try await call(machine, owner, .init(kind: "read.v1", input: object(input), caller: caller)) { payload in
      guard let chunk = payload.data, chunk.count <= VFSDefaults.maxReadBytes - bytes.count else { throw OperationError(.resultTooLarge) }
      bytes.append(chunk)
    }
    return try (version(result), bytes)
  }

  internal func writeFile(machine: String, path: String, data: Data, ifMatch: String? = nil, owner: OperationOwner, caller: StartRequest.Caller? = nil) async throws -> String {
    var input: [String: JSONValue] = [
      "path": .string(path), "bytes": .string(String(data.count)), "digest": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
    ]
    if let ifMatch { input["ifMatch"] = .string(ifMatch) }
    let operation = try await open(owner, machine: machine, start: .init(kind: "write.v1", input: object(input), caller: caller))
    return try await settle(operation) {
      let window = await operation.record.inputChannels.first { $0.name == "data" }?.windowBytes ?? 0
      let step = max(1, min(window, 64 * 1024))
      var offset = 0
      repeat {
        let end = min(data.count, offset + step)
        do {
          try await operation.write("data", .init(data: data.subdata(in: offset ..< end)), end: end == data.count)
        } catch let error as OperationError where error.code == .operationEnded { break }
        offset = end
      } while offset < data.count
      return try await version(MachineOperations.result(operation.verdict(), operation: operation.id))
    }
  }

  /// Opens the call, hands every output chunk to `consume` in order, acknowledging it, and returns the completed result.
  func call(_ machine: String, _ owner: OperationOwner, _ start: StartRequest, consume: (ChannelPayload) throws -> Void = { _ in }) async throws -> JSONValue {
    let operation = try await open(owner, machine: machine, start: start)
    return try await settle(operation) {
      var after: UInt64?
      while let chunks = try await operation.output(after: after) {
        for chunk in chunks {
          try consume(chunk.payload)
          try await operation.acknowledge(chunk)
          after = chunk.sequence
        }
      }
      return try await MachineOperations.result(operation.verdict(), operation: operation.id)
    }
  }

  /// A call that fails on this side abandons its operation: nobody is left to read it.
  private func settle<T>(_ operation: Operation, _ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch {
      try? await operation.abandon("fileCallFailed")
      throw error
    }
  }

  internal static func result(_ verdict: Verdict, operation: UUID) throws -> JSONValue {
    switch verdict.tag {
    case .completed:
      guard let result = verdict.result else { throw OperationError(.invalidResponse, operation: operation) }
      return result
    case .failed: throw verdict.error ?? OperationError(.invalidResponse, operation: operation)
    case .stopped: throw OperationError(.operationEnded, operation: operation, details: ["reason": .string(verdict.reason ?? "")])
    }
  }
}

private func version(_ result: JSONValue) throws -> String {
  guard case let .object(fields) = result, case let .string(version)? = fields["version"] else { throw OperationError(.invalidResponse) }
  return version
}

private func decodeEntry(_ value: JSONValue) throws -> MachineEntry {
  do { return try JSONDecoder().decode(MachineEntry.self, from: Data(value.jsonString().utf8)) } catch { throw OperationError(.invalidResponse) }
}

/// A JSON object with its keys in order, so equal inputs encode equally.
func object(_ fields: [String: JSONValue]) -> JSONValue {
  .object(.init(uniqueKeysWithValues: fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
}
