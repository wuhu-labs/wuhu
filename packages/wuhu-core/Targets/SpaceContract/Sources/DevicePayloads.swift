import Contract
import JSONValue

@Contract
public struct DeviceRegisterInput: Codable, Equatable, Sendable {
  public let installation: String
  public let kind: String
  public let name: String
}

@Contract
public struct DeviceAnnotateInput: Codable, Equatable, Sendable {
  public let name: String?
  public let machine: String?
}

@Contract
public struct DevicePayload: Codable, Equatable, Sendable {
  public let id: String
  public let account: String
  public let kind: String
  public let name: String
  public let machine: String?
  public let createdAt: Double
  public let lastSeenAt: Double
}

@Contract
public struct DevicesOutput: Codable, Equatable, Sendable {
  public let devices: [DevicePayload]
}

@Contract
public struct DeviceCommandInput: Codable, Equatable, Sendable {
  public let payload: JSONValue
}

@Contract
public struct DeviceCommandOutput: Codable, Equatable, Sendable {
  public let n: Int
}
