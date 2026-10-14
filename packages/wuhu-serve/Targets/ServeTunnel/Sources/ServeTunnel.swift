import FetchTunnel
import Serve

public enum ServeTunnel {
  public static func run(handler: @escaping Handler, over transport: TunnelTransport, limits: TunnelLimits = .init()) async throws {
    try await Tunnel.serve(over: transport, limits: limits, handler: handler)
  }
}
