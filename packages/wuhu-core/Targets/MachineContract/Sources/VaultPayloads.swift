import Contract
import JSONValue

@Contract
public struct VaultSet: Codable, Equatable, Sendable {
  public let id: Int
  public let name: String
  public let value: String
}

@Contract
public struct VaultRemove: Codable, Equatable, Sendable {
  public let id: Int
  public let name: String
}

@Contract
public struct VaultList: Codable, Equatable, Sendable {
  public let id: Int
}

@Contract
public enum VaultOutcome: Codable, Equatable, Sendable {
  case ok(id: Int)
  case names(id: Int, names: [String])
  case error(id: Int, error: MachineError)
}
