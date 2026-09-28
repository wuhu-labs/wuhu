import Fetch
import FetchSSE
import Foundation
import HTTPTypes
import JSONValue
import SpaceContract
import Testing

@Suite struct ObserveTests {
  @Test func globObserveStreamsMutationEvents() async throws {
    let harness = try Harness()
    let response = try await harness.get(harness.api, "/v1/observe", query: ["glob": "/notes/**"])
    #expect(response.status == .ok)
    #expect(response.headers[.contentType]?.hasPrefix("text/event-stream") == true)

    _ = try await harness.direct("write", .object(["path": "/notes/a.md", "content": "x"]))
    _ = try await harness.direct("write", .object(["path": "/elsewhere.md", "content": "x"]))
    _ = try await harness.direct("mv", .object(["from": "/notes/a.md", "to": "/notes/b.md"]))

    var events: [MutationEvent] = []
    for try await frame in response.sse() {
      events.append(try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data))))
      if events.count == 2 { break }
    }
    #expect(events == [.write(path: "/notes/a.md", rev: 1, entry: .file), .move(path: "/notes/a.md", to: "/notes/b.md", rev: 3, entry: .file)])
  }

  @Test func globObserveWithCursorReplaysJournalThenStreamsLive() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/notes/a.md", "content": "x"]))
    _ = try await harness.direct("write", .object(["path": "/notes/b.md", "content": "y"]))

    let response = try await harness.get(harness.api, "/v1/observe", query: ["glob": "/notes/**", "from": "1"])
    #expect(response.status == .ok)

    var events: [MutationEvent] = []
    for try await frame in response.sse() {
      events.append(try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data))))
      if events.count == 1 {
        _ = try await harness.direct("write", .object(["path": "/notes/c.md", "content": "z"]))
      }
      if events.count == 2 { break }
    }
    #expect(events == [.write(path: "/notes/b.md", rev: 2, entry: .file), .write(path: "/notes/c.md", rev: 3, entry: .file)])
  }

  @Test func underscoreObserveAcceptsCursorToo() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/a.md", "content": "x"]))

    let response = try await harness.get(harness.web, "/_/observe", query: ["glob": "/**", "from": "0"])
    #expect(response.status == .ok)
    for try await frame in response.sse() {
      let event = try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data)))
      #expect(event == .write(path: "/a.md", rev: 1, entry: .file))
      break
    }
  }

  @Test func globObserveRejectsMalformedCursorOnBothOrigins() async throws {
    let harness = try Harness()
    for (path, client) in [("/v1/observe", harness.api), ("/_/observe", harness.web)] {
      for from in ["x", "-1", ""] {
        let response = try await harness.get(client, path, query: ["glob": "/**", "from": from])
        #expect(response.status == .badRequest, "\(path) from=\(from)")
        let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
        #expect(error.code == .invalidArgument, "\(path) from=\(from)")
      }
    }
  }

  @Test func sqlObserveStreamsQueryOutputSnapshots() async throws {
    let harness = try Harness()
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )

    let response = try await harness.get(
      harness.api, "/v1/observe", query: ["sql": "SELECT n FROM \"/t.table\" ORDER BY id", "throttleMs": "0"],
    )
    #expect(response.status == .ok)
    #expect(response.headers[.contentType]?.hasPrefix("text/event-stream") == true)

    var snapshots: [QueryOutput] = []
    var mutated = false
    for try await frame in response.sse() {
      snapshots.append(try JSONValueDecoder().decode(QueryOutput.self, from: #require(JSONValue.parse(frame.data))))
      if !mutated {
        mutated = true
        _ = try await harness.direct(
          "table.mutate",
          .object(["path": "/t.table", "ops": .array([.object(["kind": "insert", "values": .array([.integer(1)])])])]),
        )
      }
      if snapshots.count == 2 { break }
    }
    #expect(snapshots[0].rows == [])
    #expect(snapshots[1].rows == [[.integer(1)]])
  }

  // `viewer()` is the identity a watermark POST from the same caller advances;
  // the web origin has no caller identity and reads NULL.
  @Test func sqlObserveBindsTheCallerAsViewer() async throws {
    let harness = try Harness()
    let origins: [(FetchClient, String, JSONValue)] = [(harness.api, "/v1/observe", "owner"), (harness.web, "/_/observe", .null)]
    for (client, path, expected) in origins {
      let response = try await harness.get(client, path, query: ["sql": "SELECT viewer() AS v", "throttleMs": "0"])
      #expect(response.status == .ok, "\(path)")
      for try await frame in response.sse() {
        let output = try JSONValueDecoder().decode(QueryOutput.self, from: #require(JSONValue.parse(frame.data)))
        #expect(output.rows == [[expected]], "\(path)")
        break
      }
    }
  }

  @Test func aDeviceKeyReadsItsAdoptedPersonaAsViewer() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (bearer, key) = try await harness.enrolledBearer()
      for _ in 0 ..< 2 {
        let response = try await harness.get(
          "/v1/observe", query: ["sql": "SELECT viewer() AS v", "throttleMs": "0"], bearer: bearer,
        )
        #expect(response.status == .ok)
        let persona = try #require(try await harness.space.persona(account: key.account))
        for try await frame in response.sse() {
          let output = try JSONValueDecoder().decode(QueryOutput.self, from: #require(JSONValue.parse(frame.data)))
          #expect(output.rows == [[.string(persona.name)]])
          break
        }
      }
    }
  }

  @Test func aCallerWithoutAPersonaCannotObserveViewer() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness(dev: false)
      let (bearer, _) = try await harness.enrolledBearer(capabilities: [.contractor])
      let refused = try await harness.get(
        "/v1/observe", query: ["sql": "SELECT viewer() AS v", "throttleMs": "0"], bearer: bearer,
      )
      #expect(refused.status == .forbidden)
      let plain = try await harness.get("/v1/observe", query: ["sql": "SELECT 1 AS v", "throttleMs": "0"], bearer: bearer)
      #expect(plain.status == .ok)
    }
  }

  @Test func underscoreObserveMatchesApiOriginShapes() async throws {
    let harness = try Harness()
    let response = try await harness.get(harness.web, "/_/observe", query: ["glob": "/**"])
    #expect(response.status == .ok)
    #expect(response.headers[.contentType]?.hasPrefix("text/event-stream") == true)

    _ = try await harness.direct("write", .object(["path": "/a.md", "content": "x"]))
    for try await frame in response.sse() {
      let event = try JSONValueDecoder().decode(MutationEvent.self, from: #require(JSONValue.parse(frame.data)))
      #expect(event == .write(path: "/a.md", rev: 1, entry: .file))
      break
    }
  }

  @Test func observeWithoutModeIs400() async throws {
    let harness = try Harness()
    let neither = try await harness.get(harness.api, "/v1/observe")
    #expect(neither.status == .badRequest)
    let both = try await harness.get(harness.api, "/v1/observe", query: ["glob": "/**", "sql": "SELECT 1"])
    #expect(both.status == .badRequest)
    let badThrottle = try await harness.get(harness.api, "/v1/observe", query: ["sql": "SELECT 1", "throttleMs": "x"])
    #expect(badThrottle.status == .badRequest)
  }

  @Test func observeRejectsEmptyGlobOnBothOrigins() async throws {
    let harness = try Harness()
    for (path, client) in [("/v1/observe", harness.api), ("/_/observe", harness.web)] {
      let response = try await harness.get(client, path, query: ["glob": ""])
      #expect(response.status == .badRequest, "\(path)")
      let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
      #expect(error.code == .invalidArgument, "\(path)")
    }
  }

  @Test func observeRejectsInvalidSQLBeforeStreamingOnBothOrigins() async throws {
    let harness = try Harness()
    let cases: [(sql: String, code: ErrorCode)] = [
      ("DELETE FROM docs", .invalidArgument),
      ("SELECT * FROM fs_heads", .invalidArgument),
      ("SELECT * FROM nope", .notFound),
      ("not sql at all", .invalidArgument),
    ]
    for (path, client) in [("/v1/observe", harness.api), ("/_/observe", harness.web)] {
      for (sql, code) in cases {
        let response = try await harness.get(client, path, query: ["sql": sql])
        #expect(response.status.code == 422, "\(path) \(sql)")
        #expect(response.headers[.contentType] == "application/json", "\(path) \(sql)")
        let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
        #expect(error.code == code, "\(path) \(sql)")
      }
    }
  }

  @Test func sqlObserveRehydratesJsonAndBooleanColumns() async throws {
    let harness = try Harness()
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([
        .object(["name": "j", "type": "json"]),
        .object(["name": "b", "type": "boolean"]),
      ])])]),
    )
    _ = try await harness.direct(
      "table.mutate",
      .object(["path": "/t.table", "ops": .array([.object([
        "kind": "insert", "values": .array([.array([.integer(1), .string("x")]), .bool(true)]),
      ])])]),
    )

    let response = try await harness.get(
      harness.api, "/v1/observe", query: ["sql": "SELECT j, b FROM \"/t.table\" ORDER BY id"],
    )
    #expect(response.status == .ok)
    for try await frame in response.sse() {
      let snapshot = try JSONValueDecoder().decode(QueryOutput.self, from: #require(JSONValue.parse(frame.data)))
      #expect(snapshot.rows == [[.array([.integer(1), .string("x")]), .bool(true)]])
      break
    }
  }
}
