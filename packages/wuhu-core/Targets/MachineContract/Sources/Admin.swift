import Contract
import JSONValue

@Contract
public struct MachineAddInput: Codable, Equatable, Sendable {
  public let name: String?
}

@Contract
public struct MachineAddOutput: Codable, Equatable, Sendable {
  public let id: MachineID
  public let token: String
  public let fingerprint: String?
}

@Contract
public struct MachineNameInput: Codable, Equatable, Sendable {
  public let name: String
}

@Contract
public struct MachineMoveInput: Codable, Equatable, Sendable {
  public let group: String
}

@Contract
public struct MachineRotateInput: Codable, Equatable, Sendable {
  public let id: MachineID
}

@Contract
public struct MachineRotateOutput: Codable, Equatable, Sendable {
  public let token: String
  public let fingerprint: String?
}

@Contract
public struct MachineRevokeInput: Codable, Equatable, Sendable {
  public let id: MachineID
}

@Contract
public struct MachineStatus: Codable, Equatable, Sendable {
  public let id: MachineID
  public let name: String?
  public let attached: Bool
}

@Contract
public struct ExecMintInput: Codable, Equatable, Sendable {
  public let machine: MachineID
}

@Contract
public struct ExecMintOutput: Codable, Equatable, Sendable {
  public let id: ExecID
}

@Contract
public enum ExecState: Codable, Equatable, Sendable {
  case live
  case exited(code: Int)
  case signaled(signal: Int)
  case cancelled
  case reaped
  case machineLost
}

@Contract
public struct ExecStatus: Codable, Equatable, Sendable {
  public let id: ExecID
  public let machine: MachineID
  public let command: String
  public let startedAt: Double
  public let state: ExecState
}
