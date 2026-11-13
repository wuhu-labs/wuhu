import struct SpaceContract.GroupID

extension Space {
  public nonisolated func currentRevisions(for principal: Principal) -> [String: Int] {
    worker.read { reader in
      let cell = reader.cell(SpaceCell.ID("space"))
      return cell.revisions(in: cell.readable(by: principal).union([principal.group]))
    }
  }
}

extension SpaceCell {
  public func revisions(in groups: Set<GroupID>) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: groups.map { group in
      (group.rawValue, Int(ctx.cell(FilesCell.ID(group.rawValue)).currentRevision()))
    })
  }
}
