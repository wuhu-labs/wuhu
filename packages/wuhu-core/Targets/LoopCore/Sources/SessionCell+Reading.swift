import enum AgentsContract.SessionKind
import enum AgentsContract.SessionLifecycle
import protocol AgentsContract.SessionReading
import struct AgentsContract.SessionSummary
import SessionDomain
import struct SpaceCore.SessionDataRow
import enum SpaceCore.SQLiteDateFormat
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID
import StructuredQueries
import WuweiQueries

extension SessionCell: SessionReading {
  var summary: SessionSummary? {
    db.rows(SessionDataRow.where { $0.id.eq(id.key) }).first.map {
      SessionSummary(id: SessionID($0.id), group: GroupID(rawValue: $0.group), kind: SessionKind(rawValue: $0.kind)!, parent: $0.parent.map { SessionID($0) }, createdAt: try! SQLiteDateFormat.date(from: $0.createdAt), lifecycle: $0.lifecycle == "live" ? .live : .archived(graceExpiresAt: try! SQLiteDateFormat.date(from: $0.graceExpiresAt!)), createdBy: $0.createdBy)
    }
  }
}
