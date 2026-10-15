#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import AsyncHTTPClient
import FetchAsyncHTTPClient
import ServerTelemetry

struct ServerTelemetryRuntime: Sendable {
  let buffer = SpanBuffer()
  let exporter: OTLPExporter
  let client: HTTPClient

  init(endpoint: URL) throws {
    guard ["http", "https"].contains(endpoint.scheme), endpoint.host != nil,
          endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
    else { throw OTLPExporter.ConfigurationError.invalidEndpoint }
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.timeout.connect = .seconds(2)
    configuration.timeout.read = .seconds(2)
    client = HTTPClient(configuration: configuration)
    exporter = try OTLPExporter(endpoint: endpoint, fetch: .asyncHTTPClient(client, timeout: .seconds(2)))
    ServerTracing.install { [buffer] in buffer.append($0) }
  }

  func run() async {
    await buffer.run(export: exporter.export)
  }

  func shutdown() async {
    ServerTracing.install(nil)
    await buffer.shutdown(export: exporter.export)
    try? await client.shutdown()
  }
}
