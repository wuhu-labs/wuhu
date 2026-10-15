#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct WorkerProtocol.WorkerHello

public struct ExecutionWorkerBootstrap: Codable, Sendable {
  public let parentSocket: String
  public let workerSocket: String
  public let token: String
  public let tracesAttempts: Bool

  public init(parentSocket: String, workerSocket: String, token: String, tracesAttempts: Bool) {
    self.parentSocket = parentSocket; self.workerSocket = workerSocket; self.token = token; self.tracesAttempts = tracesAttempts
  }

  static let routeTransitionsCapability = "owner.route-transitions.v1"

  public static func hello(release: String) -> WorkerHello {
    let capabilities = WorkerHello.baseline.union(["owner.session.v1", "owner.inference.v1", "owner.spawn.v1", "execution.registry.v1"])
    return WorkerHello(capabilities: capabilities.union([routeTransitionsCapability]), required: capabilities, release: release)
  }
}
