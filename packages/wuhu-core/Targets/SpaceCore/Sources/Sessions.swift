#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import StructuredQueries
import Wuwei
import WuweiQueries

public enum Sessions {
  public static func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from payload: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(payload.utf8))
  }

  public static func runtime(_ key: String, in db: Database) throws -> (generation: Int64, queueTail: Int64, stepTry: Int64) {
    guard let row = db.rows(SessionRuntimeRow.where { $0.sessionID.eq(key) }).first else { throw SessionStoreError.unknownSession(key) }
    return (row.generation, row.queueTail, row.stepTry)
  }

  public static func record(_ key: String, in db: Database) throws -> SessionRecord {
    try SessionCreation.record(SessionID(key), in: db)
  }

  public static func undrained(_ key: String, tail: Int64, at clock: String, in db: Database) throws -> [SessionQueueEntry] {
    try db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && $0.id.gt(tail) && ($0.dueAt.is(nil) || $0.dueAt.lte(Optional(clock))) }.order { $0.id }).map {
      SessionQueueEntry(id: Int($0.id), input: try decode(QueueInput.self, from: $0.payload))
    }
  }

  public static func firings(of inputs: [QueueInput], in db: Database) throws -> [String] {
    var messages: [String] = []
    var requests: [String] = []
    for input in inputs {
      switch input {
      case let .message(message):
        messages.append(message.messageID.rawValue)
        if let request = message.requestID { requests.append(request.rawValue) }
      case let .notification(notification):
        if let request = notification.requestID { requests.append(request.rawValue) }
      }
    }
    guard !messages.isEmpty || !requests.isEmpty else { return [] }
    return db.rows(
      """
      SELECT firing FROM messages WHERE firing IS NOT NULL AND id IN (\(messages.map { _ in "?" }.joined(separator: ",")))
      UNION SELECT firing FROM requests WHERE firing IS NOT NULL AND id IN (\(requests.map { _ in "?" }.joined(separator: ",")))
      ORDER BY firing
      """,
      (messages + requests).map(Value.text),
    ).map { $0["firing"].text! }
  }

  public static func queueHead(_ key: String, tail: Int64, at clock: String, in db: Database) -> Int64 {
    let head = db.rows(SessionQueueRow.where { $0.sessionID.eq(key) && ($0.dueAt.is(nil) || $0.dueAt.lte(Optional(clock))) }.select { $0.id.max() }).first! ?? 0
    return max(head, tail)
  }
}

public enum SessionRunState: String, Sendable {
  case inference
  case tool
  case noRun = "no_run"
}
