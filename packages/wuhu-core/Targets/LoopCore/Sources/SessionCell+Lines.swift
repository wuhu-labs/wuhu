#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceCore.SessionLineRow
import struct SpaceCore.SessionRecord
import enum SpaceCore.Sessions
import struct SpaceCore.StoredTranscriptLine
import struct SpaceCore.TranscriptCursor
import StructuredQueries
import Wuwei
import WuweiQueries

extension SessionCell {
  func record(_ id: SessionID) throws -> SessionRecord {
    try Sessions.record(id.rawValue, in: db)
  }

  func lineEnd(_ id: SessionID) throws -> TranscriptCursor {
    let key = id.rawValue
    let generation = try Sessions.runtime(key, in: db).generation
    let last = db.rows(SessionLineRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }
      .order { $0.position.desc() }.limit(1).select(\.position)).first
    return TranscriptCursor(generation: Int(generation), position: last.map { Int($0) } ?? -1)
  }

  func lines(_ id: SessionID, generation: Int, after: Int, prompt: Bool = false) throws -> [StoredTranscriptLine] {
    let keys = prompt ? Sessions.promptKeys : []
    return db.rows(SessionLineRow
      .where { $0.sessionID.eq(id.rawValue) && $0.generation.eq(Int64(generation)) && ($0.position.gt(Int64(after)) || $0.key.in(keys)) }
      .order(by: \.position)).map(StoredTranscriptLine.init(row:))
  }
}
