#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
import Logging
import OTel
import ServiceLifecycle
import TaskLifetime

/// An OTLP endpoint that is not an HTTP(S) URL with a host, or carries credentials, a query or a fragment.
public struct UnusableOTLPEndpoint: Error {}

/// The server's traces, configured by the standard `OTEL_*` variables: swift-otel's tracer behind `InstrumentationSystem`, which
/// takes one bootstrap per process.
struct ServerTelemetryRuntime: Sendable {
  let otel: ServiceGroup
  let otelRun: Task<Void, any Error>
  let scope = TaskScope()

  /// Nil, installing nothing, when `environment` names no OTLP endpoint or disables the SDK.
  init?(environment: [String: String], version: String) async throws {
    guard environment["OTEL_SDK_DISABLED"]?.lowercased() != "true",
          let raw = [environment["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"], environment["OTEL_EXPORTER_OTLP_ENDPOINT"]].compactMap({ $0 }).first(where: { !$0.isEmpty })
    else { return nil }
    guard let endpoint = URL(string: raw), ["http", "https"].contains(endpoint.scheme), endpoint.host != nil,
          endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil
    else { throw UnusableOTLPEndpoint() }
    try UnsupportedTelemetrySetting.refuse(environment)
    let logger = Logger(label: "wuhu.otel")
    let service = try OTel.bootstrap(configuration: Self.configuration(version: version, log: logger), environment: environment)
    otel = ServiceGroup(services: [service], logger: logger)
    otelRun = try scope.run("otel") { [otel] in try await otel.run() }
  }

  static func configuration(version: String, log: Logger) -> OTel.Configuration {
    var configuration = OTel.Configuration.default
    configuration.diagnosticLogger = .custom(Logger(label: log.label) { _ in TraceExportLog(upstream: log) })
    configuration.serviceName = "wuhu-server"
    configuration.resourceAttributes = ["service.version": version].merging(hostName().map { ["host.name": $0] } ?? [:]) { $1 }
    configuration.logs.enabled = false
    configuration.metrics.enabled = false
    configuration.traces.otlpExporter.protocol = .httpProtobuf
    configuration.traces.otlpExporter.timeout = .seconds(2)
    configuration.traces.batchSpanProcessor.exportTimeout = .seconds(2)
    return configuration
  }

  /// Flushes the exporter within its two-second deadline.
  func shutdown() async {
    await otel.triggerGracefulShutdown()
    _ = await otelRun.result
    await scope.close()
  }
}

/// An `OTEL_*` value swift-otel accepts and then answers with `fatalError` once bootstrapped.
public struct UnsupportedTelemetrySetting: Error, Equatable, CustomStringConvertible {
  public let variable: String
  public let value: String

  public var description: String { "\(variable)=\(value) is not supported: the server exports traces over OTLP/HTTP with swift-otel" }

  /// Reads each variable as swift-otel does; a value it cannot parse it ignores, so that is no refusal.
  static func refuse(_ environment: [String: String]) throws {
    let protocolVariable = environment["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] == nil ? "OTEL_EXPORTER_OTLP_PROTOCOL" : "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"
    if environment[protocolVariable] == "grpc" { throw Self(variable: protocolVariable, value: "grpc") }
    if let sampler = environment["OTEL_TRACES_SAMPLER"], ["jaeger_remote", "parentbased_jaeger_remote", "xray"].contains(sampler) {
      throw Self(variable: "OTEL_TRACES_SAMPLER", value: sampler)
    }
    let propagators = environment["OTEL_PROPAGATORS"].map { $0.split(separator: ",").map(String.init) } ?? []
    let parsed: Set = ["tracecontext", "baggage", "b3", "b3multi", "jaeger", "xray", "otTrace", "none"]
    if propagators.allSatisfy(parsed.contains),
       let propagator = propagators.prefix(while: { $0 != "none" }).first(where: { $0 != "tracecontext" })
    {
      throw Self(variable: "OTEL_PROPAGATORS", value: propagator)
    }
  }
}

private func hostName() -> String? {
  var buffer = [CChar](repeating: 0, count: 256)
  return buffer.withUnsafeMutableBufferPointer { pointer -> String? in
    guard gethostname(pointer.baseAddress!, pointer.count - 1) == 0 else { return nil }
    let name = String(cString: pointer.baseAddress!)
    return name.isEmpty ? nil : name
  }
}
