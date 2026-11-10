import Dependencies
import DeterministicDependencies
import Foundation
import Scratch
import SessionDomain
@testable import SpaceCore
import Synchronization
import Testing
import struct WuhuAI.Context

// A message from a conversation the session last posted in before its
// generation began arrives with that exchange ahead of its body.
@Suite(.deterministicDependencies) struct StaleExchangeTests {
  static let utc = TimeZone(identifier: "UTC")!
  static let person = Sender(id: "minsheng", timeZone: utc)

  final class Ticker: Sendable {
    let now = Mutex(fixedDate)
    // Each call is one second after the last.
    func tick() -> Date { now.withLock { $0 += 1; return $0 } }
  }

  struct Rig {
    let space: Space
    let agent: SessionID
    let ticker: Ticker
    var store: SessionStore { space.sessions }

    func says(_ id: String, _ text: String) async throws {
      _ = try await store.post(.box(agent), messageID: MessageID(id), sender: StaleExchangeTests.person, content: .init(text: text))
    }

    func replies(_ id: String, to target: String? = nil, _ text: String) async throws {
      _ = try await store.post(
        .box(agent), messageID: MessageID(id), sender: Sender(id: agent.rawValue, timeZone: StaleExchangeTests.utc),
        senderSession: agent, replyTarget: target.map { MessageID($0) }, content: .init(text: text),
      )
    }

    func compacts(keeping kept: Range<Int>? = nil) async throws {
      let head = GenerationHead(id: UUID(), timestamp: ticker.tick(), summary: "folded", snapshot: .init(), runningWork: [])
      _ = try await store.writeCompaction(agent, head: head, kept: kept)
    }

    func settles() async throws {
      try await store.appendAssistant(
        agent, attemptID: UUID(), message: .init(content: []),
        metadata: .init(stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 0, totalTokens: 1)),
      )
    }

    func rendered() async throws -> Context {
      try await store.transcript(agent).renderRequest(session: agent, systemPrompt: "p")
    }

