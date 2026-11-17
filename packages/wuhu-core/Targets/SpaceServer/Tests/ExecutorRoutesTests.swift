import DeterministicDependencies
import Foundation
import JSONValue
import SessionDomain
import SpaceContract
import SpaceIDs
import struct SpaceIDs.SessionID
@_spi(Testing) import SpaceCore
import SystemFiles
import Testing

@Suite(.deterministicDependencies) struct ExecutorRoutesTests {
  @Test func createDefaultsToTheKernelExecutor() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let created = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "worker", "provider": "testing", "model": "test-model"]),
        as: SessionCreateOutput.self,
      )
      #expect(created.executor == "kernel")
      #expect(created.effort == "high")
      let record = try await harness.store.record(SessionID(created.id))
      #expect(record.executor == .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")))
    }
  }

  @Test func creationWantsAProviderAndAModel() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let providerless = try await harness.post("/v1/session", .object(["kind": "agent", "title": "t", "model": "test-model"]))
      #expect(providerless.status == .unprocessableContent)
      let modelless = try await harness.post("/v1/session", .object(["kind": "agent", "title": "t", "provider": "testing"]))
      #expect(modelless.status == .unprocessableContent)
    }
  }

  @Test func templatesDenormalizeAtCreationCloneTheirFilesAndExplicitParamsWin() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let manifest = """
      {"kind":"agent","description":"night shift","provider":"testing",
       "model":"test-model","effort":"low","tags":["night"]}
      """
      let fs = await harness.space.fs(.shared)
      _ = try await fs.write("/templates/night/template.json", Data(manifest.utf8), ifMatch: nil)
      _ = try await fs.write("/templates/night/AGENTS.md", Data("night rules".utf8), ifMatch: nil)
      _ = try await fs.write("/templates/night/.agents/skills/watch/SKILL.md", Data("# Watch\nKeep watch\n".utf8), ifMatch: nil)

      let created = try await harness.call(
        "/v1/session",
        .object(["title": "shift", "template": "night", "effort": "high"]),
        as: SessionCreateOutput.self,
      )
      #expect(created.executor == "kernel")
      #expect(created.kind == .agent, "kind comes from the template when the request leaves it out")
      let record = try await harness.store.record(SessionID(created.id))
      #expect(record.tags == ["night"])
      #expect(record.executor == .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")))
      let home = "/_/sessions/\(created.id)"
      #expect(String(decoding: try await fs.read("\(home)/AGENTS.md").1, as: UTF8.self) == "night rules")
      #expect(String(decoding: try await fs.read("\(home)/.agents/skills/watch/SKILL.md").1, as: UTF8.self) == "# Watch\nKeep watch\n")
      await #expect(throws: SpaceError.notFound("\(home)/template.json")) {
        _ = try await fs.read("\(home)/template.json")
      }

      let rewritten = #"{"provider":"testing","model":"test-model","effort":"low"}"#
      _ = try await fs.write("/templates/night/template.json", Data(rewritten.utf8), ifMatch: nil)
      #expect(try await harness.store.record(SessionID(created.id)).executor == record.executor)

      let fromTemplate = try await harness.call(
        "/v1/session",
        .object(["kind": "agent", "title": "day", "template": "night"]),
        as: SessionCreateOutput.self,
      )
      #expect(fromTemplate.effort == "low")
      #expect(fromTemplate.kind == .agent)

      let kindless = try await harness.post("/v1/session", .object(["title": "t", "provider": "testing", "model": "test-model"]))
      #expect(kindless.status == .badRequest)
      let missing = try await harness.post("/v1/session", .object(["kind": "agent", "title": "t", "template": "nope"]))
      #expect(missing.status == .unprocessableContent)

      let dawn = #"{"description":"dawn shift","provider":"testing","model":"test-model","effort":"low"}"#
      _ = try await fs.write("/templates/dawn/template.json", Data(dawn.utf8), ifMatch: nil)

      let listed = try await harness.get("/v1/templates")
      let body = try JSONValueDecoder().decode(SessionTemplatesOutput.self, from: try #require(JSONValue.parse(try await listed.text())))
      #expect(body.templates.sorted { $0.name < $1.name } == [
        .init(name: "dawn", kind: nil, provider: "testing", model: "test-model", effort: "low", description: "dawn shift"),
        .init(name: "night", kind: nil, provider: "testing", model: "test-model", effort: "low", description: nil),
      ])
    }
  }

  @Test func aTemplateCloneThatFailsAfterCreationNamesTheSessionItLeftBehind() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let fs = await harness.space.fs(.shared)
      _ = try await fs.write("/templates/night/template.json", Data(#"{"kind":"agent","provider":"testing","model":"test-model"}"#.utf8), ifMatch: nil)
      _ = try await fs.write("/templates/night/AGENTS.md", Data("night rules".utf8), ifMatch: nil)
      await harness.space.failTemplateClones("the disk is full")

      let response = try await harness.post("/v1/session", .object(["title": "shift", "template": "night"]))
      #expect(response.status == .internalServerError)
      let body = try #require(JSONValue.parse(try await response.text()))
      guard case let .object(fields) = body, case let .string(id)? = fields["hint"] else {
        Issue.record("no session id in the hint: \(body)")
        return
      }
      #expect(fields["code"] == .string("incompleteSession"))
      #expect(fields["message"] == .string("session \(id) was created, but cloning template night into its home failed: the disk is full"))
      #expect(try await harness.store.record(SessionID(id)).title == "shift")
      await #expect(throws: SpaceError.notFound("/_/sessions/\(id)/AGENTS.md")) {
        _ = try await fs.read("/_/sessions/\(id)/AGENTS.md")
      }
    }
  }
}
