#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import enum JSONValue.JSONValue
import struct MachineContract.Base64Data
import struct MachineContract.MachineEntry
import struct MachineContract.MachineError
import enum MachineContract.MachineErrorCode
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot

extension OperationClient {
  func awaitResult(_ id: UUID) async throws -> JSONValue {
    while true {
      try Task.checkCancellation()
      do {
        let hold = try await store.read(id).description.limits.pollHoldMs
        let snapshot = try await reconcile(id, holdMs: min(20000, hold))
        if snapshot.verdict != nil {
          _ = try await poll(id, terminalAck: true)
          return try completed(snapshot)!
        }
      } catch let error as OperationError where error.code == .transport || error.code == .requestDeadline { try await clock.sleep(.milliseconds(10)) }
    }
  }

  func stat(machine: String, path: String, owner: OperationOwner, timeout: Duration? = nil) async throws -> MachineEntry {
    let result = try await fileCall(machine, kind: "stat.v1", input: ["path": .string(path)], owner: owner, timeout: timeout)
    return try decodeEntry(result)
  }

  func list(machine: String, path: String, owner: OperationOwner, timeout: Duration? = nil) async throws -> [MachineEntry] {
    let id = try await start(machine, request: .init(kind: "list.v1", input: ["path": .string(path)]), owner: owner, timeout: timeout)
    var entries: [MachineEntry] = []; var bytes = 0
    _ = try await drainFile(id, channel: "entries") { payload in
      for record in payload.records ?? [] {
        bytes += record.jsonString().utf8.count
        guard bytes <= VFSDefaults.maxReadBytes else { throw OperationError(.resultTooLarge) }
        entries.append(try decodeEntry(record))
      }
    }
    return entries.sorted { $0.name < $1.name }
  }

