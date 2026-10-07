#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchWebSocket
import HTTPTypes
import JSONValue
import Synchronization

struct SocketFixture: Codable, Sendable {
  var handshake: SocketHandshake
  var responseHeaders: [String: String] = [:]
  var failure: SocketFailure?
  var journal: [SocketAction] = []
}

struct SocketHandshake: Codable, Equatable, Sendable {
  var url: String
  var headers: [String: String]
  var limits: [Int]
  var tls: String
  var timeouts: [Int64]

  init(_ request: WebSocketRequest, redaction: SocketRedaction) {
    url = redaction.text(request.url.absoluteString)
    headers = redaction.requestHeaders(request.headers)
    limits = [
      request.limits.frameBytes,
      request.limits.messageBytes,
      request.limits.bufferedReceiveBytes,
      request.limits.outboundMessageBytes,
      request.limits.refusalBodyBytes,
    ]
    timeouts = [
      request.connectTimeout.components.seconds,
      request.connectTimeout.components.attoseconds,
      request.closeTimeout.components.seconds,
      request.closeTimeout.components.attoseconds,
    ]
    switch request.tls {
    case nil: tls = "default"
    case .configuration: tls = "configuration"
    case .pinned(let fingerprint): tls = "pinned:\(fingerprint)"
    }
  }
}

struct SocketMessage: Codable, Sendable {
  var text: String?
  var binary: [UInt8]?

  init(_ message: WebSocketMessage, redaction: SocketRedaction) {
    switch message {
    case .text(let value): text = redaction.message(value)
    case .binary(let value): binary = redaction.bytes(value)
    }
  }

  var message: WebSocketMessage {
    if let text { return .text(text) }
    return .binary(binary ?? [])
  }
}

struct SocketClose: Codable, Sendable {
  var code: UInt16
  var reason: String
  init(_ close: WebSocketClose, redaction: SocketRedaction) {
    code = close.code
    reason = redaction.text(close.reason)
  }

  var close: WebSocketClose { .init(code: code, reason: reason) }
}

enum SocketAction: Codable, Sendable {
  case send(SocketMessage, SocketFailure?)
  case receive(SocketMessage)
  case receivedClose(SocketClose)
  case receiveFailure(SocketFailure)
  case end
  case close(SocketClose, SocketFailure?)
  case abort
  case scopeAbort
}

struct SocketFailure: Codable, Equatable, Sendable {
  var kind: String
  var diagnostic: String = ""
  var status: Int?
  var headers: [String: String] = [:]
  var body: [UInt8] = []

  init(_ error: any Error, redaction: SocketRedaction) {
    switch error {
    case let error as WebSocketError:
      switch error {
      case .unimplemented: kind = "unimplemented"
      case .invalidURL(let value): kind = "invalidURL"; diagnostic = redaction.text(value)
      case .invalidConfiguration(let value): kind = "invalidConfiguration"; diagnostic = redaction.text(value)
      case .tls(let value): kind = "tls"; diagnostic = redaction.text(value)
      case .refused(let code, let fields, let bytes):
        kind = "refused"; status = code; headers = redaction.headers(fields); body = redaction.bytes(bytes)
      case .protocolViolation(let value): kind = "protocolViolation"; diagnostic = redaction.text(value)
      case .limitExceeded(let limit): kind = "limit:\(limit)"
      case .connectionClosed: kind = "connectionClosed"
      case .connectTimeout: kind = "connectTimeout"
      case .io(let value): kind = "io"; diagnostic = redaction.text(value)
      case .cancelled: kind = "cancelled"
      case .multipleConsumers: kind = "multipleConsumers"
      }
    case is CancellationError: kind = "cancelled"
    default: kind = "io"; diagnostic = redaction.text(String(describing: error))
    }
  }

  var error: WebSocketError {
    switch kind {
    case "unimplemented": .unimplemented
    case "invalidURL": .invalidURL(diagnostic)
    case "invalidConfiguration": .invalidConfiguration(diagnostic)
    case "tls": .tls(diagnostic)
    case "refused": .refused(status: status ?? 500, headers: RequestHeaders(values: headers).fields, body: body)
    case "protocolViolation": .protocolViolation(diagnostic)
    case "limit:frame": .limitExceeded(.frame)
    case "limit:message": .limitExceeded(.message)
    case "limit:bufferedReceive": .limitExceeded(.bufferedReceive)
    case "limit:outboundMessage": .limitExceeded(.outboundMessage)
    case "connectionClosed": .connectionClosed
    case "connectTimeout": .connectTimeout
    case "cancelled": .cancelled
    case "multipleConsumers": .multipleConsumers
    default: .io(diagnostic)
    }
  }
}

