import Foundation
import JSONValue
import SessionDomain
import Testing
import WuhuAI

@Suite struct RenderRequestTests {
  @Test func `snapshot renders as the generation's first user-role message`() async {
    let head = GenerationHead(
      id: UUID(),
      timestamp: Fix.instant,
      summary: "compacted history",
      snapshot: .init(
        subscriptions: [SubscriptionID("tim-1"): .timer(.cron("0 * * * *"))],
        preReads: ["space://a.md"],
      ),
    )
    let transcript = Transcript(items: [.generationHead(head), Fix.message()], keptCount: 1)
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")

    #expect(context.systemPrompt == "sys")
    let first = context.messages[0].user
    #expect(first != nil)
    guard case let .text(text) = first?.content.first else {
      Issue.record("snapshot must render as text")
      return
    }
    #expect(text.text.hasPrefix("<session-state>"))
    #expect(text.text.contains("tim-1"))
    #expect(text.text.contains("space://a.md"))
    guard case let .text(summary) = context.messages[1].user?.content.first else {
      Issue.record("summary must follow the snapshot")
      return
    }
    #expect(summary.text.contains("compacted history"))
    guard case let .text(nudge) = context.messages[2].user?.content.first else {
      Issue.record("the home re-read nudge must follow the summary")
      return
    }
    #expect(nudge.text == "Context was compacted; your home is /_/sessions/s-1/, re-read AGENTS.md and any notes you keep there.")
    #expect(context.messages[3].user != nil, "the message after the head renders next")
  }

  @Test func `a creation head carries no summary and no nudge`() async {
    let head = GenerationHead(id: UUID(), timestamp: Fix.instant, summary: "", snapshot: .init())
    let transcript = Transcript(items: [.generationHead(head), Fix.message()], keptCount: 1)
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    #expect(context.messages.count == 2)
    #expect(!context.messages.contains { message in
      if case let .text(text)? = message.user?.content.first { return text.text.contains("compacted") }
      return false
    })
  }

  @Test func `tool results pair with kernel-minted call ids`() async {
    let call = ToolCall(id: "k-1", name: "read", arguments: .object(["path": .string("space://a.md")]))
    let transcript = Transcript(items: [
      Fix.assistant(text: "reading", totalTokens: 10, toolCalls: [call]),
      Fix.result(
        .read(.init(path: "space://a.md", revision: .journal(3), content: "file body")),
        provenance: .toolCall(.init("k-1")),
      ),
    ])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")

    #expect(context.messages[0].assistant?.content.contains(.toolCall(call)) == true)
    let result = context.messages[1].toolResult
    #expect(result?.toolCallId == "k-1")
    #expect(result?.content == [.text("file body")])
    #expect(result?.isError == false)
  }

  @Test func `repository context renders after the turn's tool results and empty context not at all`() async {
    let calls = ["k-1", "k-2"].map { ToolCall(id: $0, name: "read", arguments: .object([:])) }
    let transcript = Transcript(items: [
      Fix.assistant(text: "reading", totalTokens: 10, toolCalls: calls),
      Fix.result(.read(.init(path: "machines://m1/repo/a", revision: .journal(1), content: "a")), provenance: .toolCall(.init("k-1"))),
      Fix.context(["machines://m1/repo": "machines://m1/repo"], text: "repo manual"),
      Fix.result(.read(.init(path: "machines://m1/tmp/b", revision: .journal(1), content: "b")), provenance: .toolCall(.init("k-2"))),
      Fix.context(["machines://m1/tmp": nil]),
    ])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    #expect(context.messages.count == 4)
    #expect(context.messages[1].toolResult?.toolCallId == "k-1")
    #expect(context.messages[2].toolResult?.toolCallId == "k-2")
    guard case let .text(notice)? = context.messages[3].user?.content.first else {
      Issue.record("the context must render as a user-role notice")
      return
    }
    #expect(notice.text.hasSuffix("\n\nrepo manual"))
  }

  @Test func `failures render as error tool results`() async {
    let transcript = Transcript(items: [
      Fix.result(.failure(.init(message: "no such file")), provenance: .toolCall(.init("k-2"))),
    ])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    let result = context.messages[0].toolResult
    #expect(result?.isError == true)
    #expect(result?.content == [.text("no such file")])
  }

  @Test func `re-executed pre-reads render as user-role messages`() async {
    let transcript = Transcript(items: [
      Fix.result(
        .read(.init(path: "space://a.md", revision: .journal(3), content: "file body")),
        provenance: .compactionReestablishment,
      ),
    ])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    guard case let .text(text) = context.messages[0].user?.content.first else {
      Issue.record("re-established read must be user role")
      return
    }
    #expect(text.text.contains("<compaction-reestablished space://a.md>"))
    #expect(text.text.contains("file body"))
  }

  @Test func `messages render header then blank line then verbatim body`() async {
    let transcript = Transcript(items: [Fix.message(text: "hello there")])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    guard case let .text(text) = context.messages[0].user?.content.first,
          case let .message(message) = transcript.items[0]
    else {
      Issue.record("a conversation message must be user role")
      return
    }
    #expect(text.text == message.header.render() + "\n\nhello there")
  }

  @Test func `handles passed to a render attribute every message sender`() async {
    let transcript = Transcript(items: [Fix.message(sender: "alice", text: "hello there")])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys", handles: ["alice": "ali"])
    guard case let .text(text) = context.messages[0].user?.content.first else {
      Issue.record("a conversation message must be user role")
      return
    }
    #expect(text.text.hasPrefix("<sender>ali (alice)</sender>\n"))
  }

  @Test func `render never synthesizes pressure notices`() async {
    let transcript = Transcript(items: [Fix.assistant(totalTokens: 800)])
    let context = await transcript.renderRequest(session: Fix.session, systemPrompt: "sys")
    #expect(context.messages.count == 1)
    #expect(context.messages[0].assistant != nil)
  }
}