  func writeFile(machine: String, path: String, data: Data, ifMatch: String? = nil, owner: OperationOwner, timeout: Duration? = nil) async throws -> String {
    var input: JSONValue = ["path": .string(path), "bytes": .string(String(data.count)), "digest": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())]
    if let ifMatch, case var .object(fields) = input { fields["ifMatch"] = .string(ifMatch); input = .object(fields) }
    let id = try await start(machine, request: .init(kind: "write.v1", input: input), owner: owner, timeout: timeout)
    do {
      while true {
        try Task.checkCancellation()
        let record = try await store.read(id)
        if record.snapshot?.verdict != nil { break }
        let offset = Int(record.accepted["data"]?.rawValue ?? 0)
        guard offset <= data.count else { throw OperationError(.invalidResponse) }
        let pending = record.pendingInputs["data"]
        let payload = pending?.payload ?? .init(data: data.subdata(in: offset ..< min(data.count, offset + 65536)))
        let end = pending?.end ?? (offset + payload.count == data.count)
        do {
          let receipt = try await write(id, channel: "data", payload: payload, end: end)
          if receipt.end { break }
          if receipt.blocked { _ = try await reconcile(id); try await clock.sleep(.milliseconds(10)) }
        } catch let error as OperationError where error.code == .transport || error.code == .requestDeadline { try await clock.sleep(.milliseconds(10)) }
        catch let error as OperationError where error.code == .operationEnded { break }
      }
      let result = try await awaitResult(id)
      guard case let .object(fields) = result, case let .string(version)? = fields["version"] else { throw OperationError(.invalidResponse) }
      return version
    } catch {
      if let record = try? await store.read(id), record.snapshot?.verdict == nil { try? await abandon(record, reason: "fileCallFailed") }
      throw error
    }
  }

  func mkdir(machine: String, path: String, owner: OperationOwner, timeout: Duration? = nil) async throws {
    _ = try await fileCall(machine, kind: "mkdir.v1", input: ["path": .string(path)], owner: owner, timeout: timeout)
  }

  func remove(machine: String, path: String, ifMatch: String? = nil, owner: OperationOwner, timeout: Duration? = nil) async throws {
    var input: JSONValue = ["path": .string(path)]
    if let ifMatch, case var .object(fields) = input { fields["ifMatch"] = .string(ifMatch); input = .object(fields) }
    _ = try await fileCall(machine, kind: "remove.v1", input: input, owner: owner, timeout: timeout)
  }

  func move(machine: String, from: String, to: String, owner: OperationOwner, timeout: Duration? = nil) async throws {
    _ = try await fileCall(machine, kind: "move.v1", input: ["from": .string(from), "to": .string(to)], owner: owner, timeout: timeout)
  }

  public func vfs(machine: String, op: VFSOp, owner: OperationOwner, timeout: Duration? = nil) async throws -> VFSResult {
    do {
      if descriptions[machine] == nil { _ = try await describe(machine) }
      switch op {
      case let .stat(path): return try await .entry(entry: stat(machine: machine, path: path, owner: owner, timeout: timeout))
      case let .ls(path): return try await .entries(entries: list(machine: machine, path: path, owner: owner, timeout: timeout))
      case let .write(path, data, token): return try await .written(token: writeFile(machine: machine, path: path, data: Data(data.bytes), ifMatch: token, owner: owner, timeout: timeout))
      case let .mkdir(path): try await mkdir(machine: machine, path: path, owner: owner, timeout: timeout); return .ok
      case let .rm(path, token): try await remove(machine: machine, path: path, ifMatch: token, owner: owner, timeout: timeout); return .ok
      case let .mv(from, to): try await move(machine: machine, from: from, to: to, owner: owner, timeout: timeout); return .ok
      case let .read(path, offset, length):
        guard (offset ?? 0) >= 0, (length ?? 0) >= 0 else { return .error(error: .init(code: .invalidArgument, message: "Read range must not be negative")) }
        if let length, length > VFSDefaults.maxReadBytes { return .error(error: .init(code: .tooLarge, message: "Read exceeds the wire bound")) }
        var input: JSONValue = ["path": .string(path), "offset": .string(String(offset ?? 0))]
        if let length, case var .object(fields) = input { fields["length"] = .string(String(length)); input = .object(fields) }
        let id = try await start(machine, request: .init(kind: "read.v1", input: input), owner: owner, timeout: timeout)
        var bytes = Data()
        let result = try await drainFile(id, channel: "data") { payload in
          guard let chunk = payload.data, chunk.count <= VFSDefaults.maxReadBytes - bytes.count else { throw OperationError(.resultTooLarge) }
          bytes.append(chunk)
        }
        guard case let .object(fields) = result, case let .string(token)? = fields["version"] else { throw OperationError(.invalidResponse) }
        return .file(token: token, data: .init([UInt8](bytes)))
      }
    } catch let error as OperationError {
      let code: MachineErrorCode
      switch error.code {
      case .fileChanged: code = .conflict
      case .invalidInput: code = .invalidArgument
      case .resultTooLarge, .inputTooLarge, .recordTooLarge: code = .tooLarge
      case .fileUnavailable:
        if case let .object(fields)? = error.details, let number = fields["errno"]?.intValue { code = fields["lookup"] == .bool(true) ? .notFound : (number == 17 ? .conflict : .io) }
        else { code = .io }
      default: throw error
      }
      return .error(error: MachineError(code: code, message: error.message.isEmpty ? error.code.rawValue : error.message))
    }
  }

  private func fileCall(_ machine: String, kind: String, input: JSONValue, owner: OperationOwner, timeout: Duration?) async throws -> JSONValue {
    let id = try await start(machine, request: .init(kind: kind, input: input), owner: owner, timeout: timeout)
    do { return try await awaitResult(id) }
    catch { if let record = try? await store.read(id), record.snapshot?.verdict == nil { try? await abandon(record, reason: "fileCallFailed") }; throw error }
  }

  private func drainFile(_ id: UUID, channel: String, consume: (ChannelPayload) throws -> Void) async throws -> JSONValue {
    do {
      while true {
        try Task.checkCancellation()
        do {
          let hold = try await store.read(id).description.limits.pollHoldMs
          let snapshot = try await poll(id, channel: channel, holdMs: min(20000, hold))
          for payload in try await takeOutput(id, channel: channel) { try consume(payload) }
          if snapshot.channelEnd {
            _ = try await poll(id, channel: channel, terminalAck: true)
            guard let result = try completed(snapshot) else { throw OperationError(.invalidResponse) }; return result
          }
        } catch let error as OperationError where error.code == .transport || error.code == .requestDeadline { try await clock.sleep(.milliseconds(10)) }
      }
    } catch { if let record = try? await store.read(id), record.snapshot?.verdict == nil { try? await abandon(record, reason: "fileCallFailed") }; throw error }
  }

  private func completed(_ snapshot: OperationSnapshot) throws -> JSONValue? {
    guard let verdict = snapshot.verdict else { return nil }
    switch verdict.tag {
    case .completed: return verdict.result!
    case .failed: throw verdict.error!
    case .stopped: throw OperationError(.operationEnded, operation: snapshot.operation, details: ["reason": .string(verdict.reason!)])
    }
  }
}

private func decodeEntry(_ value: JSONValue) throws -> MachineEntry {
  do { return try JSONDecoder().decode(MachineEntry.self, from: Data(value.jsonString().utf8)) }
  catch { throw OperationError(.invalidResponse) }
}
