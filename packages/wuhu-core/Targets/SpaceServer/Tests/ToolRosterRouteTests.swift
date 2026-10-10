import Fetch
import Foundation
import JSONValue
import SpaceContract
import SpaceServer
import Testing

func sessionToolRosters(_ harness: SessionHarness, executor: SessionToolExecutor?) async throws -> ToolRostersOutput {
  let response = try await harness.get(
    "/v1/session-tools",
    query: executor.map { ["executor": $0.rawValue] } ?? [:],
  )
  #expect(response.status == .ok)
  let text = try await response.text()
  return try JSONValueDecoder().decode(ToolRostersOutput.self, from: try #require(JSONValue.parse(text)))
}

@Suite struct ToolRosterRouteTests {
  @Test func defaultListingCarriesOnlyKernel() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let output = try await sessionToolRosters(harness, executor: nil)
      #expect(output.rosters.map(\.executor) == [.kernel])
    }
  }

  @Test func imageGenerationTakesAPromptAndARequiredDestination() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let roster = try #require(try await sessionToolRosters(harness, executor: .kernel).rosters.first)
      let tool = try #require(roster.tools.first { $0.name == "generate_image" })
      let parameters = try #require(tool.parameters.object)
      #expect(parameters["properties"]?.object?.keys.sorted() == ["destination", "model", "prompt", "provider", "quality", "size"])
      #expect(parameters["required"] == .array(["prompt", "destination"]))
      #expect(parameters["additionalProperties"] == false)
    }
  }

  @Test func theExecSchemaOffersEnvAndGroupSecrets() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let roster = try #require(try await sessionToolRosters(harness, executor: .kernel).rosters.first)
      let exec = try #require(roster.tools.first { $0.name == "exec" })
      let properties = try #require(exec.parameters.object?["properties"]?.object)
      let stringMap = JSONValue.object(["type": .string("string")])
      for field in ["env", "secrets"] {
        let declared = try #require(properties[field]?.object)
        #expect(declared["type"] == .string("object"))
        #expect(declared["additionalProperties"] == stringMap)
      }
    }
  }

  @Test func anUnknownExecutorIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let response = try await harness.get("/v1/session-tools", query: ["executor": "daemon"])
      #expect(response.status == .badRequest)
    }
  }
}
