import Foundation
import JSONValue
import SessionDomain
@testable import SessionTools
import SpaceCore
import Testing

@Suite struct TitleToolTests {
  @Test func aSessionRenamesItself() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space, name: "I don't know")
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      guard case let .setTitle(result) = try await world.run(
        "set_title", .object(["title": "  Nightly release watch  "]),
      ) else {
        throw Mismatch("set_title failed")
      }
      #expect(result.title == "Nightly release watch", "the stored title is the trimmed one")
      #expect(try await space.sessions.record(session).title == "Nightly release watch")
    }
  }

  @Test func aTitleIsOneNonEmptyLineWithinTheCap() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let session = try await makeSession(space, name: "keep me")
      var world = ToolWorld(executor: ToolExecutor(space: space), session: session)

      for refused in ["", "   ", "two\nlines", String(repeating: "x", count: SessionStore.titleLimit + 1)] {
        let message = try failureMessage(try await world.run("set_title", .object(["title": .string(refused)])))
        #expect(message.contains("one non-empty line"))
      }
      #expect(try await space.sessions.record(session).title == "keep me", "a refused title changes nothing")

      guard case .setTitle = try await world.run(
        "set_title", .object(["title": .string(String(repeating: "x", count: SessionStore.titleLimit))]),
      ) else {
        throw Mismatch("the cap itself must be accepted")
      }
    }
  }
}
