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

private func mcpToolNames(_ harness: SessionHarness, session: String) async throws -> [String] {
  let response = try await harness.post("/v1/session/\(session)/mcp", .object([
    "jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("tools/list"),
  ]))
  #expect(response.status == .ok)
  let envelope = try #require(JSONValue.parse(try await response.text()))
  let tools = try #require(envelope.object?["result"]?.object?["tools"]?.array)
  return tools.compactMap { $0.object?["name"]?.stringValue }
}

@Suite struct ToolRosterRouteTests {
  @Test func defaultListingCarriesBothRosters() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let output = try await sessionToolRosters(harness, executor: nil)
      #expect(output.rosters.map(\.executor) == [.kernel, .claudeCode])
    }
  }

  @Test func claudeCodeRosterIsExactlyWhatMcpServes() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let session = try await harness.createSession().rawValue
      let output = try await sessionToolRosters(harness, executor: .claudeCode)
      let listed = try #require(output.rosters.first)
      #expect(listed.tools.map(\.name) == (try await mcpToolNames(harness, session: session)))
    }
  }

  @Test func onlyTheKernelRosterCarriesKernelTools() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let kernel = try #require(try await sessionToolRosters(harness, executor: .kernel).rosters.first)
      let claudeCode = try #require(try await sessionToolRosters(harness, executor: .claudeCode).rosters.first)
      let extra = kernel.tools.map(\.name).filter { name in !claudeCode.tools.contains { $0.name == name } }
      #expect(extra == ["bookmark", "compact"])
    }
  }

  @Test func imageGenerationTakesAPromptAndARequiredDestination() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let roster = try #require(try await sessionToolRosters(harness, executor: .claudeCode).rosters.first)
      let tool = try #require(roster.tools.first { $0.name == "generate_image" })
      let parameters = try #require(tool.parameters.object)
      #expect(parameters["properties"]?.object?.keys.sorted() == ["destination", "prompt"])
      #expect(parameters["required"] == .array(["prompt", "destination"]))
      #expect(parameters["additionalProperties"] == false)
    }
  }

  @Test func theExecSchemaOffersEnvAndVaultSecrets() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let roster = try #require(try await sessionToolRosters(harness, executor: .claudeCode).rosters.first)
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
