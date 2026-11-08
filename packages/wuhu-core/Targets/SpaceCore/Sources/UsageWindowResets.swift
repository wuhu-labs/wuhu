import StructuredQueries
import StructuredQueriesSQLite

@Table("usage_window_resets")
struct UsageWindowResetRow {
  var provider: String
  @Column("window_name") var window: String
  @Column("resets_at") var resetsAt: Double
}

/// One plan window of one provider.
public struct UsageWindowKey: Hashable, Sendable {
  public let provider: String
  public let window: String

  public init(provider: String, window: String) {
    self.provider = provider
    self.window = window
  }
}

extension Space {
  /// The last reset seen of each fixed plan window, kept across restarts.
  public func usageWindowResets() async throws -> [UsageWindowKey: Double] {
    try await writer.read { db in
      Dictionary(uniqueKeysWithValues: try UsageWindowResetRow.all.fetchAll(db).map { (UsageWindowKey(provider: $0.provider, window: $0.window), $0.resetsAt) })
    }
  }

  public func saveUsageWindowResets(_ resets: [UsageWindowKey: Double]) async throws {
    try await writer.write { db in
      for (key, resetsAt) in resets {
        try UsageWindowResetRow.insert {
          UsageWindowResetRow(provider: key.provider, window: key.window, resetsAt: resetsAt)
        } onConflict: {
          ($0.provider, $0.window)
        } doUpdate: {
          $0.resetsAt = $1.resetsAt
        }.execute(db)
      }
    }
  }
}
