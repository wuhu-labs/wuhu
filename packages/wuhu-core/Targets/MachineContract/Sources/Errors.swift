import Contract
import JSONValue

@Contract
public enum MachineErrorCode: String, Codable, Equatable, Sendable {
  case machineLost
  case execNotFound
  case tokenInvalid
  case tokenRevoked
  case windowExceeded
  case protocolViolation
  case notFound
  case conflict
  case invalidArgument
  case io
  case tooLarge
}

@Contract
public struct MachineError: Codable, Equatable, Sendable {
  public let code: MachineErrorCode
  public let message: String
}
