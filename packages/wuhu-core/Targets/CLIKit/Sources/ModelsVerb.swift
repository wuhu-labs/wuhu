#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import SpaceClient
import struct SpaceContract.ReadOutput
import struct SpaceContract.WriteOutput

// The published basis for `wuhu models update`. wuhu.ai/resources/
// well-known-models.json does not exist yet; until it does, the verb syncs
// against this repo-hosted seed. Model ids verified live 2026-07-06 against
// each provider's models endpoint; context limits are seed estimates the user
// is free to edit — user edits always win on sync.
enum WellKnownModels {
  static let spacePath = "/models.json"

  static let seed = """
  {
    "anthropic": {
      "dialect": "anthropic",
      "baseURL": "https://api.anthropic.com",
      "models": {
        "claude-sonnet-5": {
          "maxInput": 200000,
          "maxOutput": 64000,
          "efforts": ["low", "medium", "high", "max"],
          "defaultEffort": "high"
        }
      }
    },
    "claude": {
      "dialect": "claude",
      "baseURL": "https://api.anthropic.com/v1",
      "models": {
        "claude-sonnet-5": {
          "maxInput": 1000000,
          "maxOutput": 64000,
          "efforts": ["low", "medium", "high", "max"],
          "defaultEffort": "high"
        }
      }
    },
    "openai": {
      "dialect": "responses",
      "baseURL": "https://api.openai.com/v1",
      "models": {
        "gpt-5.4": {
          "maxInput": 400000,
          "maxOutput": 128000,
          "efforts": ["none", "low", "medium", "high", "xhigh"],
          "defaultEffort": "medium"
        },
        "gpt-5.6-luna": {
          "maxInput": 1050000,
          "maxOutput": 128000,
          "efforts": ["low", "medium", "high", "xhigh"],
          "defaultEffort": "low"
        }
      }
    },
    "codex": {
      "dialect": "codex",
      "baseURL": "https://chatgpt.com/backend-api/codex",
      "originator": "wuhu",
      "models": {
        "gpt-5.6-terra": {
          "maxInput": 272000,
          "maxOutput": 128000,
          "efforts": ["low", "medium", "high", "xhigh", "max"],
          "defaultEffort": "medium"
        },
        "gpt-5.6-sol": {
          "maxInput": 272000,
          "maxOutput": 128000,
          "efforts": ["low", "medium", "high", "xhigh", "max"],
          "defaultEffort": "low"
        }
      }
    },
    "deepseek": {
      "dialect": "anthropic",
      "baseURL": "https://api.deepseek.com/anthropic",
      "models": {
        "deepseek-v4-pro": {
          "maxInput": 131072,
          "maxOutput": 32768,
          "efforts": ["low", "medium", "high"],
          "defaultEffort": "high"
        },
        "deepseek-v4-flash": {
          "maxInput": 131072,
          "maxOutput": 32768,
          "efforts": ["low", "medium", "high"],
          "defaultEffort": "medium"
        }
      }
    }
  }
  """
}

struct ModelsMerge {
  var merged: JSONValue
  var added: [String]

  // Additive sync: basis providers/models missing from the user's copy are
  // added; every key the user already has keeps the user's value.
  init(basis: JSONValue, user: JSONValue?) {
    var result = user?.object ?? [:]
    var added: [String] = []
    for (providerID, basisProvider) in basis.object ?? [:] {
      guard var userProvider = result[providerID]?.object else {
        result[providerID] = basisProvider
        added.append("provider \(providerID)")
        continue
      }
      var userModels = userProvider["models"]?.object ?? [:]
      for (modelName, basisModel) in basisProvider.object?["models"]?.object ?? [:] {
        guard userModels[modelName] == nil else { continue }
        userModels[modelName] = basisModel
        added.append("model \(providerID)/\(modelName)")
      }
      userProvider["models"] = .object(userModels)
      result[providerID] = .object(userProvider)
    }
    merged = .object(result)
    self.added = added
  }
}

func prettyJSON(_ value: JSONValue, indent: Int = 0) -> String {
  let pad = String(repeating: "  ", count: indent)
  let innerPad = String(repeating: "  ", count: indent + 1)
  switch value {
  case let .object(object):
    guard !object.isEmpty else { return "{}" }
    let entries = object.map { key, value in
      "\(innerPad)\(JSONValue.string(key).jsonString()): \(prettyJSON(value, indent: indent + 1))"
    }
    return "{\n" + entries.joined(separator: ",\n") + "\n\(pad)}"
  case let .array(array):
    guard !array.isEmpty else { return "[]" }
    let scalars = array.allSatisfy { if case .object = $0 { false } else if case .array = $0 { false } else { true } }
    if scalars {
      return "[" + array.map { $0.jsonString() }.joined(separator: ", ") + "]"
    }
    let entries = array.map { "\(innerPad)\(prettyJSON($0, indent: indent + 1))" }
    return "[\n" + entries.joined(separator: ",\n") + "\n\(pad)]"
  default:
    return value.jsonString()
  }
}

extension Executor {
  mutating func modelsUpdate() async throws {
    let space = try self.wallet.pinnedSpace()
    guard let basis = JSONValue.parse(WellKnownModels.seed) else {
      preconditionFailure("embedded well-known models seed is not valid JSON")
    }

    var user: JSONValue?
    var token: String?
    do {
      let output: ReadOutput = try await self.authenticated(space).tool(
        "read", ["path": .string(WellKnownModels.spacePath)],
      )
      token = output.token
      guard let existing = JSONValue.parse(output.content) else {
        throw CLIError(message: "\(WellKnownModels.spacePath) is not valid JSON; fix or remove it, then re-run")
      }
      user = existing
    } catch let error as SpaceClient.ToolFailure where error.error.code == .notFound {}

    let merge = ModelsMerge(basis: basis, user: user)
    guard !merge.added.isEmpty else {
      await self.runner.stdout("models: up to date\n")
      return
    }

    var input: JSONValue = [
      "path": .string(WellKnownModels.spacePath),
      "content": .string(prettyJSON(merge.merged) + "\n"),
    ]
    input.set("ifMatch", token.map(JSONValue.string))
    let output: WriteOutput = try await self.authenticated(space).tool("write", input)
    try self.wallet.record(token: output.token, space: space, path: WellKnownModels.spacePath)

    var report = merge.added.map { "added \($0)\n" }.joined()
    report += output.rev.map { "rev \($0)\n" } ?? ""
    await self.runner.stdout(report)
  }
}
