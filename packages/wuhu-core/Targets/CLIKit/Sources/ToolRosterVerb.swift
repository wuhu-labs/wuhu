import JSONValue
import SpaceClient
import enum SpaceContract.SessionToolExecutor
import struct SpaceContract.ToolDescriptor
import struct SpaceContract.ToolRosterDescriptor
import struct SpaceContract.ToolRostersOutput

extension Executor {
  mutating func toolRoster(executor: SessionToolExecutor?, json: Bool) async throws {
    let space = try self.wallet.pinnedSpace()
    let output: ToolRostersOutput = try await self.authenticated(space).sessionTools(executor: executor)
    guard !json else {
      await self.runner.stdout(prettyJSON(try JSONValueEncoder().encode(output)) + "\n")
      return
    }
    await self.runner.stdout(output.rosters.map(rendered).joined(separator: "\n"))
  }
}

private func rendered(_ roster: ToolRosterDescriptor) -> String {
  var text = "\(roster.executor.rawValue) — \(roster.tools.count) tools\n"
  for tool in roster.tools {
    text += "\n  \(tool.name)  \(flattened(tool.description))\n"
    for parameter in parameters(of: tool) {
      text += "    \(parameter)\n"
    }
  }
  return text
}

private func parameters(of tool: ToolDescriptor) -> [String] {
  guard let properties = tool.parameters.object?["properties"]?.object else { return [] }
  let required = Set(tool.parameters.object?["required"]?.array?.compactMap(\.stringValue) ?? [])
  let width = properties.keys.map { $0.count + (required.contains($0) ? 1 : 0) }.max() ?? 0
  return properties.map { name, schema in
    let marked = required.contains(name) ? name + "*" : name
    let type = schema.object?["type"]?.stringValue ?? "any"
    let padding = String(repeating: " ", count: max(1, width + 1 - marked.count))
    let description = schema.object?["description"]?.stringValue.map { "  " + flattened($0) } ?? ""
    return "\(marked)\(padding)\(type)\(description)"
  }
}

private func flattened(_ text: String) -> String {
  text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: " ")
}
