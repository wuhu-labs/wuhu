#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch
import JSONValue
import MachineChannel
import enum MachineContract.ExecEvent
import enum MachineContract.ExecOutputStream
import struct MachineContract.ExecStart
import enum MachineContract.ExecState
import struct MachineContract.ExecStatus
import struct MachineContract.MachineID
import struct MachineContract.MachineStatus

public struct ExecSession: Sendable {
  let client: SpaceClient
  let start: ExecStart
  private let execution = Execution()

  // The caller leg's handle; a call made before `run` has started waits for it.
  private actor Execution {
    private var outgoing: OutgoingExec?
    private var waiting: [CheckedContinuation<OutgoingExec, Never>] = []
    /// Output arrived: the process ran on the machine.
    private(set) var ran = false

    func noteRan() { ran = true }

    func set(_ outgoing: OutgoingExec) {
      self.outgoing = outgoing
      for waiter in waiting { waiter.resume(returning: outgoing) }
      waiting = []
    }

    func ready() async -> OutgoingExec {
      if let outgoing { return outgoing }
      return await withCheckedContinuation { waiting.append($0) }
    }
  }

  public func acknowledgeExit() async {
    await execution.ready().acknowledgeExit()
  }

  /// Consumption acknowledgement for a run without `autoAcknowledge`.
  public func acknowledge(through cursor: Int) async {
    await execution.ready().acknowledge(through: cursor)
  }

  /// Kill over the caller leg; the exec's exit still arrives as an event.
  public func kill() async {
    await execution.ready().kill()
  }

  /// Stdin for a run with `input: .caller`: waits for the machine's window,
  /// and is dropped once the exec has exited or stdin is closed.
  public func sendStdin(_ bytes: [UInt8]) async throws {
    try await execution.ready().sendStdin(bytes)
  }

  public func closeStdin() async {
    await execution.ready().closeStdin()
  }

  public enum Stdin: Sendable {
    /// Half-closed at once, so interactive invocation never dangles (ruling 7: no PTY, ever).
    case closed
    /// Pumped from the stream; EOF half-closes.
    case stream(AsyncStream<[UInt8]>)
    /// Driven by the caller through `sendStdin`/`closeStdin`.
    case caller
  }

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
    autoAcknowledge: Bool = true,
    failOnRemoteError: Bool = false,
    input: Stdin,
    output: @escaping @Sendable (ExecOutputStream, [UInt8]) async -> Void,
    onEvent: (@Sendable (ExecEvent) async -> Void)? = nil,
    onTermination: (@Sendable (Termination) async -> Void)? = nil,
  ) async throws -> Termination {
    let url = try self.client.url("/v1/exec/\(self.start.id.rawValue)")
    let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
    let endpoint = ChannelEndpoint()
    let exec = await endpoint.startExec(self.start, autoAcknowledge: autoAcknowledge)
    await execution.set(exec)
    return await withTaskGroup(of: Termination?.self, returning: Termination.self) { group in
      group.addTask { await self.pumpStdin(input, into: exec) }
      group.addTask { await self.maintainConnection(endpoint, url: url, clock: clock) }
      group.addTask { await self.consumeEvents(exec, output: output, onEvent: onEvent, failOnRemoteError: failOnRemoteError) }
      var termination: Termination = .interrupted
      while let outcome = await group.next() {
        if let outcome {
          termination = outcome
          break
        }
      }
      // Settlement may wait for a durable result before acknowledging the
      // exit; keep the caller leg running until that acknowledgement is sent.
      await onTermination?(termination)
      group.cancelAll()
      return termination
    }
  }

  private func pumpStdin(_ input: Stdin, into exec: OutgoingExec) async -> Termination? {
    switch input {
    case .closed:
      await exec.closeStdin()
    case let .stream(chunks):
      do {
        for await chunk in chunks {
          try await exec.sendStdin(chunk)
        }
        await exec.closeStdin()
      } catch {}
    case .caller:
      break
    }
    return nil
  }

  private func consumeEvents(
    _ exec: OutgoingExec,
    output: @Sendable (ExecOutputStream, [UInt8]) async -> Void,
    onEvent: (@Sendable (ExecEvent) async -> Void)?,
    failOnRemoteError: Bool,
  ) async -> Termination? {
    var total = 0
    do {
      for try await event in exec.events {
        await onEvent?(event)
        switch event {
        case let .output(stream, _, data):
          if total == 0 { await execution.noteRan() }
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
        case let .failed(error):
          if failOnRemoteError { return .streamFailed(error.message) }
        case .truncated, .timedOut:
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
      } catch let refusal as SpaceClient.DialRefusal where refusal.isFinal {
        // The server answered and said no: redialing gets the same answer,
        // so this is not an unreachable server.
        return .streamFailed(refusal.description)
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
        case .cancelled where !(await self.mayStillSettle(status)):
          return .cancelled
        case .cancelled, .exited, .signaled, .reaped:
          // Cancelled and reaped still drain: the machine may settle the row
          // with the killed process's buffered output and exit, so the redial
          // replays the tail and the exit event, not a fabricated verdict. A
          // second sever means the tail is gone.
          drains += 1
          if drains >= 2 {
            return status.state == .cancelled ? .cancelled : .tailLost
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

  // A cancelled exec drains when the machine can still settle it: the kill
  // reached the machine, the process had produced output, or the machine is
  // attached now. One whose machine never got it and is away never ran there
  // (`killOnDetachedMachineSurfacesCancelled`), so nothing waits out the grace.
  private func mayStillSettle(_ status: ExecStatus) async -> Bool {
    if status.killDelivered == true { return true }
    if await execution.ran { return true }
    guard let machines: [MachineStatus] = try? await self.client.api(.get, "/v1/machine") else { return true }
    return machines.first { $0.id == status.machine }?.attached ?? true
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
