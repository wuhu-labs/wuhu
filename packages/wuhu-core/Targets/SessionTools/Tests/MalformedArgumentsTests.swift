import DeterministicDependencies
import class MainHub.Hub
@testable import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing
import struct WuhuAI.ToolArguments

@Suite(.deterministicDependencies) struct MalformedArgumentsTests {
  @Test func truncatedArgumentsAreRefusedAsNotJSONAndNeverRun() async throws {
    try await withToolDeps { _ in
      let space = try Space.inMemory()
      let loop = try await ToolFixture(space: space)
      let session = try await makeSession(space, name: "Before")
      var world = ToolWorld(executor: try await loop.executor(owner: loop.hub { Hub(space: space) }), session: session)

      let message = try failureMessage(try await world.run("set_title", ToolArguments(emitted: #"{"title":"Nightly"#)))

      #expect(message == "set_title: the arguments are not valid JSON (one JSON object); send the call again with complete arguments")
      #expect(try await space.sessions.record(session).title == "Before")
    }
  }
}
