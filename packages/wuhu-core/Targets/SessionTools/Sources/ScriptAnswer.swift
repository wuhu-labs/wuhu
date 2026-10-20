#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct MainHub.ScriptError
import SpaceClient
import SpaceContract
import SpaceTools

/// A host call's answer in the `wuhu:space` core's protocol: `{ok: value}` or
/// `{error: payload}`, the payload the core raises as a SpaceError with the
/// code, hint and token a page would see.
func spaceAnswer(_ body: () async throws -> JSONValue) async -> JSONValue {
  do {
    return .object(["ok": try await body()])
  } catch {
    return .object(["error": spaceFailurePayload(error)])
  }
}

/// A tool's own `{code, message, hint?, token?}`, a route's `{code, message}`
/// (a code no tool uses), a script error as `invalidArgument`, anything else
/// as the wire renders it.
func spaceFailurePayload(_ error: any Error) -> JSONValue {
  switch error {
  case let error as ScriptError:
    ToolRunError.failed(code: .invalidArgument, message: error.description, hint: nil).payload
  case let failure as SpaceClient.ToolFailure:
    ToolRunError.failed(code: failure.error.code, message: failure.error.message, hint: failure.error.hint, token: failure.error.token).payload
  case let failure as SpaceClient.TransportFailure:
    .object(["code": .string(failure.code ?? ErrorCode.internal.rawValue), "message": .string(failure.message)])
  default:
    Wire.failure(error).payload
  }
}

/// The same failure as the error a host function throws straight into the
/// script: the server's message, nothing of the transport.
func scriptFailure(_ error: any Error) -> any Error {
  switch error {
  case let failure as SpaceClient.ToolFailure: ScriptError(failure.error.message)
  case let failure as SpaceClient.TransportFailure: ScriptError(failure.message)
  default: error
  }
}

/// `path` with `items` as its query string, each value percent-encoded so a
/// `+` or `&` inside one (an ISO instant's zone) survives the trip.
func queryPath(_ path: String, _ items: [(String, String?)]) -> String {
  let query = items.compactMap { name, value in value.map { "\(name)=\(percentEncoded($0))" } }
  return query.isEmpty ? path : path + "?" + query.joined(separator: "&")
}

/// One path segment, percent-encoded.
func pathSegment(_ raw: String) -> String {
  percentEncoded(raw)
}

/// `text` with every byte but the unreserved ASCII (letters, digits, `-._~`)
/// percent-encoded, which fits a query value and a path segment alike.
private func percentEncoded(_ text: String) -> String {
  let digits = Array("0123456789ABCDEF".utf8)
  var bytes: [UInt8] = []
  for byte in text.utf8 {
    switch byte {
    case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "0") ... UInt8(ascii: "9"),
         UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
      bytes.append(byte)
    default:
      bytes += [UInt8(ascii: "%"), digits[Int(byte >> 4)], digits[Int(byte & 15)]]
    }
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// What a request's origin reads as for an identity token: `scheme://host[:port]`,
/// lowercase, default ports dropped; nil for anything but http(s) to a plain
/// host.
public func fetchOrigin(_ url: URL) -> String? {
  guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("*"), parts.user == nil, parts.password == nil,
        parts.port == nil || (1 ... 65535).contains(parts.port!)
  else { return nil }
  parts.scheme = scheme
  parts.host = host
  if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
  parts.path = ""
  parts.query = nil
  parts.fragment = nil
  return parts.string
}
