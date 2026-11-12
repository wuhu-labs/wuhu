#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import struct FileSearch.SearchError
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import JSONValue
import MachineContract
import struct OperationProtocol.ChannelDescriptor
import struct OperationProtocol.ChannelPayload
import struct OperationProtocol.OperationError
import struct OperationProtocol.StartRequest
import SpaceCore
import Wuwei

struct MachineFileClient: Sendable {
  let space: Space
  let machine: MachineID
  let caller: StartRequest.Caller?

  func connect(_ start: StartRequest) throws -> MachineFileConnection {
    try MachineFileConnection(space: space, machine: machine, start: start)
  }

  nonisolated(nonsending) func call(_ start: StartRequest, consume: (ChannelPayload) async throws -> Void = { _ in }) async throws -> JSONValue {
    let connection = try connect(start)
    defer { connection.close() }
    return try await connection.result(consume: consume)
  }

  nonisolated(nonsending) func write(_ path: String, data: Data, ifMatch: String?) async throws -> String {
    var input: [String: JSONValue] = [
      "path": .string(path), "bytes": .string(String(data.count)),
      "digest": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
    ]
    if let ifMatch { input["ifMatch"] = .string(ifMatch) }
    let connection = try connect(.init(kind: "write.v1", input: object(input), caller: caller))
    defer { connection.close() }
    do {
      try await connection.write("data", .init(data: data), end: true)
    } catch let error as OperationError where error.code == .operationEnded {}
    return try machineFileVersion(await connection.result())
  }

  private nonisolated(nonsending) func restartingRangeOnce<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
    try Task.checkCancellation()
    do { return try await operation() }
    catch MachineFileFailure.rangeLost {
      try Task.checkCancellation()
      return try await operation()
    }
  }

  nonisolated(nonsending) func stat(_ path: String) async throws -> MachineEntry {
    try await restartingRangeOnce {
      try decodeEntry(await call(.init(kind: "stat.v1", input: ["path": .string(path)], caller: caller)))
    }
  }

  nonisolated(nonsending) func list(_ path: String) async throws -> [MachineEntry] {
    try await restartingRangeOnce {
      var entries: [MachineEntry] = []
      var bytes = 0
      _ = try await call(.init(kind: "list.v1", input: ["path": .string(path)], caller: caller)) { payload in
        guard let records = payload.records else { throw OperationError(.invalidResponse) }
        for record in records {
          let size = record.jsonString().utf8.count
          guard size <= VFSDefaults.maxReadBytes - bytes else { throw OperationError(.resultTooLarge) }
          bytes += size
          try entries.append(decodeEntry(record))
        }
      }
      return entries.sorted { $0.name < $1.name }
    }
  }

  nonisolated(nonsending) func read(_ path: String, offset: Int, length: Int?) async throws -> VFSResult {
    var input: [String: JSONValue] = ["path": .string(path), "offset": .string(String(offset))]
    if let length { input["length"] = .string(String(length)) }
    let start = StartRequest(kind: "read.v1", input: object(input), caller: caller)
    return try await restartingRangeOnce {
      var bytes = Data()
      let result = try await call(start) { payload in
        guard let chunk = payload.data else { throw OperationError(.invalidResponse) }
        guard chunk.count <= VFSDefaults.maxReadBytes - bytes.count else { throw OperationError(.resultTooLarge) }
        if let length, chunk.count > length - bytes.count { throw OperationError(.invalidResponse) }
        bytes.append(chunk)
      }
      guard case let .string(version)? = result.object?["version"] else { throw OperationError(.invalidResponse) }
      return .file(token: version, data: .init(Array(bytes)))
    }
  }

  nonisolated(nonsending) func vfs(_ op: VFSOp) async throws -> VFSResult {
    do {
      switch op {
      case let .stat(path): return try await .entry(entry: stat(path))
      case let .ls(path): return try await .entries(entries: list(path))
      case let .read(path, offset, length):
        guard (offset ?? 0) >= 0, (length ?? 0) >= 0 else { return .error(error: .init(code: .invalidArgument, message: "Read range must not be negative")) }
        if let length, length > VFSDefaults.maxReadBytes { return .error(error: .init(code: .tooLarge, message: "Read exceeds the wire bound")) }
        return try await read(path, offset: offset ?? 0, length: length)
      case let .mkdir(path):
        _ = try await call(.init(kind: "mkdir.v1", input: ["path": .string(path)], caller: caller))
      case let .rm(path, token):
        var input: [String: JSONValue] = ["path": .string(path)]
        if let token { input["ifMatch"] = .string(token) }
        _ = try await call(.init(kind: "remove.v1", input: object(input), caller: caller))
      case let .mv(from, to):
        _ = try await call(.init(kind: "move.v1", input: ["from": .string(from), "to": .string(to)], caller: caller))
      case let .write(path, data, ifMatch):
        return try await .written(token: write(path, data: Data(data.bytes), ifMatch: ifMatch))
      }
      return .ok
    } catch let error as OperationError {
      return try Self.fileError(error)
    }
  }

  nonisolated(nonsending) func search(_ query: SearchQuery) async throws -> SearchPage {
    let input = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(query))
    return try await restartingRangeOnce {
      let result: JSONValue
      do { result = try await call(.init(kind: "search.v1", input: input, caller: caller)) }
      catch let error as OperationError {
        if case let .string(code)? = error.details?.object?["search"], let typed = SearchError.Code(rawValue: code) { throw SearchError(typed, error.message) }
        throw error
      }
      do { return try JSONDecoder().decode(SearchPage.self, from: Data(result.jsonString().utf8)) }
      catch { throw OperationError(.invalidResponse, message: "search.v1 result is not a page") }
    }
  }

  static func fileError(_ error: OperationError) throws -> VFSResult {
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
    return .error(error: .init(code: code, message: error.message.isEmpty ? error.code.rawValue : error.message))
  }
}

