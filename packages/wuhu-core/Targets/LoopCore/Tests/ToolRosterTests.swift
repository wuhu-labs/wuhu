import Foundation
@testable import LoopCore
import SessionDomain
import Testing
import enum WuhuAI.Tool

@Suite struct ToolRosterTests {
  private func tool(_ name: String, _ description: String = "does it") -> Tool {
    Tool(name: name, description: description, parameters: .object(["type": "object"]))
  }

  private func transcript(_ notices: [String]) -> Transcript {
    Transcript(items: notices.map { notice in
      .notification(.init(id: UUID(), timestamp: Date(timeIntervalSince1970: 0), kind: .context, subscriptionID: ToolRosterChanged.source, content: .init(text: notice)))
    }, keptCount: 0)
  }

  @Test func theNoticeNamesWhatWasAddedRemovedAndChanged() throws {
    let stored = [tool("read"), tool("timer"), tool("exec")]
    let live = [tool("read"), tool("exec", "does it differently"), tool("copy"), tool("watch")]
    let changed = try #require(ToolRosterChanged(stored: stored, live: live, told: transcript([])))
    #expect(changed.notice.contains("Added: copy, watch. Removed: timer. Changed: exec. "))
    #expect(changed.notice.hasPrefix("The server was upgraded") && changed.notice.contains("until your next compaction"))

    let removal = try #require(ToolRosterChanged(stored: stored, live: [tool("read"), tool("exec")], told: transcript([])))
    #expect(removal.notice.contains("differ from the list this generation was given. Removed: timer. Your list stays"))
  }

  @Test func nothingIsSaidWithoutAChangeOrTwice() throws {
    let stored = [tool("read"), tool("exec")]
    #expect(ToolRosterChanged(stored: stored, live: stored, told: transcript([])) == nil)
    #expect(ToolRosterChanged(stored: stored, live: stored.reversed(), told: transcript([])) == nil, "an order is no change")

    let live = stored + [tool("copy")]
    let first = try #require(ToolRosterChanged(stored: stored, live: live, told: transcript([])))
    #expect(ToolRosterChanged(stored: stored, live: live, told: transcript([first.notice])) == nil)
    let second = try #require(ToolRosterChanged(stored: stored, live: live + [tool("watch")], told: transcript([first.notice])), "another upgrade is another notice")
    #expect(second.notice.contains("Added: copy, watch."))
  }
}
