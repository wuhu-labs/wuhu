import struct MachineContract.ExecMintOutput
import struct MachineContract.ExecStart
import struct MachineContract.StringMap
import struct SpaceClient.ExecSession
import struct SpaceClient.SpaceClient

extension Executor {
  mutating func exec(_ command: ExecCommand) async throws -> Int32 {
    guard let address = parseMachineAddress(command.cwd) else {
      throw UsageError(message: "exec: --cwd wants machines://<name-or-id>/<path>, got \(command.cwd)")
    }
    let machine = try await self.machineID(address.machine, verb: "exec")
    let space = try self.wallet.pinnedSpace()
    let client = try await self.authenticated(space)
    let minted: ExecMintOutput = try await client.api(
      .post, "/v1/exec",
      body: .object(["machine": .string(machine.rawValue)]),
    )
    let start = ExecStart(
      id: minted.id,
      cwd: address.path,
      command: command.command,
      env: nil,
      secrets: command.secrets.isEmpty ? nil : StringMap(command.secrets),
      window: command.window,
      maxOutput: command.maxOutput,
      timeout: command.timeout,
    )
    let runner = self.runner
    let termination = try await ExecSession(client: client, start: start).run(
      input: runner.stdinIsTerminal ? nil : runner.stdinChunks(),
      output: { stream, bytes in
        switch stream {
        case .stdout: await runner.stdoutBytes(bytes)
        case .stderr: await runner.stderrBytes(bytes)
        }
      },
    )
    switch termination {
    case let .exited(code):
      return code
    case let .signaled(signal, outputLimitReached):
      if outputLimitReached, let limit = command.maxOutput {
        await runner.stderr("wuhu: output truncated at \(limit) bytes; command killed (--max-output)\n")
      }
      return Int32(truncatingIfNeeded: 128 + signal)
    case let .machineLost(machine):
      await runner.stderr("wuhu: machine \(machine.rawValue) lost; output above is partial\n")
      return 125
    case .cancelled:
      await runner.stderr("wuhu: exec \(start.id.rawValue) was cancelled\n")
      return 124
    case .tailLost:
      await runner.stderr("wuhu: exec finished but its output tail is no longer replayable; output above is incomplete\n")
      return 123
    case let .unreachable(attempts):
      await runner.stderr("wuhu: \(client.base) is unreachable after \(attempts) attempts; giving up on exec \(start.id.rawValue)\n")
      return 122
    case let .streamFailed(description):
      await runner.stderr("wuhu: exec stream error: \(description)\n")
      return 1
    case .interrupted:
      return 1
    }
  }
}
