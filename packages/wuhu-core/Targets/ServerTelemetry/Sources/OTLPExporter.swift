#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch

public struct OTLPExporter: Sendable {
  private let endpoint: URL
  private let fetch: FetchClient

  public init(endpoint: URL, fetch: FetchClient) throws {
    guard ["http", "https"].contains(endpoint.scheme), endpoint.host != nil,
          endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
    else { throw ConfigurationError.invalidEndpoint }
    self.endpoint = endpoint.path.hasSuffix("/v1/traces") ? endpoint : endpoint.appendingPathComponent("v1/traces")
    self.fetch = fetch
  }

  public func export(_ spans: [FinishedSpan]) async throws {
    let body = Export(resourceSpans: [.init(resource: .init(attributes: [.init(key: "service.name", value: .init(stringValue: "wuhu-server"))]), scopeSpans: [.init(scope: .init(name: "wuhu-server"), spans: spans.map(WireSpan.init))])])
    let response = try await fetch(Request(url: endpoint, method: .post, body: .json(body)))
    guard (200 ..< 300).contains(response.status.code) else { throw ConfigurationError.collectorRejected }
    try await response.body.discard()
  }

  public enum ConfigurationError: Error { case invalidEndpoint, collectorRejected }
}

private struct Value: Encodable { let stringValue: String }
private struct Attribute: Encodable { let key: String; let value: Value }
private struct Export: Encodable { let resourceSpans: [ResourceSpans] }
private struct ResourceSpans: Encodable { let resource: Resource; let scopeSpans: [ScopeSpans] }
private struct Resource: Encodable { let attributes: [Attribute] }
private struct ScopeSpans: Encodable { let scope: Scope; let spans: [WireSpan] }
private struct Scope: Encodable { let name: String }
private struct Status: Encodable { let code: Int }
private struct WireSpan: Encodable {
  let traceId: String
  let spanId: String
  let parentSpanId: String?
  let name: String
  let kind = 1
  let startTimeUnixNano: String
  let endTimeUnixNano: String
  let attributes: [Attribute]
  let status: Status

  init(_ span: FinishedSpan) {
    traceId = span.context.traceID; spanId = span.context.spanID; parentSpanId = span.parentSpanID
    name = span.name.rawValue
    startTimeUnixNano = String(UInt64(max(0, span.start.timeIntervalSince1970) * 1_000_000_000))
    endTimeUnixNano = String(UInt64(max(0, span.end.timeIntervalSince1970) * 1_000_000_000))
    var values = span.attributes
    values[.session] = span.context.session; values[.group] = span.context.group
    attributes = values.sorted { $0.key.rawValue < $1.key.rawValue }.map { Attribute(key: $0.key.rawValue, value: Value(stringValue: $0.value)) }
    status = Status(code: values[.outcome].map { $0 == "ok" ? 1 : 2 } ?? 0)
  }
}
