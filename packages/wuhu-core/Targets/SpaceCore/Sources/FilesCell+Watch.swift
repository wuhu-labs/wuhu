import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

struct FileCommitPage: Sendable {
  var cursor: Int?
  var full: Bool
  var commits: [FSCommit]
}

struct FileWatchReads: Sendable {
  var read: @Sendable (FileStream.Opening, Int) throws -> FileCommitPage

  init(read: @escaping @Sendable (FileStream.Opening, Int) throws -> FileCommitPage) { self.read = read }

  init(worker: Worker) {
    read = { [weak worker] opening, after in
      let worker = worker!
      return try worker.read { reader in
        guard reader.cell(SpaceCell.ID("space")).readable(by: opening.principal).contains(opening.group) else { throw FileWatchEnded() }
        return reader.cell(FilesCell.ID(opening.group.rawValue)).commits(after: after, limit: 64)
      }
    }
  }

  func page(_ opening: FileStream.Opening, after: Int) throws -> FileCommitPage { try read(opening, after) }
}

private struct FileWatchEnded: Error {}

extension FilesCell {
  func commits(after: Int, limit: Int) -> FileCommitPage {
    let key = id.key
    let revisions = db.rows(RevisionRow.where { $0.grp.eq(key) && $0.rev.gt(Int64(after)) }.order { $0.rev }.limit(limit).select { $0.rev })
    guard let last = revisions.last else { return FileCommitPage(full: false, commits: []) }
    let rows = db.rows(FSVersionRow.where { $0.grp.eq(key) && $0.rev.gt(Int64(after)) && $0.rev.lte(last) }.order { ($0.rev, $0.path) })
    return FileCommitPage(cursor: Int(last), full: revisions.count == limit, commits: Self.reduce(rows, in: group))
  }

  private static func reduce(_ rows: [FSVersionRow], in group: GroupID) -> [FSCommit] {
    var commits: [FSCommit] = []
    var index = rows.startIndex
    while index < rows.endIndex {
      var events: [MutationEvent] = []
      let rev = Int(rows[index].rev)
      let batch = rows[index...].prefix { Int($0.rev) == rev }
      index += batch.count
      // A move journals two rows per node: a tombstone at the source and a write at the destination. The move event carries both ends, so the destination write row is suppressed.
      let moveDestinations = Set(batch.compactMap { $0.op == JournalOp.move.rawValue ? $0.aux : nil })
      let kinds = batch.reduce(into: [String: String]()) { acc, row in
        if let kind = row.kind { acc[row.path] = kind }
      }
      for row in batch {
        switch JournalOp(rawValue: row.op)! {
        case .move:
          events.append(MutationEvent(
            group: group, path: row.aux!, from: row.path, rev: rev, kind: .move,
            entry: Substrate.entryKind(kinds[row.aux!]!),
          ))
        case .write, .delete, .checkout:
          if let kind = row.kind {
            if !moveDestinations.contains(row.path) {
              events.append(MutationEvent(group: group, path: row.path, rev: rev, kind: .write, entry: Substrate.entryKind(kind)))
            }
          } else {
            events.append(MutationEvent(group: group, path: row.path, rev: rev, kind: .delete, entry: nil))
          }
        }
      }
      commits.append(FSCommit(group: group, rev: rev, events: events))
    }
    return commits
  }
}
