#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import JSONValue
import MachineChannel
import enum MachineContract.ExecOutputStream
import struct MachineContract.ExecStart
import enum MachineContract.ExecState
import struct MachineContract.ExecStatus
import struct MachineContract.MachineID

public struct ExecSession: Sendable {
  let client: SpaceClient
  let start: ExecStart

  public init(client: SpaceClient, start: ExecStart) {
    self.client = client
    self.start = start
  }

  public enum Termination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int, outputLimitReached: Bool)
    case machineLost(MachineID)
    case cancelled
    case tailLost
    case unreachable(attempts: Int)
    case streamFailed(String)
    case interrupted
  }

  // Delays sum to ~90s of redialing, comfortably past one network blip and past
  // the server's 60s caller-absence grace — beyond that the exec is dead anyway.
  static let maxUnreachableAttempts: Int = 8

  static func backoff(attempt: Int) -> Duration {
    .milliseconds(min(30000, 200 << min(attempt, 8)))
  }

  public func run(
    input: AsyncStream<[UInt8]>?,
    output: @escaping @Sendable (ExecOutputStream, [UInt8]) async -> Void,
  ) async throws -> Termination {
    let url = try self.client.url("/v1/exec/\(self.start.id.rawValue)")
    let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
    let endpoint = ChannelEndpoint()
    let exec = await endpoint.startExec(self.start)
    return await withTaskGroup(of: Termination?.self, returning: Termination.self) { group in
      group.addTask { await self.pumpStdin(input, into: exec) }
      group.addTask { await self.maintainConnection(endpoint, url: url, clock: clock) }
      group.addTask { await self.consumeEvents(exec, output: output) }
      var termination: Termination = .interrupted
      while let outcome = await group.next() {
        if let outcome {
          termination = outcome
          break
        }
      }
      group.cancelAll()
      return termination
    }
  }

  // Ruling 7: no PTY, ever. A nil input gets an immediate half-close so
  // interactive invocation never dangles; a stream half-closes on EOF.
  private func pumpStdin(_ input: AsyncStream<[UInt8]>?, into exec: OutgoingExec) async -> Termination? {
    guard let input else {
      await exec.closeStdin()
      return nil
    }
    do {
      for await chunk in input {
        try await exec.sendStdin(chunk)
      }
      await exec.closeStdin()
    } catch {}
    return nil
  }

  private func consumeEvents(
    _ exec: OutgoingExec,
    output: @Sendable (ExecOutputStream, [UInt8]) async -> Void,
  ) async -> Termination? {
    var total = 0
    do {
      for try await event in exec.events {
        switch event {
        case let .output(stream, _, data):
          total += data.count
          await output(stream, data.bytes)
        case let .exit(status):
          switch status {
          case let .exited(code):
            return .exited(Int32(truncatingIfNeeded: code))
          case let .signaled(signal):
            let limitReached = self.start.maxOutput.map { total >= $0 } ?? false
            return .signaled(signal, outputLimitReached: limitReached)
          }
        case .truncated, .failed:
          continue
        }
      }
      return nil
    } catch {
      return .streamFailed(String(describing: error))
    }
  }

  // Ruling 9: re-dial with the same exec id and let the channel replay
  // byte-exactly. After every sever the registry state decides: live execs keep
  // redialing, terminal states map to the terminal cases, and a server that
  // stops answering exhausts the attempt budget instead of spinning.
  private func maintainConnection(
    _ endpoint: ChannelEndpoint,
    url: URL,
    clock: any Clock<Duration>,
  ) async -> Termination? {
    var attempt = 0
    var unreachable = 0
    var drains = 0
    while !Task.isCancelled {
      do {
        let transport = try await self.client.dial(url, [])
        unreachable = 0
        attempt = 0
        await endpoint.run(transport)
      } catch is CancellationError {
        return nil
      } catch {
        unreachable += 1
      }
      if Task.isCancelled { return nil }
      switch await self.fetchStatus(url) {
      case .none:
        unreachable += 1
      case let .some(status):
        switch status.state {
        case .live:
          break
        case .machineLost:
          return .machineLost(status.machine)
        case .cancelled:
          return .cancelled
        case .exited, .signaled, .reaped:
          // Reaped still drains: the machine buffered the killed process's
          // output to termination, so the redial replays the tail and the
          // exit event, not a fabricated verdict.
          drains += 1
          if drains >= 2 {
            return .tailLost
          }
        }
      }
      if unreachable >= Self.maxUnreachableAttempts {
        return .unreachable(attempts: unreachable)
      }
      do {
        try await clock.sleep(for: Self.backoff(attempt: attempt))
      } catch {
        return nil
      }
      attempt += 1
    }
    return nil
  }

  private func fetchStatus(_ url: URL) async -> ExecStatus? {
    guard let response = try? await self.client.fetch(Request(url: url, method: .get)),
          200 ..< 300 ~= response.status.code,
          let text = try? await response.text(),
          let value = JSONValue.parse(text)
    else { return nil }
    return try? JSONValueDecoder().decode(ExecStatus.self, from: value)
  }
}