    func drained() async throws -> [String] {
      try await store.deliverMail()
      return try await store.drainQueue(agent).items.compactMap {
        if case let .message(message) = $0 { message.content.text } else { nil }
      }
    }
  }

  func makeRig(_ ticker: Ticker = Ticker(), open: () throws -> Space = { try Space.inMemory() }) async throws -> Rig {
    let space = try opened(ticker, open)
    let agent = try await space.sessions.createSession(
      group: .shared, title: "A", kind: .agent, createdBy: "owner", model: .test, snapshot: .init(),
    )
    return Rig(space: space, agent: agent, ticker: ticker)
  }

  func opened(_ ticker: Ticker, _ open: () throws -> Space) throws -> Space {
    try withDependencies { $0.date = DateGenerator { ticker.tick() } } operation: { try open() }
  }

  func stamp(_ text: String) -> String {
    text.replacingOccurrences(of: #"time="[^"]*""#, with: #"time="t""#, options: .regularExpression)
  }

  @Test func followUpAfterCompactionCarriesTheExchangeOnce() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    try await rig.says("m2", "unrelated")
    _ = try await rig.drained()
    try await rig.replies("m3", to: "m1", "bench count: 42 <ok>")
    try await rig.compacts()
    try await rig.says("m4", "did you read the trace?")
    try await rig.says("m5", "why does it fail?")
    let a = rig.agent.rawValue
    #expect(try await rig.drained().map(stamp) == [
      """
      <earlier-in-conversation>
      <message id="m1" sender="minsheng" time="t">
      count the bench
      </message>
      <message id="m3" sender="\(a)" time="t">
      bench count: 42 &lt;ok&gt;
      </message>
      </earlier-in-conversation>

      did you read the trace?
      """,
      "why does it fail?",
    ])
    try await rig.says("m6", "hello?")
    #expect(try await rig.drained() == ["hello?"])
  }

  @Test func postInTheCurrentGenerationAttachesNothing() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    try await rig.replies("m2", to: "m1", "42")
    #expect(try await rig.drained() == ["count the bench"])
    try await rig.compacts()
    try await rig.replies("m3", "and the trace is in")
    try await rig.says("m4", "thanks")
    #expect(try await rig.drained() == ["thanks"])
  }

  @Test func laterCompactionAttachesAgainCutToTheCap() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    _ = try await rig.drained()
    try await rig.replies("m2", String(repeating: "x", count: EarlierMessage.maxBytes + 10))
    try await rig.compacts()
    try await rig.says("m3", "next")
    _ = try await rig.drained()
    try await rig.compacts()
    try await rig.says("m4", "again")
    let shown = try #require(try await rig.drained().first)
    let a = rig.agent.rawValue
    #expect(stamp(shown) == """
    <earlier-in-conversation>
    <message id="m1" sender="minsheng" time="t">
    count the bench
    </message>
    <message id="m2" sender="\(a)" time="t">
    \(String(repeating: "x", count: EarlierMessage.maxBytes))
    [cut at \(EarlierMessage.maxBytes) of \(EarlierMessage.maxBytes + 10) bytes; read message m2 for the rest]
    </message>
    </earlier-in-conversation>

    again
    """)
  }

  @Test func escapingCountsAgainstTheCap() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    _ = try await rig.drained()
    try await rig.replies("m2", String(repeating: "&", count: EarlierMessage.maxBytes))
    try await rig.compacts()
    try await rig.says("m3", "next")
    let shown = try #require(try await rig.drained().first)
    let taken = EarlierMessage.maxBytes / 5
    #expect(shown.contains("""
    \(String(repeating: "&amp;", count: taken))
    [cut at \(taken) of \(EarlierMessage.maxBytes) bytes; read message m2 for the rest]
    </message>
    """))
  }

  @Test func blockDrainedAfterAReopenIsStoredOnceAndNeverReRendered() async throws {
    let folder = try ScratchFolder("stale-exchange-reopen")
    let file = folder.url.appending(path: "space.sqlite")
    let ticker = Ticker()
    let first = try await makeRig(ticker) { try Space.open(file: file) }
    try await first.says("m1", "count the bench")
    _ = try await first.drained()
    try await first.replies("m2", to: "m1", "42")
    try await first.compacts()
    try await first.says("m3", "and the trace?")
    try await first.space.close()

    let rig = try Rig(space: opened(ticker) { try Space.open(file: file) }, agent: first.agent, ticker: ticker)
    let shown = try await rig.drained()
    #expect(shown.map { $0.hasPrefix("<earlier-in-conversation>\n<message id=\"m1\" sender=\"minsheng\"") } == [true])
    let before = try await rig.rendered()
    _ = try await rig.space.setUserProfile(principal: "minsheng", handle: "ms", displayName: nil)
    try await rig.replies("m4", to: "m3", "reading it")
    try await rig.says("m5", "and?")
    #expect(try await rig.drained() == ["and?"])
    let blocks = try await rig.store.transcript(rig.agent).items.filter {
      if case let .message(message) = $0 { message.content.text.contains("<earlier-in-conversation>") } else { false }
    }
    #expect(blocks.count == 1)
    let after = try await rig.rendered()
    #expect(Array(after.messages.prefix(before.messages.count)) == before.messages)
    #expect(try await rig.rendered() == after)
    try await rig.space.close()
  }

  @Test func startOverAttachesTheExchange() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    _ = try await rig.drained()
    try await rig.replies("m2", to: "m1", "42")
    try await rig.settles()
    try await rig.store.restart(rig.agent)
    try await rig.says("m3", "and the trace?")
    let a = rig.agent.rawValue
    #expect(try await rig.drained().map(stamp) == [
      """
      <earlier-in-conversation>
      <message id="m1" sender="minsheng" time="t">
      count the bench
      </message>
      <message id="m2" sender="\(a)" time="t">
      42
      </message>
      </earlier-in-conversation>

      and the trace?
      """,
    ])
  }

  @Test func compactionKeepingAMessageFromTheConversationAttachesNothing() async throws {
    let rig = try await makeRig()
    try await rig.says("m1", "count the bench")
    _ = try await rig.drained()
    try await rig.replies("m2", to: "m1", "42")
    let items = try await rig.store.transcript(rig.agent).items
    let kept = try #require(items.firstIndex {
      if case let .message(message) = $0 { message.messageID == MessageID("m1") } else { false }
    })
    try await rig.compacts(keeping: kept ..< items.count)
    try await rig.says("m3", "and the trace?")
    #expect(try await rig.drained() == ["and the trace?"])
  }
}
