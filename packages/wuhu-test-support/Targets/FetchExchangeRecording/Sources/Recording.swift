#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import struct HTTPTypes.HTTPField

public struct RecordedExchange: Codable, Equatable, Sendable {
  public struct Head: Codable, Equatable, Sendable {
    public let method: String?
    public let url: String?
    public let status: Int?
    public let headers: [String: String]
    public let body: Data?
    public init(method: String? = nil, url: String? = nil, status: Int? = nil, headers: [String: String] = [:], body: Data? = nil) {
      self.method = method; self.url = url; self.status = status; self.headers = headers; self.body = body
    }
  }

  public let request: Head
  public let response: Head
  public init(request: Head, response: Head) { self.request = request; self.response = response }
}

public struct RecordedEffect: Codable, Equatable, Sendable {
  public let name: String
  public let input: [String: String]
  public let output: [String: String]
  public init(_ name: String, input: [String: String] = [:], output: [String: String] = [:]) { self.name = name; self.input = input; self.output = output }
}

public struct ExchangeRecording: Codable, Equatable, Sendable {
  public let exchanges: [RecordedExchange]
  public let effects: [RecordedEffect]
  public init(exchanges: [RecordedExchange], effects: [RecordedEffect] = []) { self.exchanges = exchanges; self.effects = effects }
}

public enum RecordingError: Error, Equatable { case exhausted, requestMismatch, unsafeHeaders, capacityExceeded, invalidHead }

public actor FetchExchangeRecorder {
  let live: FetchClient?
  let replay: ExchangeRecording?
  let bodyLimit: Int
  let exchangeLimit: Int
  let effectLimit: Int
  var index = 0
  var exchanges: [RecordedExchange] = []
  var effects: [RecordedEffect] = []

  public init(live: FetchClient, bodyLimit: Int = 256 * 1024, exchangeLimit: Int = 4096) {
    self.live = live; replay = nil; self.bodyLimit = bodyLimit; self.exchangeLimit = exchangeLimit; effectLimit = exchangeLimit
  }

  public init(replay: ExchangeRecording, bodyLimit: Int = 256 * 1024) {
    live = nil; self.replay = replay; self.bodyLimit = bodyLimit; exchangeLimit = replay.exchanges.count; effectLimit = replay.effects.count
  }

  public nonisolated var client: FetchClient { FetchClient { try await self.fetch($0) } }
  public func effect(_ effect: RecordedEffect) throws {
    guard try JSONEncoder().encode(effect).count <= bodyLimit else { throw RecordingError.capacityExceeded }
    guard effects.count < effectLimit else { throw RecordingError.capacityExceeded }
    if let replay { guard effects.count < replay.effects.count, replay.effects[effects.count] == effect else { throw RecordingError.requestMismatch } }
    effects.append(effect)
  }

  public func recording() -> ExchangeRecording { .init(exchanges: exchanges, effects: effects) }
  public func assertComplete() throws {
    if let replay, index != replay.exchanges.count || effects.count != replay.effects.count { throw RecordingError.exhausted }
  }

  func fetch(_ request: Request) async throws -> Response {
    guard index < exchangeLimit else { throw RecordingError.capacityExceeded }
    guard request.headers.sensitiveValues.isEmpty,
          request.headers.fields.allSatisfy({ !["authorization", "proxy-authorization", "cookie", "set-cookie", "x-wuhu-supervisor-nonce"].contains($0.name.rawName.lowercased()) }) else { throw RecordingError.unsafeHeaders }
    guard request.headers.fields.reduce(0, { $0 + $1.name.rawName.utf8.count + $1.value.utf8.count }) <= 16 * 1024 else { throw RecordingError.capacityExceeded }
    let body = try await request.body?.bytes(upTo: bodyLimit)
    let head = RecordedExchange.Head(
      method: request.method.rawValue,
      url: request.url.absoluteString,
      headers: Dictionary(uniqueKeysWithValues: request.headers.fields.map { ($0.name.rawName.lowercased(), $0.value) }),
      body: body,
    )
    let slot = index; index += 1
    if let replay {
      guard slot < replay.exchanges.count else { throw RecordingError.exhausted }
      let exchange = replay.exchanges[slot]
      guard exchange.request == head else { throw RecordingError.requestMismatch }
      guard let status = exchange.response.status, (100 ... 599).contains(status), (exchange.response.body?.count ?? 0) <= bodyLimit else { throw RecordingError.invalidHead }
      guard exchange.response.headers.keys.allSatisfy({ !["authorization", "proxy-authorization", "cookie", "set-cookie", "x-wuhu-supervisor-nonce"].contains($0.lowercased()) }) else { throw RecordingError.unsafeHeaders }
      guard exchange.response.headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16 * 1024 else { throw RecordingError.capacityExceeded }
      var headers = Headers()
      for (name, value) in exchange.response.headers { guard let field = HTTPField.Name(name) else { throw RecordingError.invalidHead }; headers[field] = value }
      exchanges.append(exchange)
      return Response(status: .init(code: status), headers: headers, body: .bytes(exchange.response.body ?? Data(), contentType: headers[.contentType]))
    }
    guard let live else { throw RecordingError.exhausted }
    var copy = request
    if let body { copy.body = .bytes(body, contentType: request.body?.contentType) }
    let response = try await live(copy)
    guard response.headers.allSatisfy({ !["authorization", "proxy-authorization", "cookie", "set-cookie", "x-wuhu-supervisor-nonce"].contains($0.name.rawName.lowercased()) }) else { throw RecordingError.unsafeHeaders }
    guard response.headers.reduce(0, { $0 + $1.name.rawName.utf8.count + $1.value.utf8.count }) <= 16 * 1024 else { throw RecordingError.capacityExceeded }
    let bytes = try await response.body.bytes(upTo: bodyLimit)
    let recorded = RecordedExchange(request: head, response: .init(
      status: response.status.code,
      headers: Dictionary(response.headers.map { ($0.name.rawName.lowercased(), $0.value) }, uniquingKeysWith: { _, b in b }),
      body: bytes,
    ))
    exchanges.append(recorded)
    return Response(status: response.status, headers: response.headers, body: .bytes(bytes, contentType: response.body.contentType))
  }
}
