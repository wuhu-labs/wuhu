#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
import Testing
import enum WuhuAI.Tool

@Suite struct ToolRosterTests {
  private func tool(_ name: String, _ description: String = "does it") -> Tool {
    Tool(name: name, description: description, parameters: .object(["type": "object"]))
  }

  private func lines(_ notices: [String]) -> [TranscriptLine] {
    notices.map { notice in
      TranscriptLine(at: anchor, key: LineKey.toolRoster, message: .user(.init(content: [
        .text(MessageHeader.systemNotice(source: ToolRosterChanged.source, at: anchor).render() + "\n\n" + notice),
      ])))
    }
  }

  @Test func theNoticeNamesWhatWasAddedRemovedAndChanged() throws {
    let stored = [tool("read"), tool("timer"), tool("exec")]
    let live = [tool("read"), tool("exec", "does it differently"), tool("copy"), tool("watch")]
    let changed = try #require(ToolRosterChanged(stored: stored, live: live, told: lines([])))
    #expect(changed.notice.contains("Added: copy, watch. Removed: timer. Changed: exec. "))
    #expect(changed.notice.hasPrefix("The server was upgraded") && changed.notice.contains("until your next compaction"))

    let removal = try #require(ToolRosterChanged(stored: stored, live: [tool("read"), tool("exec")], told: lines([])))
    #expect(removal.notice.contains("differ from the list this generation was given. Removed: timer. Your list stays"))
  }

  @Test func nothingIsSaidWithoutAChangeOrTwice() throws {
    let stored = [tool("read"), tool("exec")]
    #expect(ToolRosterChanged(stored: stored, live: stored, told: lines([])) == nil)
    #expect(ToolRosterChanged(stored: stored, live: stored.reversed(), told: lines([])) == nil, "an order is no change")

    let live = stored + [tool("copy")]
    let first = try #require(ToolRosterChanged(stored: stored, live: live, told: lines([])))
    #expect(ToolRosterChanged(stored: stored, live: live, told: lines([first.notice])) == nil)
    var unrelated = lines([first.notice])
    unrelated[0].key = LineKey.scope
    #expect(ToolRosterChanged(stored: stored, live: live, told: unrelated) != nil)
    let second = try #require(ToolRosterChanged(stored: stored, live: live + [tool("watch")], told: lines([first.notice])), "another upgrade is another notice")
    #expect(second.notice.contains("Added: copy, watch."))
  }
}
