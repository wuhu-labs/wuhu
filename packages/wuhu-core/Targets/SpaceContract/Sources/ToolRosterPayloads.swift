import Contract
import JSONValue

@Contract
public enum SessionToolExecutor: String, Codable, Equatable, Sendable, CaseIterable {
  case kernel
  case claudeCode = "claude-code"
}

@Contract
public struct ToolDescriptor: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let parameters: JSONValue
}

@Contract
public struct ToolRosterDescriptor: Codable, Equatable, Sendable {
  public let executor: SessionToolExecutor
  public let tools: [ToolDescriptor]
}

@Contract
public struct ToolRostersOutput: Codable, Equatable, Sendable {
  public let rosters: [ToolRosterDescriptor]
}
