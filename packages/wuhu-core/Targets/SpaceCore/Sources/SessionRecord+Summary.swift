import AgentsContract
import struct SpaceIDs.GroupID

extension SessionRecord {
  /// What another family reads of a session: its group, title, kind, parent, creation, lifecycle and creator.
  public var summary: SessionSummary {
    SessionSummary(
      id: id, group: group, title: title, kind: kind, parent: parent, createdAt: createdAt, lifecycle: lifecycle, createdBy: createdBy,
    )
  }
}