final class SocketRedaction: Sendable {
  private let secrets: Mutex<[String]>

  init(_ request: WebSocketRequest) {
    secrets = Mutex([])
    for (name, value) in request.headers.sensitiveValues { learn(value, header: name) }
    for (name, value) in request.headers.values where Self.privateHeader(name) { learn(value, header: name) }
  }

  private static func privateHeader(_ name: String) -> Bool {
    ["authorization", "proxy-authorization", "cookie", "set-cookie", "chatgpt-account-id", "session-id", "thread-id"].contains(name)
      || name.contains("routing") || name.contains("token") || name.contains("secret") || name.contains("api-key") || name.contains("affinity")
  }

  func requestHeaders(_ headers: RequestHeaders) -> [String: String] {
    var result: [String: String] = [:]
    for (name, value) in headers.values { result[name] = Self.privateHeader(name) ? "<redacted>" : text(value) }
    for name in headers.sensitiveValues.keys { result[name] = "<redacted>" }
    return result
  }

  func text(_ value: String) -> String {
    String(decoding: bytes(Array(value.utf8)), as: UTF8.self)
  }

  func message(_ value: String) -> String {
    guard let json = JSONValue.parse(value) else { return text(value) }
    return text(scrub(json, key: "").jsonString())
  }

  private func scrub(_ value: JSONValue, key: String) -> JSONValue {
    switch value {
    case .object(var fields):
      for name in fields.keys.sorted() {
        if key == "headers", case .string(let string) = fields[name], !Self.allowedResponseHeader(name.lowercased()) {
          learn(string, header: name.lowercased())
          fields[name] = .string("<redacted>")
        } else { fields[name] = scrub(fields[name]!, key: name.lowercased()) }
      }
      return .object(fields)
    case .array(let items): return .array(items.map { scrub($0, key: key) })
    case .string(let string):
      if Self.privateHeader(key) {
        learn(string, header: key)
        return .string("<redacted>")
      }
      return .string(text(string))
    default: return value
    }
  }

  private func learn(_ value: String, header: String) {
    var components = [value]
    let words = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
    if words.count == 2, words[0].lowercased() == "bearer" { components.append(String(words[1])) }
    if header == "cookie" || header == "set-cookie" {
      let cookies = value.split(separator: ";")
      for cookie in header == "set-cookie" ? Array(cookies.prefix(1)) : cookies {
        if let separator = cookie.firstIndex(of: "=") {
          let component = String(cookie[cookie.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
          components.append(component)
          if component.count >= 2, component.first == "\"", component.last == "\"" {
            components.append(String(component.dropFirst().dropLast()))
          }
        }
      }
    }
    secrets.withLock { secrets in
      secrets = Array(Set(secrets + components.filter { !$0.isEmpty && $0 != "<redacted>" }))
        .sorted { $0.utf8.count > $1.utf8.count }
    }
  }

  func bytes(_ value: [UInt8]) -> [UInt8] {
    let patterns = secrets.withLock { $0.map { Array($0.utf8) } }
    let replacement = Array("<redacted>".utf8)
    var result: [UInt8] = []
    var index = 0
    while index < value.count {
      if value[index...].starts(with: replacement) {
        result += replacement
        index += replacement.count
      } else if let pattern = patterns.first(where: { value[index...].starts(with: $0) }) {
        result += replacement
        index += pattern.count
      } else {
        result.append(value[index])
        index += 1
      }
    }
    return result
  }

  private static func allowedResponseHeader(_ name: String) -> Bool {
    ["upgrade", "connection", "content-type", "date", "retry-after"].contains(name) || name.hasPrefix("x-ratelimit-")
      || ["primary", "secondary"].contains { window in
        ["used-percent", "reset-at", "window-minutes"].contains { name == "x-codex-\(window)-\($0)" }
      }
  }

  func headers(_ fields: Headers) -> [String: String] {
    var result: [String: String] = [:]
    for field in fields {
      let name = field.name.canonicalName
      let allowed = Self.allowedResponseHeader(name)
      if !allowed { learn(field.value, header: name) }
      result[name] = allowed ? text(field.value) : "<redacted>"
    }
    return result
  }
}
