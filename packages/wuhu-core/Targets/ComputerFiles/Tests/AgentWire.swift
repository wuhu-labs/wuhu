#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import Fetch
import enum JSONValue.JSONValue
import struct MachineContract.MachineEntry
import OperationProtocol
import Testing

struct AgentWire: Sendable {
  let handler: @Sendable (Request) async throws -> Response
  let base = URL(string: "https://test.invalid/machine/v2/machines/disk")!

  init(_ handler: @escaping @Sendable (Request) async throws -> Response) { self.handler = handler }

  func receive<T: Decodable & Sendable>(_ type: T.Type, _ request: Request) async throws -> T {
    let response = try await handler(request)
    if response.status.code >= 400 { throw try await response.body.json(ErrorEnvelope.self).error }
    return try await response.body.json(type)
  }

  func describe() async throws -> MachineDescription { try await receive(MachineDescription.self, Request(url: base)) }

  func start(_ request: StartRequest, id: UUID = UUID()) async throws -> AgentOperation {
    let description = try await describe()
    let kind = try #require(description.kinds.first { $0.name == request.kind })
    let url = base.appendingPathComponent("operations/\(id.uuidString)")
    _ = try await receive(OperationSnapshot.self, Request(url: url, method: .post, body: .json(request)))
    return AgentOperation(wire: self, url: url, kind: kind)
  }

  nonisolated(nonsending) func call(_ request: StartRequest, consume: (ChannelPayload) async throws -> Void = { _ in }) async throws -> JSONValue {
    let operation = try await start(request)
    let end = try await operation.collect(consume)
    return try result(end)
  }

  func write(path: String, data: Data, ifMatch: String? = nil) async throws -> String {
    var input: [String: JSONValue] = ["path": .string(path), "bytes": .string(String(data.count)), "digest": .string(sha256(data))]
    if let ifMatch { input["ifMatch"] = .string(ifMatch) }
    let operation = try await start(.init(kind: "write.v1", input: .object(.init(uniqueKeysWithValues: input.map { ($0.key, $0.value) }))))
    var offset = 0
    do {
      repeat {
        let end = min(data.count, offset + 64 * 1024)
        try await operation.write("data", .init(data: data.subdata(in: offset ..< end)), end: end == data.count)
        offset = end
      } while offset < data.count
    } catch let error as OperationError where error.code == .operationEnded {}
    let value = try result(await operation.collect { _ in })
    return try #require(value.object?["version"]?.stringValue)
  }
}

actor AgentOperation {
  let wire: AgentWire
  let url: URL
  let kind: KindDescriptor
  var inputOffsets: [String: Offset] = [:]

  init(wire: AgentWire, url: URL, kind: KindDescriptor) { self.wire = wire; self.url = url; self.kind = kind }

  func poll(_ query: [URLQueryItem] = []) async throws -> OperationSnapshot {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = query
    return try await wire.receive(OperationSnapshot.self, Request(url: components.url!))
  }

  func input(_ channel: String, _ request: WriteRequest) async throws -> WriteReceipt {
    let receipt = try await wire.receive(WriteReceipt.self, Request(url: url.appendingPathComponent("inputs/\(channel)"), method: .put, body: .json(request)))
    inputOffsets[channel] = receipt.acceptedThrough
    return receipt
  }

  func write(_ channel: String, _ payload: ChannelPayload, end: Bool) async throws {
    let offset = inputOffsets[channel, default: .zero]
    let through = try offset.advanced(by: payload.count)
    let request = WriteRequest(offset: offset, payload: payload, end: end)
    while true {
      let receipt = try await input(channel, request)
      if receipt.acceptedThrough >= through && (!end || receipt.end) { break }
      await Task.yield()
    }
    inputOffsets[channel] = through
  }

  func stop(_ reason: String) async throws {
    _ = try await wire.receive(OperationSnapshot.self, Request(url: url.appendingPathComponent("stop"), method: .put, body: .json(StopRequest(reason: reason))))
  }

  func verdict() async throws -> Verdict {
    while true {
      if let verdict = try await poll().verdict { return verdict }
      await Task.yield()
    }
  }

  nonisolated(nonsending) func collect(_ consume: (ChannelPayload) async throws -> Void) async throws -> Verdict {
    var offsets: [String: Offset] = [:]
    for channel in kind.outputChannels {
      var offset = Offset.zero
      while true {
        let snapshot = try await poll([.init(name: "channel", value: channel.name), .init(name: "after", value: String(offset.rawValue))])
        if let payload = snapshot.payload { try await consume(payload) }
        offset = snapshot.through!
        if snapshot.channelEnd { break }
        await Task.yield()
      }
      offsets[channel.name] = offset
      _ = try await poll([.init(name: "channel", value: channel.name), .init(name: "after", value: String(offset.rawValue))])
    }
    let ending = try await verdict()
    let token = try #require(try await poll().terminalToken)
    if kind.outputChannels.isEmpty {
      _ = try await poll([.init(name: "terminalAck", value: token.uuidString)])
    } else {
      for channel in kind.outputChannels {
        _ = try await poll([.init(name: "channel", value: channel.name), .init(name: "after", value: String(offsets[channel.name]!.rawValue)), .init(name: "terminalAck", value: token.uuidString)])
      }
    }
    return ending
  }

  nonisolated(nonsending) func drain() async throws -> (data: Data, records: [JSONValue], end: Ending) {
    var data = Data()
    var records: [JSONValue] = []
    let verdict = try await collect { payload in
      if let bytes = payload.data { data.append(bytes) }
      if let items = payload.records { records.append(contentsOf: items) }
    }
    return (data, records, Ending(verdict: verdict))
  }
}

struct Ending: Sendable { let verdict: Verdict? }

private func result(_ verdict: Verdict) throws -> JSONValue {
  switch verdict.tag {
  case .completed: verdict.result!
  case .failed: throw verdict.error!
  case .stopped: throw OperationError(.operationEnded, details: ["reason": .string(verdict.reason!)])
  }
}

func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

func decodeEntry(_ value: JSONValue) throws -> MachineEntry { try JSONDecoder().decode(MachineEntry.self, from: Data(value.jsonString().utf8)) }

let leaseJumpRetention: Duration = .seconds(3600)
