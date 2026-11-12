#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite struct ItemLinesTests {
  @Test func `snapshot renders as the generation's first user-role message`() {
    let head = GenerationHead(
      id: UUID(),
      timestamp: Fix.instant,
      summary: "compacted history",
      snapshot: .init(
        subscriptions: [SubscriptionID("tim-1"): .timer(.cron("0 * * * *"))],
        preReads: ["space://a.md"],
      ),
      runningWork: [],
    )
    let items: [TranscriptItem] = [.generationHead(head), Fix.message()]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)

    let first = messages[0].user
    #expect(first != nil)
    guard case let .text(text) = first?.content.first else {
      Issue.record("snapshot must render as text")
      return
    }
    #expect(text.text.hasPrefix("<session-state>"))
    #expect(text.text.contains("tim-1"))
    #expect(text.text.contains("space://a.md"))
    guard case let .text(summary) = messages[1].user?.content.first else {
      Issue.record("summary must follow the snapshot")
      return
    }
    #expect(summary.text.contains("compacted history"))
    guard case let .text(nudge) = messages[2].user?.content.first else {
      Issue.record("the home re-read nudge must follow the summary")
      return
    }
    #expect(nudge.text == "Context was compacted; your home is /_/sessions/s-1/, re-read AGENTS.md and any notes you keep there.")
    #expect(messages[3].user != nil, "the message after the head renders next")
  }

  @Test func `the snapshot lists the requests the session awaits`() {
    let heard = Date(timeIntervalSince1970: 1_800_000_000)
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "s", snapshot: .init(), runningWork: [], awaiting: [
      AwaitedRequest(id: RequestID("r1"), task: SessionID("t-1"), lastHeard: heard),
      AwaitedRequest(id: RequestID("r2"), task: SessionID("t-2"), lastHeard: heard),
    ])
    let messages = head.lines(session: Fix.session).map(\.message)
    guard case let .text(text) = messages[0].user?.content.first else {
      Issue.record("snapshot must render as text")
      return
    }
    #expect(text.text.contains(
      "awaiting final reports: r1 from t-1 (last heard 2027-01-15T08:00:00Z), r2 from t-2 (last heard 2027-01-15T08:00:00Z)",
    ))
  }

  @Test func `a creation head carries no summary and no nudge`() {
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "", snapshot: .init(), runningWork: [])
    let items: [TranscriptItem] = [.generationHead(head), Fix.message()]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    #expect(messages.count == 2)
    #expect(!messages.contains { message in
      if case let .text(text)? = message.user?.content.first { return text.text.contains("compacted") }
      return false
    })
  }

  @Test func `tool results pair with kernel-minted call ids`() {
    let call = ToolCall(id: "k-1", name: "read", arguments: .object(["path": .string("space://a.md")]))
    let items: [TranscriptItem] = [
      Fix.assistant(text: "reading", totalTokens: 10, toolCalls: [call]),
      Fix.result(
        .read(.init(path: "space://a.md", revision: .journal(3), content: "file body")),
        provenance: .toolCall(.init("k-1")),
      ),
    ]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)

    #expect(messages[0].assistant?.content.contains(.toolCall(call)) == true)
    let result = messages[1].toolResult
    #expect(result?.toolCallId == "k-1")
    #expect(result?.content == [.text("file body")])
    #expect(result?.isError == false)
  }

  @Test func `a scope notice renders once and empty context renders no lines`() {
    let notice = Fix.context(["machines://m1/repo": "machines://m1/repo"], text: "repo manual")
    let lines = notice.lines(session: Fix.session)
    #expect(lines.count == 1)
    #expect(lines.first?.key == LineKey.scope)
    #expect(lines.first?.role == .user)
    guard case let .text(text)? = lines.first?.message.user?.content.first else {
      Issue.record("scope notice must contain text")
      return
    }
    #expect(text.text.hasSuffix("\n\nrepo manual"))
    #expect(Fix.context(["machines://m1/tmp": nil]).lines(session: Fix.session).isEmpty)
  }

  @Test func `failures render as error tool results`() {
    let items: [TranscriptItem] = [
      Fix.result(.failure(.init(message: "no such file")), provenance: .toolCall(.init("k-2"))),
    ]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    let result = messages[0].toolResult
    #expect(result?.isError == true)
    #expect(result?.content == [.text("no such file")])
  }

  @Test func `re-executed pre-reads render as user-role messages`() {
    let items: [TranscriptItem] = [
      Fix.result(
        .read(.init(path: "space://a.md", revision: .journal(3), content: "file body")),
        provenance: .compactionReestablishment,
      ),
    ]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    guard case let .text(text) = messages[0].user?.content.first else {
      Issue.record("re-established read must be user role")
      return
    }
    #expect(text.text.contains("<compaction-reestablished space://a.md>"))
    #expect(text.text.contains("file body"))
  }

  @Test func `messages render header then blank line then verbatim body`() {
    let items: [TranscriptItem] = [Fix.message(text: "hello there")]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    guard case let .text(text) = messages[0].user?.content.first,
          case let .message(message) = items[0]
    else {
      Issue.record("a conversation message must be user role")
      return
    }
    #expect(text.text == message.header.render() + "\n\nhello there")
  }

  @Test func `stored attribution renders without a live directory`() {
    guard case var .message(message) = Fix.message(sender: "alice", text: "hello there") else { return }
    message.sender.handle = "ali"
    let items: [TranscriptItem] = [.message(message)]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    guard case let .text(text) = messages[0].user?.content.first else {
      Issue.record("a conversation message must be user role")
      return
    }
    #expect(text.text.hasPrefix("<sender>ali (alice)</sender>\n"))
  }

  @Test func `a person's request carries the viewed page into the user turn`() {
    let items: [TranscriptItem] = [Fix.message(kind: .request, request: "r-1", viewing: "wuhu://ops.localspace/runbook.md")]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    guard case let .text(text) = messages[0].user?.content.first else {
      Issue.record("a request must be user role")
      return
    }
    #expect(text.text.contains("\n<viewing>wuhu://ops.localspace/runbook.md</viewing>\n"))
  }

  @Test func `render never synthesizes pressure notices`() {
    let items: [TranscriptItem] = [Fix.assistant(totalTokens: 800)]
    let lines = items.flatMap { $0.lines(session: Fix.session) }
    let messages = lines.map(\.message)
    #expect(messages.count == 1)
    #expect(messages[0].assistant != nil)
  }
}
