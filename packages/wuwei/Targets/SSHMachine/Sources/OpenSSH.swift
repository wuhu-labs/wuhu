import Subprocess

extension SSHClient {
  /// The system `ssh` with one ControlMaster per host: `connect` starts the master or finds it still running from an earlier process, and each command is a client of it. Hosts, users and keys come from the ssh config. ssh's own failures exit 255, so a command that exits 255 by itself reads as a lost connection.
  public static func openSSH(socketDirectory: String) -> SSHClient {
    SSHClient { host in
      let control = ["-o", "BatchMode=yes", "-o", "ControlPath=\(socketDirectory)/\(host).sock"]
      if try await ssh(control + ["-O", "check", host]).status != 0 {
        let master = try await Subprocess.run(
          .name("ssh"),
          arguments: Arguments(control + ["-o", "ControlMaster=yes", "-o", "ControlPersist=10m", "-f", "-N", host]),
          output: .discarded,
          error: .discarded,
        )
        guard case .exited(0) = master.terminationStatus else { throw SSHFailure.unreachable("ssh \(host): \(master.terminationStatus)") }
      }
      return SSHConnection(
        run: { command in
          let output = try await ssh(control + ["-o", "ControlMaster=no", host, "--", command])
          guard output.status != 255 else { throw SSHFailure.lost(output.stderr) }
          return output
        },
        close: { _ = try? await ssh(control + ["-O", "exit", host]) },
      )
    }
  }
}

private func ssh(_ arguments: [String]) async throws -> SSHOutput {
  let result = try await Subprocess.run(.name("ssh"), arguments: Arguments(arguments), output: .string(limit: 1 << 20), error: .string(limit: 1 << 20))
  let status: Int32 = switch result.terminationStatus {
  case let .exited(code): code
  case let .signaled(signal): 128 + signal
  }
  return SSHOutput(status: status, stdout: result.standardOutput ?? "", stderr: result.standardError ?? "")
}
