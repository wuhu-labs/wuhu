import struct SpaceContract.GroupID
import StructuredQueries

extension SpaceCell {
  public func revisions(in groups: Set<GroupID>) -> [String: Int] {
    let keys = groups.map(\.rawValue)
    let rows = db.rows(RevisionRow.where { $0.grp.in(keys) }.group { $0.grp }.select { RevisionHead.Columns(group: $0.grp, rev: $0.rev.max()) })
    var revisions = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
    for row in rows { revisions[row.group] = Int(row.rev!) }
    return revisions
  }
}

extension Space {
  public nonisolated func currentRevisions(for principal: Principal) -> [String: Int] {
    let cell = cell
    return cell.revisions(in: cell.readable(by: principal).union([principal.group]))
  }
}

@Selection
private struct RevisionHead {
  let group: String
  let rev: Int64?
}
