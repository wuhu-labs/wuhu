import Contract
import JSONValue

@Contract
public struct SecretsOutput: Codable, Equatable, Sendable {
  public let names: [String]
}

@Contract
public struct SecretSetInput: Codable, Equatable, Sendable {
  public let value: String
}
