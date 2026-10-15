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
  public let telemetry: Bool?
  public let machines: Bool

  public init(parentSocket: String, workerSocket: String, token: String, tracesAttempts: Bool, machines: Bool = false, telemetry: Bool = false) {
    self.telemetry = telemetry; self.machines = machines
    self.parentSocket = parentSocket; self.workerSocket = workerSocket; self.token = token; self.tracesAttempts = tracesAttempts
  }

  static let handoffCapability = "execution.handoff.v1"
  static let remindersCapability = "owner.reminders.v1"
  static let routeTransitionsCapability = "owner.route-transitions.v1"

  public static func hello(release: String) -> WorkerHello {
    let capabilities = WorkerHello.baseline.union(["owner.session.v1", "owner.inference.v1", "owner.spawn.v1", "execution.registry.v1", "owner.tools.v1", "owner.scripts.v1", "owner.runtime.v1", "execution.handlers.v1"])
    return WorkerHello(capabilities: capabilities.union([routeTransitionsCapability, remindersCapability, handoffCapability, "telemetry.spans.v1"]), required: capabilities, release: release)
  }
}
