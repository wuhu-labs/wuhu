import CExecSupervisor
import struct OperationProtocol.OperationError

extension ExecSupervisor {
  /// Starts `arguments` the way supervisors start: its own process group, standard descriptors on /dev/null and nothing else inherited, so it outlives the agent's service restart. The caller reaps it.
  public static func launchDetached(_ arguments: [String]) throws -> Int32 {
    guard let executable = arguments.first, executable.hasPrefix("/") else { throw OperationError(.invalidConfiguration) }
    var pid: Int32 = 0
    let code = withCStringArray(arguments) { exec_launch_detached($0, &pid) }
    guard code == 0 else { throw OperationError(.spawnFailed, details: ["errno": .number(Double(code))]) }
    return pid
  }

  /// True once `pid`, a child of this process, has exited and is reaped (or is no longer a child).
  public static func reapIfExited(_ pid: Int32) -> Bool { exec_reap_nonblocking(pid) != 0 }
}
