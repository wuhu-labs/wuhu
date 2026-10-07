#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
@testable import SpaceCore
import Testing

@Suite struct RestartHeadCompatibilityTests {
  private struct Dev88Head: Hashable, Codable {
    var id: UUID
    var timestamp: Date
    var summary: String
    var snapshot: StateSnapshot
    var settle: SettleState?
    var note: String?

    init(_ head: GenerationHead) {
      id = head.id
      timestamp = head.timestamp
      summary = head.summary
      snapshot = head.snapshot
      settle = head.settle
      note = head.note
    }
  }

  private enum Dev88Item: Codable {
    case generationHead(Dev88Head)
  }

  @Test func dev88DecodesPersistedRestartHeadAndRetainsItsSnapshot() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await store.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      _ = try await store.restart(id, note: "restart")
      let item = try #require(try await store.transcript(id).items.first)
      guard case let .generationHead(head) = item else { Issue.record("missing restart head"); return }
      #expect(head.settleBoundary != nil)
      let bytes = try #require(try await store.writer.read { db in
        try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ? AND id = ?", arguments: [id.rawValue, head.id.uuidString.lowercased()])
      })
      let decoded = try Sessions.decode(Dev88Item.self, from: bytes)
      guard case let .generationHead(oldHead) = decoded else { return }
      #expect(oldHead == Dev88Head(head))
      #expect(oldHead.settle != nil)
      #expect(oldHead.note == "restart")
    }
  }

  @Test(arguments: [false, true])
  func headsWithoutRestartEncodeByteIdentically(hasSettle: Bool) throws {
    let head = GenerationHead(
      id: UUID(), timestamp: fixedDate, summary: "summary", snapshot: .init(),
      settle: hasSettle ? SettleState(owed: [.init("ch1"): .owed]) : nil, note: "note",
    )
    #expect(head.settleBoundary == nil)
    let newBytes = try Sessions.encode(TranscriptItem.generationHead(head))
    let oldBytes = try Sessions.encode(Dev88Item.generationHead(Dev88Head(head)))
    #expect(newBytes == oldBytes)
    #expect(!newBytes.contains("settleBoundary"))
  }
}
