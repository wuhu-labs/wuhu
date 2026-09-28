import Dependencies
import Foundation
@testable import MachineAgent
import MachineChannel
import MachineContract
import Scratch
import Synchronization
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

func execID(_ n: Int) -> ExecID {
  let digits = String(n)
  return ExecID(rawValue: "ex_t" + String(repeating: "0", count: 7 - digits.count) + digits)
}

func makeStart(
  _ id: ExecID,
  command: [String],
  cwd: String = "/",
  env: [String: String]? = nil,
  secrets: [String: String]? = nil,
  window: Int? = nil,
  maxOutput: Int? = nil,
  timeout: Double? = nil,
  session: ExecSessionCredential? = nil,
) -> ExecStart {
  ExecStart(
    id: id,
    cwd: cwd,
    command: command,
    env: env.map(StringMap.init),
    secrets: secrets.map(StringMap.init),
    window: window,
    maxOutput: maxOutput,
    timeout: timeout,
    session: session,
  )
}

final class Box<Value: Sendable>: Sendable {
  private let storage: Mutex<Value>

  init(_ value: Value) {
    storage = Mutex(value)
  }

  var value: Value {
    storage.withLock { $0 }
  }

  @discardableResult
  func update<R>(_ transform: @Sendable (inout Value) -> R) -> R {
    storage.withLock { transform(&$0) }
  }
}

struct CollectedExec {
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  var exit: MachineContract.ExitStatus?

  var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

func collect(_ exec: OutgoingExec) async throws -> CollectedExec {
  var collected = CollectedExec()
  for try await event in exec.events {
    switch event {
    case let .output(stream, _, data):
      switch stream {
      case .stdout: collected.stdout += data.bytes
      case .stderr: collected.stderr += data.bytes
      }
    case let .exit(status):
      collected.exit = status
      return collected
    default:
      continue
    }
  }
  return collected
}

func processAlive(_ pid: Int32) -> Bool {
  kill(pid, 0) == 0
}

func pollUntil(attempts: Int = 250, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
  @Dependency(\.continuousClock) var clock
  for _ in 0 ..< attempts {
    if try await condition() { return true }
    try await clock.sleep(for: .milliseconds(20))
  }
  return false
}

final class TapTransport: FrameTransport, Sendable {
  let base: InMemoryTransport
  let sent: Box<[Frame]>

  init(_ base: InMemoryTransport) {
    self.base = base
    sent = Box([])
  }

  var inbound: AsyncStream<[UInt8]> {
    base.inbound
  }

  func send(_ frame: [UInt8]) async throws {
    let decoded = try FrameCodec.decode(frame)
    sent.update { $0.append(decoded) }
    try await base.send(frame)
  }

  func close() {
    base.close()
  }

  func outputBytes() -> Int {
    sent.value.filter { $0.opcode == .output }
      .compactMap { try? $0.payload(OutputChunk.self) }
      .reduce(0) { $0 + $1.data.count }
  }
}

// Caller endpoint wired to a MachineAgent over in-memory transport pairs; each
// connect() is one connection round for both legs.
final class Harness: Sendable {
  let caller: ChannelEndpoint = ChannelEndpoint()
  let agent: MachineAgent
  let state: ScratchFolder
  var stateDirectory: String { state.path }

  private let agentTransports: AsyncStream<any FrameTransport>
  private let agentContinuation: AsyncStream<any FrameTransport>.Continuation
  private let callerTransports: AsyncStream<InMemoryTransport>
  private let callerContinuation: AsyncStream<InMemoryTransport>.Continuation

  init(killGrace: Duration = .milliseconds(300), disconnectGrace: Duration = .seconds(300)) throws {
    state = try ScratchFolder("machine-agent-tests")
    agent = MachineAgent(stateDirectory: state.path, killGrace: killGrace, disconnectGrace: disconnectGrace)
    (agentTransports, agentContinuation) = AsyncStream.makeStream()
    (callerTransports, callerContinuation) = AsyncStream.makeStream()
  }

  @discardableResult
  func connect(severAfterSends: Int? = nil, tapAgentSide: Bool = false) -> (agentSide: TapTransport?, sever: InMemoryTransport) {
    let (a, b) = InMemoryTransport.pair(severAfterSends: severAfterSends)
    let tap = tapAgentSide ? TapTransport(a) : nil
    agentContinuation.yield(tap ?? a)
    callerContinuation.yield(b)
    return (tap, a)
  }

  func run(_ body: @escaping @Sendable (Harness) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { [agent, agentTransports] in
        // Dials are strictly sequential, so a fresh iterator per call drains
        // the buffered feed in order.
        await agent.run(dial: {
          for await transport in agentTransports { return transport }
          throw ChannelError.severed
        })
      }
      group.addTask { [caller, callerTransports] in
        for await transport in callerTransports {
          await caller.run(transport)
        }
      }
      group.addTask {
        try await body(self)
      }
      try await group.next()
      group.cancelAll()
    }
  }
}

// Round trips fail fast with .severed while a leg is unbound; retry through it.
func retryingUntilBound<Result>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
  while true {
    do {
      return try await operation()
    } catch ChannelError.severed {
      await Task.yield()
    }
  }
}
