import Fetch
import Foundation
import JSONValue
import SpaceContract
@testable import SpaceServer
import Testing

@Suite struct ApiOriginTests {
  @Test func everyToolIsFaithfulToDirectRun() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/notes/a.md", "content": "foo\nbar [b](/b.md)"]))
    _ = try await harness.direct("write", .object(["path": "/b.md", "content": "target"]))
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/data/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )
    _ = try await harness.direct(
      "table.mutate",
      .object(["path": "/data/t.table", "ops": .array([.object(["kind": "insert", "values": .array([.integer(7)])])])]),
    )

    let probes: [(String, JSONValue)] = [
      ("read", .object(["path": "/notes/a.md"])),
      ("ls", .object(["path": "/"])),
      ("stat", .object(["path": "/notes/a.md"])),
      ("grep", .object(["pattern": "foo"])),
      ("find", .object(["glob": "**/*.md"])),
      ("history", .object(["path": "/notes/a.md"])),
      ("query", .object(["sql": "SELECT n FROM \"/data/t.table\""])),
    ]
    for (name, input) in probes {
      let response = try await harness.post(name, input)
      #expect(response.status == .ok, "\(name)")
      let viaHTTP = try await json(response)
      let viaTool = try await harness.direct(name, input)
      #expect(viaHTTP == viaTool, "\(name)")
    }
  }

  @Test func mutatingToolsWorkOverHTTP() async throws {
    let harness = try Harness()
    let written = try await harness.call(
      "write", .object(["path": "/a.md", "content": "v1\n[b](/b.md)"]), as: WriteOutput.self,
    )
    _ = try await harness.call("write", .object(["path": "/b.md", "content": "x"]), as: WriteOutput.self)

    let edited = try await harness.call(
      "edit", .object(["path": "/a.md", "edits": .array([.object(["old": "v1", "new": "v2"])])]), as: EditOutput.self,
    )
    #expect(edited.rev! > written.rev!)

    let synced = try await harness.call(
      "sync",
      .object(["path": "/a.md", "baseToken": .string(written.token), "content": "v1\n[B](/b.md)"]),
      as: SyncOutput.self,
    )
    guard case let .merged(_, _, content) = synced else {
      Issue.record("expected merged, got \(synced)")
      return
    }
    #expect(content == "v2\n[B](/b.md)")

    let moved = try await harness.call("mv", .object(["from": "/b.md", "to": "/c.md"]), as: MoveOutput.self)
    #expect(moved.dangling == ["/a.md"])

    let restored = try await harness.call(
      "checkout", .object(["path": "/a.md", "rev": .integer(written.rev!)]), as: CheckoutOutput.self,
    )
    #expect(restored.rev > edited.rev!)

    let read = try await harness.call("read", .object(["path": "/a.md"]), as: ReadOutput.self)
    #expect(read.content == "v1\n[b](/b.md)")

    _ = try await harness.call("rm", .object(["path": "/c.md"]), as: RevisionOutput.self)
    let gone = try await harness.post("read", .object(["path": "/c.md"]))
    #expect(gone.status.code == 422)

    _ = try await harness.call(
      "write", .object(["path": "/templates/j.md", "content": "---\ntemplate:\n  strategy: incr\n  prefix: J\n---\nhi"]),
      as: WriteOutput.self,
    )
    let instantiated = try await harness.call(
      "new", .object(["template": "/templates/j.md", "in": "/journal"]), as: NewOutput.self,
    )
    #expect(instantiated.path == "/journal/J-1.md")
  }

  @Test func tableToolsRouteThroughDottedNames() async throws {
    let harness = try Harness()
    let created = try await harness.call(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([
        .object(["name": "j", "type": "json"]),
        .object(["name": "b", "type": "boolean"]),
      ])])]),
      as: RevisionOutput.self,
    )
    #expect(created.rev > 0)

    _ = try await harness.call(
      "table.alter",
      .object(["path": "/t.table", "header": .object(["columns": .array([
        .object(["name": "j", "type": "json"]),
        .object(["name": "b", "type": "boolean"]),
        .object(["name": "s", "type": "string"]),
      ])])]),
      as: RevisionOutput.self,
    )
    _ = try await harness.call(
      "table.mutate",
      .object(["path": "/t.table", "ops": .array([.object([
        "kind": "insert", "values": .array([.object(["k": .integer(1)]), .bool(true), .string("x")]),
      ])])]),
      as: RevisionOutput.self,
    )

    let rows = try await harness.call(
      "query", .object(["sql": "SELECT j, b, s FROM \"/t.table\""]), as: QueryOutput.self,
    )
    #expect(rows.rows == [[.object(["k": .integer(1)]), .bool(true), .string("x")]])
  }

  // Clients build `<group>.<contentBase>`.
  @Test func serverInfoReportsTheContentBase() async throws {
    for (origin, base) in [
      ("https://wuhu.example:5530", "wuhu.example:5530"), ("https://Wuhu.Example", "wuhu.example"),
      ("https://localhost:5530", "localhost:5530"),
    ] {
      let harness = try Harness(origin: origin)
      let response = try await harness.get(harness.api, "/v1/server")
      #expect(response.status == .ok)
      let info = try await json(response).object
      #expect(info?["contentBase"] == .string(base))
      #expect(info?["contentHost"] == nil)
    }
  }

  @Test func theDefaultContentHostIsLocalhost() throws {
    let host = try #require(ContentHost(origin: "https://localhost:5530"))
    #expect(host.base == "localhost:5530")
    #expect(host.plane(of: "shared.localhost") == .content(.shared))
    #expect(host.plane(of: "localhost") == .api)
    #expect(host.plane(of: "127.0.0.1") == .api)
  }

  @Test func serverInfoAdvertisesTheSpaceIdentityAndOrigin() async throws {
    let harness = try Harness(origin: "https://api.wuhu.example:5530")
    let response = try await harness.get(harness.api, "/v1/server")
    #expect(response.status == .ok)
    let info = try JSONValueDecoder().decode(ServerInfo.self, from: try await json(response))
    #expect(info.space == (try await harness.space.identity().rawValue))
    #expect(info.origin == "https://api.wuhu.example:5530")

    let bare = try Harness()
    let none = try JSONValueDecoder().decode(ServerInfo.self, from: try await json(try await bare.get(bare.api, "/v1/server")))
    #expect(none.space == (try await bare.space.identity().rawValue))
    #expect(none.origin == nil)
  }

  @Test func serverInfoStaysPublicBehindTheWall() async throws {
    let harness = try Harness(dev: false, origin: "https://api.wuhu.example:5530")
    let response = try await harness.get(harness.api, "/v1/server")
    #expect(response.status == .ok)
    let info = try JSONValueDecoder().decode(ServerInfo.self, from: try await json(response))
    #expect(info.space == (try await harness.space.identity().rawValue))
    #expect(info.origin == "https://api.wuhu.example:5530")
  }

  @Test func unknownToolIs404() async throws {
    let harness = try Harness()
    let response = try await harness.post("nope", .object([:]))
    #expect(response.status == .notFound)
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
    #expect(error.code == .notFound)
  }

  @Test func undecodableBodiesAre400() async throws {
    let harness = try Harness()
    let notJSON = try await harness.api(Request(
      url: URL(string: "http://space/v1/tools/read")!,
      method: .post,
      body: .string("not json"),
    ))
    #expect(notJSON.status == .badRequest)

    let wrongShape = try await harness.post("read", .object(["nope": true]))
    #expect(wrongShape.status == .badRequest)
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(wrongShape))
    #expect(error.code == .invalidArgument)
  }

  @Test func domainFailuresAre422WithToolErrorPayload() async throws {
    let harness = try Harness()
    let response = try await harness.post("read", .object(["path": "/missing.md"]))
    #expect(response.status.code == 422)
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
    #expect(error.code == .notFound)

    let first = try await harness.call("write", .object(["path": "/a.md", "content": "v1"]), as: WriteOutput.self)
    _ = try await harness.call("write", .object(["path": "/a.md", "content": "v2"]), as: WriteOutput.self)
    let stale = try await harness.post(
      "write", .object(["path": "/a.md", "content": "v3", "ifMatch": .string(first.token)]),
    )
    #expect(stale.status.code == 422)
    let conflict = try JSONValueDecoder().decode(ToolError.self, from: try await json(stale))
    #expect(conflict.code == .conflict)
    #expect(conflict.hint != nil)
  }

  @Test func unknownRoutesAre404AndMethodsGated() async throws {
    let harness = try Harness()
    let missing = try await harness.get(harness.api, "/nope")
    #expect(missing.status == .notFound)
    let wrongMethod = try await harness.get(harness.api, "/v1/tools/read")
    #expect(wrongMethod.status == .methodNotAllowed)
  }

  @Test func nonDevServerRejectsEverything() async throws {
    let harness = try Harness(dev: false)
    let response = try await harness.post("read", .object(["path": "/a.md"]))
    #expect(response.status == .unauthorized)
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
    #expect(error.code == .unauthorized)
  }
}
