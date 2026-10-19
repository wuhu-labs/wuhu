import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SpaceTools.MachineSeam

public struct ScriptMachineAccess: Sendable {
  public let files: MachineSeam
  public let exec: ExecBackend

  public init(files: MachineSeam, exec: ExecBackend) {
    self.files = files
    self.exec = exec
  }
}

public struct ScriptMachineSnapshot: Sendable {
  public let id: MachineID
  public let name: String?
  public let attached: Bool
}

public struct ScriptExecRequest: Sendable {
  public let machine: MachineID
  public let cwd: String
  public let command: String
  public let environment: ExecEnvironment
  public let window: Int
  public let maxOutput: Int?
  public let timeout: Double?
  public let acceptsStdin: Bool
  public let autoAcknowledge: Bool

  public init(machine: MachineID, cwd: String, command: String, environment: ExecEnvironment, window: Int, maxOutput: Int?, timeout: Double?, acceptsStdin: Bool, autoAcknowledge: Bool) {
    self.machine = machine; self.cwd = cwd; self.command = command; self.environment = environment
    self.window = window; self.maxOutput = maxOutput; self.timeout = timeout
    self.acceptsStdin = acceptsStdin; self.autoAcknowledge = autoAcknowledge
  }
}

public enum ScriptExecEvent: Sendable {
  case event(ExecEvent)
  case lost(String)
}

public struct ScriptExecStream: Sendable {
  public let id: ExecID
  public let events: AsyncThrowingStream<ScriptExecEvent, any Error>
}

public enum ScriptExecInput: Sendable {
  public enum Kill: Sendable { case caller, recorded }
  case write([UInt8])
  case closeStdin
  case acknowledge(through: Int)
  case kill(Kill)
  case release
}