func decodeEntry(_ value: JSONValue) throws -> MachineEntry {
  do { return try JSONDecoder().decode(MachineEntry.self, from: Data(value.jsonString().utf8)) }
  catch { throw OperationError(.invalidResponse) }
}

func object(_ fields: [String: JSONValue]) -> JSONValue {
  .object(.init(uniqueKeysWithValues: fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
}

func machineFileVersion(_ result: JSONValue) throws -> String {
  guard case let .string(version)? = result.object?["version"] else { throw OperationError(.invalidResponse) }
  return version
}

final class MachineFileConnection {
  private let request: MachineFile
  private let buffers: MachineBuffers
  private let peer: Peer<FileBulk>
  private var iterator: AsyncStream<FileBulk.Outgoing>.Iterator
  private var started = false
  private var inputs: [ChannelDescriptor]?
  private var inputOffsets: [String: UInt64] = [:]
  private var offset: UInt64 = 0
  private var terminal: Result<JSONValue, MachineFileFailure>?

  init(space: Space, machine: MachineID, start: StartRequest) throws {
    request = MachineFile(operation: UUID(), start: start)
    buffers = space.machineBuffers
    let (events, continuation) = AsyncStream<FileBulk.Outgoing>.makeStream()
    guard let peer = space.worker.attach(FileBulk.self, to: MachineCell.ID(machine.rawValue), opening: .init(request: request), output: {
      switch $0 {
      case let .frame(frame): continuation.yield(frame)
      case .closed: continuation.finish()
      }
    }) else { throw OperationError(.machineUnavailable) }
    self.peer = peer
    iterator = events.makeAsyncIterator()
  }

  func close() {
    peer.close()
    buffers.discard(request.operation)
  }

  private nonisolated(nonsending) func next() async throws -> FileBulk.Outgoing {
    while let event = await iterator.next(isolation: #isolation) {
      try Task.checkCancellation()
      switch event {
      case .started: started = true
      case let .ready(channels):
        inputs = channels
        return event
      case let .finished(result):
        terminal = result
        return event
      default: return event
      }
    }
    try Task.checkCancellation()
    guard started else { throw OperationError(.machineUnavailable, details: ["started": false]) }
    switch request.start.kind {
    case "stat.v1", "read.v1", "list.v1", "search.v1": throw MachineFileFailure.rangeLost(offset: offset)
    default: throw MachineFileFailure.outcomeUnknown
    }
  }

  private func value(_ result: Result<JSONValue, MachineFileFailure>) throws -> JSONValue {
    do { return try result.get() }
    catch let MachineFileFailure.operation(error) { throw error }
  }

  private nonisolated(nonsending) func channels() async throws -> [ChannelDescriptor] {
    while inputs == nil {
      switch try await next() {
      case .ready: break
      case let .finished(result):
        _ = try value(result)
        throw OperationError(.operationEnded)
      default: throw OperationError(.invalidResponse)
      }
    }
    return inputs!
  }

  nonisolated(nonsending) func ready() async throws {
    _ = try await channels()
  }

  nonisolated(nonsending) func write(_ channel: String, _ payload: ChannelPayload, end: Bool = false) async throws {
    try Task.checkCancellation()
    if let terminal { _ = try value(terminal); throw OperationError(.operationEnded) }
    guard let descriptor = try await channels().first(where: { $0.name == channel }) else { throw OperationError(.invalidInput) }
    guard (descriptor.unit == .bytes) == (payload.data != nil) else { throw OperationError(.invalidInput) }
    let window = min(65536, descriptor.windowBytes)
    guard window > 0 else { throw OperationError(.invalidResponse) }
    var from = 0
    repeat {
      let through: Int
      if payload.data != nil { through = min(payload.count, from + window) }
      else {
        var count = from
        var bytes = 0
        while count < payload.count {
          let size = payload.records![count].jsonString().utf8.count
          guard size <= descriptor.maxRecordBytes, size <= window else { throw OperationError(.recordTooLarge) }
          if size > window - bytes { break }
          bytes += size; count += 1
        }
        through = count
      }
      try await send(channel, payload.slice(from ..< through), end: end && through == payload.count)
      from = through
    } while from < payload.count
  }

  private nonisolated(nonsending) func send(_ channel: String, _ payload: ChannelPayload, end: Bool) async throws {
    let from = inputOffsets[channel, default: 0]
    guard let pointer = buffers.put(payload: payload, operation: request.operation, channel: channel, from: from) else { throw OperationError(.inputTooLarge) }
    peer.send(.input(pointer, end: end))
    while true {
      switch try await next() {
      case let .accepted(acceptedChannel, offset, ended):
        guard acceptedChannel == channel, offset == pointer.through, ended == end else { throw OperationError(.invalidResponse) }
        buffers.accepted(request.operation, channel: channel, through: offset, ended: ended)
        inputOffsets[channel] = offset
        return
      case let .finished(result):
        _ = try value(result)
        throw OperationError(.operationEnded)
      default: throw OperationError(.invalidResponse)
      }
    }
  }

  nonisolated(nonsending) func result(consume: (ChannelPayload) async throws -> Void = { _ in }) async throws -> JSONValue {
    if let terminal { return try value(terminal) }
    while true {
      switch try await next() {
      case .ready: break
      case let .output(pointer):
        precondition(pointer.operation == request.operation)
        guard let payload = buffers.payload(pointer) else { throw MachineFileFailure.rangeLost(offset: pointer.from) }
        try await consume(payload)
        offset = pointer.through
        peer.send(.want(channel: pointer.channel, offset: pointer.through))
      case let .finished(result): return try value(result)
      case .started: preconditionFailure("dispatch is handled by next")
      case .accepted: throw OperationError(.invalidResponse)
      }
    }
  }
}
