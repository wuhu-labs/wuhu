import StructuredQueries
import StructuredQueriesSQLite
import Wuwei

@Table("usage_window_resets")
struct UsageWindowResetRow {
  var provider: String
  @Column("window_name") var window: String
  @Column("resets_at") var resetsAt: Double
}

/// One plan window of one provider.
public struct UsageWindowKey: Hashable, Codable, Sendable {
  public let provider: String
  public let window: String

  public init(provider: String, window: String) {
    self.provider = provider
    self.window = window
  }
}

extension SpaceCell {
  /// The last reset seen of each fixed plan window, kept across restarts.
  func usageWindowResets() -> [UsageWindowKey: Double] {
    Dictionary(uniqueKeysWithValues: db.rows(UsageWindowResetRow.all).map { (UsageWindowKey(provider: $0.provider, window: $0.window), $0.resetsAt) })
  }
}

extension Space {
  public func usageWindowResets() async throws -> [UsageWindowKey: Double] {
    cell.usageWindowResets()
  }

  public func saveUsageWindowResets(_ resets: [UsageWindowKey: Double]) async throws {
    try await worker.call(SpaceCell.ID("space")) { try $0.saveWindowResets(resets) }
  }
}
