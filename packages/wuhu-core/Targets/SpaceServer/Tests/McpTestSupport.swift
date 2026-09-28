import Fetch
import Foundation
import JSONValue
import Testing

func rpc(_ method: String, id: JSONValue = .integer(1), params: JSONValue? = nil) -> JSONValue {
  guard case var .object(fields) = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "method": .string(method)])
  else { preconditionFailure("literal object") }
  if let params { fields["params"] = params }
  return .object(fields)
}

func envelope(_ response: Response) async throws -> JSONValue {
  try #require(JSONValue.parse(try await response.text()))
}

func callResult(
  _ harness: SessionHarness,
  _ session: String,
  tool: String,
  _ arguments: JSONValue,
  toolUseID: String? = nil,
) async throws -> JSONValue {
  let meta: JSONValue = toolUseID.map { .object(["claudecode/toolUseId": .string($0)]) } ?? .object([:])
  let response = try await harness.post(
    "/v1/session/\(session)/mcp",
    rpc("tools/call", params: .object(["name": .string(tool), "arguments": arguments, "_meta": meta])),
  )
  #expect(response.status == .ok)
  guard case let .object(fields) = try await envelope(response) else { return .null }
  return fields["result"] ?? .null
}

func resultText(_ result: JSONValue) -> String? {
  guard case let .object(fields) = result, case let .array(blocks)? = fields["content"],
        case let .object(block)? = blocks.first, case let .string(text)? = block["text"]
  else { return nil }
  return text
}

func isToolError(_ result: JSONValue) -> Bool {
  guard case let .object(fields) = result else { return false }
  return fields["isError"] == .bool(true)
}

let mcpImagePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
let mcpImageModels = #"""
{
  "codex": {
    "dialect": "codex",
    "baseURL": "https://chatgpt.com/backend-api/codex",
    "models": {
      "gpt-5.6-sol": {"maxInput": 100000, "maxOutput": 10000, "efforts": ["high"], "defaultEffort": "high"}
    }
  }
}
"""#
