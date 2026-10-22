import Clocks
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import Fetch
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationProtocol
import OperationRuntime
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

/// Writes each argument as its own chunk, 300 ms apart, to stderr when it starts with `2>` and to stdout otherwise, then runs
/// until it is stopped, noting the reason.
private struct ChunkedOutput: OperationKind {
  let note: StopNote
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    do {
      for (index, chunk) in input.argv.enumerated() {
        if index > 0 { try await Task.sleep(for: .milliseconds(300)) }
        let (channel, text) = chunk.hasPrefix("2>") ? ("stderr", chunk.dropFirst(2)) : ("stdout", Substring(chunk))
        try await channels.send(.init(data: Data(text.utf8)), to: channel)
      }
      while true {
        try await cancellation.check()
        try await Task.sleep(for: .milliseconds(10))
      }
    } catch {
      let reason = await cancellation.reason()
      note.reason.withLock { $0 = reason ?? "unknown" }
      throw error
    }
  }
}

private final class StopNote: Sendable {
  let reason = Mutex<String?>(nil)
}

@Suite(.deterministicDependencies(clock: TestClock()), .timeLimit(.minutes(1)))
struct MachineV2ExecOutputBudgetTests {
  /// The overrun ends the exec however the machine splits the output: a send waiting on the caller's unread window must not hide
  /// the excess byte, and output queued for the window before the overrun still reaches the caller.
  @Test(arguments: [(["abc"], 1, 2, "a"), (["ab", "c"], 1, 2, "a"), (["ab", "cd"], 100, 3, "abc")])
  func outputBudgetEndsTheExecWhenTheUnreadWindowFills(_ chunks: [String], window: Int, maxOutput: Int, expected: String) async throws {
    let (stdout, stderr) = try await runOverBudget(chunks, window: window, maxOutput: maxOutput)
    #expect(stdout == expected)
    #expect(stderr == "")
  }

  /// The streams share the budget: an overrun on either keeps what the other had admitted. The relay polls the streams on their
  /// own, so which one reaches the budget first is not fixed; together they carry exactly the budget, each a prefix of its output.
  @Test func anOverrunOnOneStreamKeepsTheOthersAdmittedOutput() async throws {
    let (stdout, stderr) = try await runOverBudget(["2>eeee", "oooooooo"], window: 100, maxOutput: 10)
    #expect(stdout.count + stderr.count == 10, "stdout \(stdout), stderr \(stderr)")
    #expect(!stdout.isEmpty && "oooooooo".hasPrefix(stdout))
    #expect(!stderr.isEmpty && "eeee".hasPrefix(stderr))
  }

  private func runOverBudget(_ chunks: [String], window: Int, maxOutput: Int) async throws -> (stdout: String, stderr: String) {
    let note = StopNote()
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "budget_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [.init(ChunkedOutput(note: note))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: chunks, window: window, maxOutput: maxOutput))
    return try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { caller.cancel() }
      // Nothing reads the output until the exec has ended, so a small window stays full.
      var ended = false
      for _ in 0 ..< 500 where !ended {
        ended = try await space.execRecord(minted.id)?.terminal != nil
        if !ended { try await Task.sleep(for: .milliseconds(10)) }
      }
      #expect(ended, "the over-budget exec never ended")
      #expect(note.reason.withLock { $0 } == "outputLimit")
      var stdout = Data()
      var stderr = Data()
      var status: MachineContract.ExitStatus?
      var truncated = false
      for try await event in outgoing.events {
        switch event {
        case let .output(stream, _, bytes): if stream == .stdout { stdout.append(contentsOf: bytes.bytes) } else { stderr.append(contentsOf: bytes.bytes) }
        case let .exit(value): status = value
        case .truncated: truncated = true
        case .failed, .timedOut: break
        }
      }
      #expect(truncated)
      #expect(status == .exited(code: 1))
      await agent.shutdown(); await service.shutdown()
      return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
  }
}
