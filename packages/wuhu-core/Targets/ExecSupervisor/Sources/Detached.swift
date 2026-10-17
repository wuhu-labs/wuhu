import CExecSupervisor
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
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

  /// As `launchDetached`, and a thread of this process reaps it whenever it exits: no zombie outlives whatever launched it.
  static func launchReaped(_ arguments: [String]) throws -> Int32 {
    let pid = try launchDetached(arguments)
    let code = exec_reap_when_exited(pid)
    guard code == 0 else {
      _ = exec_signal_group(pid, SIGKILL); _ = exec_reap(pid)
      throw OperationError(.spawnFailed, details: ["errno": .number(Double(code))])
    }
    return pid
  }

  /// Whether `pid` names a process (one exited and not yet reaped included).
  static func running(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

  /// True once `pid`, a child of this process, has exited and is reaped (or is no longer a child).
  public static func reapIfExited(_ pid: Int32) -> Bool { exec_reap_nonblocking(pid) != 0 }
}
