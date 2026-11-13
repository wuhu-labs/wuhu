#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

extension SpaceCell {
  public func sessionRecord(_ id: SessionID) throws -> SessionRecord {
    try Sessions.record(id.rawValue, in: db)
  }

  public func sessionHydration(_ id: SessionID, at now: Date) throws -> SessionHydration {
    try Sessions.hydrate(id.rawValue, at: SQLiteDateFormat.string(from: now), in: db)
  }

  public func sessionInputs(_ id: SessionID, at now: Date) throws -> [SessionQueueEntry] {
    try Sessions.undrained(id.rawValue, tail: Sessions.runtime(id.rawValue, in: db).queueTail, at: SQLiteDateFormat.string(from: now), in: db)
  }

  public func sessionQueueHead(_ id: SessionID, at now: Date) throws -> Int {
    Int(Sessions.queueHead(id.rawValue, tail: try Sessions.runtime(id.rawValue, in: db).queueTail, at: SQLiteDateFormat.string(from: now), in: db))
  }

  public func liveChildren(_ parent: SessionID) -> Int {
    Self.liveChildren(parent, in: db)
  }

  public static func liveChildren(_ parent: SessionID, in db: Database) -> Int {
    db.rows(SessionDataRow.where { $0.parent.eq(parent.rawValue) && $0.lifecycle.eq("live") }.asSelect().count()).first!
  }

  public static func openRequests(_ task: String, in db: Database) throws -> [OpenRequest] {
    guard !db.rows(SessionDataRow.where { $0.id.eq(task) }).isEmpty else { throw SessionStoreError.unknownSession(task) }
    return db.rows(RequestRow.where { $0.task.eq(task) && $0.status.eq("open") }.order { $0.createdAt }.select { $0.id }).map { OpenRequest(id: RequestID($0)) }
  }
}

extension SpaceCell {
  public func sessionIsLegacy(_ id: SessionID, generation: Int) throws -> Bool {
    try Sessions.isLegacy(id.rawValue, generation: Int64(generation), in: db)
  }

  public func sessionLineGenerations(_ id: SessionID) throws -> (current: Int, withLines: [Int]) {
    let key = id.rawValue
    let current = try Sessions.runtime(key, in: db).generation
    let generations = db.rows(SessionLineRow.where { $0.sessionID.eq(key) }.order(by: \.generation).select(\.generation).distinct())
    return (Int(current), generations.map { Int($0) })
  }

  public func sessionLines(_ id: SessionID, generation: Int) throws -> [StoredTranscriptLine] {
    try Sessions.lines(id.rawValue, generation: Int64(generation), in: db)
  }

  public func sessionTranscriptLineCount(_ id: SessionID) throws -> Int {
    try Sessions.transcriptLineCount(id.rawValue, generation: Sessions.runtime(id.rawValue, in: db).generation, in: db)
  }

  public func sessionTranscriptLines(_ id: SessionID, generation: Int? = nil) throws -> [StoredTranscriptLine] {
    let key = id.rawValue
    return try Sessions.transcriptLines(key, generation: try generation.map { Int64($0) } ?? Sessions.runtime(key, in: db).generation, in: db)
  }

  public func sessionLinePage(_ id: SessionID, generation: Int?, before: Int?, limit: Int) throws -> (generation: Int, lines: [StoredTranscriptLine], hasEarlier: Bool) {
    let key = id.rawValue
    let generation = try generation.map { Int64($0) } ?? Sessions.runtime(key, in: db).generation
    let rows = db.rows(SessionLineRow
      .where { $0.sessionID.eq(key) && $0.generation.eq(generation) && $0.position.lt(Int64(before ?? .max)) }
      .order { $0.position.desc() }.limit(limit + 1))
    return (Int(generation), rows.prefix(limit).reversed().map(StoredTranscriptLine.init(row:)), rows.count > limit)
  }

  public func sessionGeneration(_ id: SessionID) throws -> Int {
    let key = id.rawValue
    return Int(try Sessions.runtime(key, in: db).generation)
  }

  public func sessionGenerationState(_ id: SessionID) throws -> GenerationState {
    let key = id.rawValue
    return try Sessions.generationState(key, in: db)
  }

  public func sessionArchiveSubtree(_ root: SessionID) throws -> [SessionRecord] {
    _ = try Sessions.record(root.rawValue, in: db)
    let rows = db.rows(SessionTreeRow.all.order(by: \.id))
    let children = Dictionary(grouping: rows.filter { $0.parent != nil }, by: { $0.parent! })
    var ordered: [SessionRecord] = []
    func visit(_ id: String, depth: Int) throws {
      precondition(depth <= SessionStore.depthLimit, "session tree cycle below \(root.rawValue)")
      for child in children[id, default: []] { try visit(child.id, depth: depth + 1) }
      try ordered.append(Sessions.record(id, in: db))
    }
    try visit(root.rawValue, depth: 1)
    return ordered
  }
}
