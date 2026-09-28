import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct TemplateToolTests {
  @Test func anEmptySpaceSaysSoRatherThanListingNothing() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .templates(result) = try await world.run("templates", .object([:])) else {
        throw Mismatch("templates failed")
      }
      #expect(result.templates.isEmpty)
      #expect(result.rendered.contains("no session templates"))
    }
  }

  @Test func templatesCarryTheSpecCreateSessionWouldInherit() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      _ = try await space.fs(.shared).write(
        "/templates/triage/template.json",
        Data(#"{"kind":"task","provider":"test","model":"test-model","effort":"high","description":"Triage the inbox."}"#.utf8),
        ifMatch: nil,
      )
      _ = try await space.fs(.shared).write(
        "/templates/scribe/template.json",
        Data(#"{"kind":"agent"}"#.utf8),
        ifMatch: nil,
      )
      var world = ToolWorld(executor: ToolExecutor(space: space), session: try await makeSession(space))

      guard case let .templates(result) = try await world.run("templates", .object([:])) else {
        throw Mismatch("templates failed")
      }
      #expect(result.templates.map(\.name).sorted() == ["scribe", "triage"])
      let triage = try #require(result.templates.first { $0.name == "triage" })
      #expect(triage.kind == "task")
      #expect(triage.provider == "test")
      #expect(triage.model == "test-model")
      #expect(triage.effort == "high")
      #expect(triage.description == "Triage the inbox.")

      let scribe = try #require(result.templates.first { $0.name == "scribe" })
      #expect(scribe.provider == nil)
      #expect(scribe.model == nil)

      #expect(result.rendered.contains("- triage [task test test-model high] — Triage the inbox."))
    }
  }
}
