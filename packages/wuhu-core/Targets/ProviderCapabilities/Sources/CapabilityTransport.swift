#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import JSONValue

extension CapabilityClient {
  func send(_ request: Request) async throws -> Response {
    @Dependency(\.fetch) var fetch
    let response: Response
    do { response = try await fetch(request) }
    catch is CancellationError { throw CancellationError() }
    catch { throw CapabilityError(.providerUnavailable, "The capability provider could not be reached.", hint: "Retry later; no other provider was selected.") }
    guard (200 ..< 300).contains(response.status.code) else {
      let payload = try? await response.body.json(JSONValue.self, upTo: 4096)
      let upstreamCode = payload?["code"].text ?? payload?["error"]["code"].text ?? ""
      let code: CapabilityError.Code = switch response.status.code {
      case 401: .providerAuth
      case 403 where upstreamCode.lowercased().contains("region") || upstreamCode == "unsupported_country_region_territory": .providerRegion
      case 403: .providerEntitlement
      case 429: .providerRateLimited
      case 400, 422: .invalidArgument
      default: .providerUnavailable
      }
      throw CapabilityError(code, "The capability provider refused the request (HTTP \(response.status.code)).", hint: "Check the selected provider's credentials, endpoint, entitlement and input; no fallback was attempted.")
    }
    return response
  }

  func json(_ request: Request) async throws -> JSONValue {
    let response = try await send(request)
    do { return try await response.body.json(JSONValue.self, upTo: 32 << 20) }
    catch is CancellationError { throw CancellationError() }
    catch { throw CapabilityError(.providerUnavailable, "The capability provider returned an invalid response.") }
  }

  func post(_ provider: Resolved, _ path: String, _ body: JSONValue, asynchronous: Bool = false) async throws -> JSONValue {
    var headers = provider.headers
    if asynchronous { headers.set("x-dashscope-async", "enable") }
    return try await json(Request(url: provider.baseURL.appendingPathComponent(path), method: .post, headers: headers, body: try .json(body)))
  }

  func download(_ raw: String) async throws -> Data {
    guard let url = URL(string: raw), ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else {
      throw CapabilityError(.providerUnavailable, "The provider returned an invalid result URL.")
    }
    // Result storage is a distinct authority; provider credentials never follow it.
    let response = try await send(Request(url: url))
    do { return try await response.body.data(upTo: 32 << 20) }
    catch is CancellationError { throw CancellationError() }
    catch { throw CapabilityError(.providerUnavailable, "The provider result could not be read within the result bound.") }
  }
}

extension JSONValue {
  subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
  var text: String? { if case let .string(value) = self { value } else { nil } }
  var list: [JSONValue] { if case let .array(value) = self { value } else { [] } }
  var speakerLabel: String? {
    switch self {
    case let .string(value): value
    case let .integer(value): String(value)
    case let .number(value) where value.isFinite && value >= 0 && value < 1_000_000 && value == value.rounded(): String(Int(value))
    default: nil
    }
  }

  var numeric: Double? {
    switch self {
    case let .integer(value): Double(value)
    case let .number(value): value.isFinite ? value : nil
    default: nil
    }
  }
}
