import Dependencies
import MachineChannel
import struct MachineContract.ExecID

// Keeps an exec's caller leg dialed, re-dialing with backoff, and returns why it
// gave up (nil once cancelled). A machine-lost verdict never proves process exit.
func holdExecLeg(
  _ id: ExecID,
  endpoint: ChannelEndpoint,
  backend: ExecBackend,
) async throws -> String? {
  let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
  var unreachable = 0
  var terminalSevers = 0
  while !Task.isCancelled {
    do {
      let transport = try await backend.connect(id)
      unreachable = 0
      await endpoint.run(transport)
    } catch is CancellationError {
      return nil
    } catch {
      unreachable += 1
    }
    if Task.isCancelled { return nil }
    if let record = try? await backend.status(id), let terminal = record.terminal {
      if terminal == .machineLost {
        return "machine \(record.machine.rawValue) stopped responding; remote process outcome is unknown"
      }
      // Terminal without a delivered exit: one more round may still
      // drain the buffered tail; a second sever means it cannot.
      terminalSevers += 1
      if terminalSevers >= 2 {
        return "\(execHandle(id)) is finished and its stream is no longer replayable"
      }
    }
    if unreachable >= 8 {
      return "machine connection for \(execHandle(id)) failed; the run may still be tracked server-side"
    }
    try await clock.sleep(for: .milliseconds(50 * (1 << min(unreachable, 5))))
  }
  return nil
}
