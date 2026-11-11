import DeterministicDependencies
import Fetch
import FetchSSE
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct SessionLineRoutesTests {
  private func event(_ data: String) throws -> SessionLineEvent {
    try JSONValueDecoder().decode(SessionLineEvent.self, from: #require(JSONValue.parse(data)))
  }

  @Test func `the lines stream resets to the generation, then sends each line the page reads, the late prompt once`() async throws {
    try await withSessionDeps {
      let session = Mutex<(Space, SessionID)?>(nil)
      let harness = try await SessionHarness { _, _ in
        if let (space, id) = session.withLock({ $0 }) { _ = try await sessionPrompt(space: space, session: id) }
        return reply("Hello")
      }
      let id = try await harness.createSession()
      session.withLock { $0 = (harness.space, id) }
      let response = try await harness.get("/v1/session/\(id.rawValue)/lines")
      #expect(response.status == .ok)
      #expect(response.headers[.contentType]?.hasPrefix("text/event-stream") == true)
      var frames = response.sse().makeAsyncIterator()
      #expect(try event(try #require(await frames.next()).data) == .reset(generation: 0))

      var heard: [SessionLinePayload] = []
      for (text, replies) in [("hi", 1), ("again", 2)] {
        try await harness.deliver(text, to: id)
        while heard.count { $0.role == .assistant } < replies {
          guard case let .line(0, line) = try event(try #require(await frames.next()).data) else {
            Issue.record("heard a reset")
            return
          }
          heard.append(line)
        }
      }
      let page = try await harness.get("/v1/session/\(id.rawValue)/lines/page").json(SessionLinesPageOutput.self)

      #expect(page.generation == 0)
      #expect(!page.hasEarlier)
      #expect(heard.count { $0.key == "system" } == 1)
      #expect(page.lines == heard.sorted { $0.position < $1.position }, "heard \(heard.map(\.key)), page \(page.lines.map(\.key))")
      #expect(page.lines.first?.key == "system")
      #expect(page.lines.first?.position == 0)
    }
  }

  @Test func `the lines page walks back from the newest line by position`() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness { _, _ in reply("Hello") }
      let id = try await harness.createSession()
      try await harness.deliver("hi", to: id)
      try await until("the reply's line") {
        try await harness.get("/v1/session/\(id.rawValue)/lines/page").json(SessionLinesPageOutput.self).lines.contains { $0.role == .assistant }
      }
      let all = try await harness.get("/v1/session/\(id.rawValue)/lines/page").json(SessionLinesPageOutput.self).lines
      let newest = try await harness.get("/v1/session/\(id.rawValue)/lines/page", query: ["limit": "1"]).json(SessionLinesPageOutput.self)
      #expect(newest.lines == [all.last!])
      #expect(newest.hasEarlier)
      let earlier = try await harness.get(
        "/v1/session/\(id.rawValue)/lines/page", query: ["generation": "0", "before": String(all.last!.position)],
      ).json(SessionLinesPageOutput.self)
      #expect(earlier.lines == all.dropLast())
      #expect(!earlier.hasEarlier)
    }
  }

  @Test func `the lines routes refuse a half cursor, a bad limit, an unknown session and an anonymous viewer`() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      #expect(try await harness.get("/v1/session/\(id.rawValue)/lines", query: ["generation": "0"]).status == .badRequest)
      #expect(try await harness.get("/v1/session/\(id.rawValue)/lines", query: ["generation": "0", "after": "x"]).status == .badRequest)
      #expect(try await harness.get("/v1/session/\(id.rawValue)/lines/page", query: ["limit": "201"]).status == .badRequest)
      #expect(try await harness.get("/v1/session/\(id.rawValue)/lines/page", query: ["before": "x"]).status == .badRequest)
      #expect(try await harness.get("/v1/session/nobody-here-ever/lines").status == .notFound)
      #expect(try await harness.get("/v1/session/nobody-here-ever/lines/page").status == .notFound)

      let closed = try await SessionHarness(dev: false)
      let hidden = try await closed.store.createSession(group: .shared, title: "private", kind: .agent, createdBy: "owner", model: ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
      #expect(try await closed.get("/v1/session/\(hidden.rawValue)/lines").status == .unauthorized)
      #expect(try await closed.get("/v1/session/\(hidden.rawValue)/lines/page").status == .unauthorized)
    }
  }
}
