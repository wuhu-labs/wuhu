import struct OperationProtocol.OperationError
import Synchronization

/// The streams of every machine's tunnel, shared by all `MachineOperations` that reach machines through the same tunnels: an
/// operation holds its lanes (its control lane and one per output channel) from admission until its driver ends.
public final class TunnelLanes: Sendable {
  /// Streams kept free for describes alongside the operations' lanes.
  public static let describeStreams = 2

  private let limit: @Sendable (String) async -> Int?
  private let held = Mutex<[String: Int]>([:])

  /// `limit` answers how many concurrent exchanges a machine's tunnel carries right now; nil admits without a check.
  public init(limit: @escaping @Sendable (String) async -> Int? = { _ in nil }) {
    self.limit = limit
  }

  /// Holds `lanes` on the machine's tunnel, or refuses with `capacityExceeded` (`tunnelStreams`) when they do not fit.
  func reserve(_ lanes: Int, on machine: String) async throws {
    let limit = await limit(machine)
    try held.withLock { held throws(OperationError) in
      let used = Self.describeStreams + held[machine, default: 0]
      if let limit, used + lanes > limit {
        throw OperationError.capacityExceeded("tunnelStreams", used: used, limit: limit, requested: lanes)
      }
      held[machine, default: 0] += lanes
    }
  }

  /// Holds lanes for an operation already on the machine, a resumed one, whether they fit or not.
  func hold(_ lanes: Int, on machine: String) {
    held.withLock { $0[machine, default: 0] += lanes }
  }

  func release(_ lanes: Int, on machine: String) {
    held.withLock { held in
      let left = held[machine, default: 0] - lanes
      held[machine] = left > 0 ? left : nil
    }
  }
}
