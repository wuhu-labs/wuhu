import GRDB
import struct SpaceContract.GroupID

extension Space {
  /// The documents of `group` linking to `path` of `group` or to anything under it.
  public func linkSources(into path: String, in group: GroupID) async throws -> [String] {
    let prefix = path
      .replacing("\\", with: "\\\\")
      .replacing("%", with: "\\%")
      .replacing("_", with: "\\_")
    return try await writer.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT DISTINCT src FROM links WHERE grp = ? AND dst_grp = grp AND (dst = ? OR dst LIKE ? ESCAPE '\\') ORDER BY src",
        arguments: [group.rawValue, path, prefix + "/%"],
      )
    }
  }
}
