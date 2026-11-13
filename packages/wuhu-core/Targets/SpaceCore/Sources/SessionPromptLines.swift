#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.TranscriptLine
import StructuredQueries
import WuhuAI
import Wuwei
import WuweiQueries

extension SessionPrompts {
  static func keepsOpening(_ key: String, generation: Int64, in db: Wuwei.Database) -> Bool {
    if let first = db.rows(SessionLineRow.where {
      $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0)) && !$0.key.in(Sessions.openingKeys)
    }.order { $0.position.asc() }.limit(1).select(\.position)).first {
      return first == Int64(Sessions.openingKeys.count + 1)
    }
    return db.rows(PromptPointerRow.where { $0.sessionID.eq(key) && $0.generation.eq(generation) }.limit(1)).isEmpty
  }

  static func opening(_ key: String, generation: Int64, in db: Wuwei.Database) throws -> [String] {
    try db.rows(SessionLineRow.where {
      $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.key.in(Sessions.openingKeys) && $0.position.lte(Int64(Sessions.openingKeys.count))
    }.order { $0.position.asc() }.select(\.message)).map { message in
      guard case let .user(user) = try Sessions.decode(Message.self, from: message), case let .text(text)? = user.content.first else {
        preconditionFailure("an opening line is one user-role text")
      }
      return text.text
    }
  }

  static func writePreamble(_ key: String, generation: Int64, rendered: String, opening: PromptOpening?, at: Date, in db: inout Wuwei.Database) throws {
    let hasLines = !db.rows(SessionLineRow.where {
      $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.gt(Int64(0))
    }.limit(1)).isEmpty
    guard opening != nil || hasLines else { return }
    let row = SessionLineRow(
      sessionID: key, generation: generation, position: 0, at: SQLiteDateFormat.string(from: at),
      role: TranscriptLine.Role.system.rawValue, key: "system", message: try Sessions.preambleLine(rendered: rendered), meta: nil,
    )
    try db.execute(SessionLineRow.insert { row } onConflict: { ($0.sessionID, $0.generation, $0.position) })
    guard let opening else { return }
    for (offset, text) in [opening.group, opening.session].enumerated() where !text.isEmpty {
      let line = TranscriptLine(at: at, key: Sessions.openingKeys[offset], message: .user(.init(content: [.text(text)])))
      let row = SessionLineRow(
        sessionID: key, generation: generation, position: Int64(offset + 1), at: SQLiteDateFormat.string(from: at),
        role: line.role.rawValue, key: line.key, message: try Sessions.encode(line.message), meta: nil,
      )
      try db.execute(SessionLineRow.insert { row })
    }
  }
}

@Table("session_pointers")
private struct PromptPointerRow {
  @Column("session_id") var sessionID: String
  var generation: Int64
}
