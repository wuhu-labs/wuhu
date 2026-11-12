import ControlledTime
import Dependencies
import DeterministicDependencies
@testable import ExecSupervisor
import Fetch
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
import JSONValue
import MachineContract
@testable import MainHub
@testable import OperationRuntime
import Scratch
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall
import Wuwei

@Suite(.deterministicDependencies(clock: ContinuousClock()), .timeLimit(.minutes(1)))
struct ExecDefaultLifetimeTests {
  @Test func theV2SupervisorKillsTheProcessGroupAtTheDefaultLifetime() async throws {
    try await withDependencies {
      $0.installTimeControl()
    } operation: {
      let work = try ScratchFolder("exec-default-lifetime-v2")
      defer { work.remove() }
      let space = try Space.inMemory()
      let machine = try await space.addMachineV2(name: "lifetime_v2", group: .shared).machine.id
      let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(ExecKind())], authorize: { _, _ in })
      let hub = MachineHub(space: space)
      do {
        try await withThrowingTaskGroup(of: Void.self) { tasks in
          tasks.addTask { await agent.run() }
          defer { tasks.cancelAll() }
          do {
            try await withMachineBox(space: space, hub: hub, machine: machine, client: FetchClient { try await agent.handler($0) }) {
              try await ToolLifetimes.$execDefault.withValue(1) {
                let plan = try ExecToolPlan(ToolCall(id: "default-lifetime", name: "exec", arguments: .object([
                  "machine": .string(machine.rawValue), "cwd": .string(work.path),
                  "command": "mkfifo child-input; trap 'wait; exit 143' TERM; cat child-input & echo $! > child; echo started; wait",
                ])))
                #expect(plan.lifetime == 1 && plan.defaultLifetime)
                let first = try await LifetimeExec(space: space, machine: machine, plan: plan)
                defer { first.peer.close() }
                await first.events.output.wait()
                try #require(first.events.printed.withLock { $0 }, "the default exec closed or ended before its readiness output")
                try await advanceLifetime(space, machine: machine, by: 1.001)
                try await completeLifetime(space, agent: agent, machine: machine, exec: first)
                await first.events.ended.wait()
                let killed = try #require(first.events.end.withLock { $0 })
                guard case let .exec(result) = plan.finished(killed) else { Issue.record("default lifetime failed: \(killed)"); return }
                #expect(result.output == "started\n\n[killed after 1 s, the default max lifetime; start longer work detached and watch it from run_script]")
                #expect([128 + 15, 128 + 9].contains(result.exitCode))
                let child = try #require(Int32(String(contentsOfFile: work.path + "/child", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                #expect(!isRunning(child), "the backgrounded child survived the kill")

                let explicit = try ExecToolPlan(ToolCall(id: "explicit-lifetime", name: "exec", arguments: .object([
                  "machine": .string(machine.rawValue), "cwd": .string(work.path),
                  "command": "mkfifo release; exec 3<>release; echo ready; read line <&3; echo finished", "max_lifetime_seconds": 30,
                ])))
                #expect(explicit.lifetime == 30 && !explicit.defaultLifetime)
                let second = try await LifetimeExec(space: space, machine: machine, plan: explicit)
                defer { second.peer.close() }
                await second.events.output.wait()
                try #require(second.events.printed.withLock { $0 }, "the explicit exec closed or ended before its readiness output")
                try await advanceLifetime(space, machine: machine, by: 2)
                #expect(second.events.end.withLock { $0 == nil })
                #expect(try await space.execRecord(second.id)?.terminal == nil)
                let fd = open(work.path + "/release", O_WRONLY | O_NONBLOCK)
                try #require(fd >= 0, "the explicit lifetime ended before its release")
                let release = Array("go\n".utf8)
                let written = release.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                #expect(written == release.count)
                #expect(close(fd) == 0)
                try await completeLifetime(space, agent: agent, machine: machine, exec: second)
                await second.events.ended.wait()
                let end = try #require(second.events.end.withLock { $0 })
                guard case let .exec(finished) = explicit.finished(end) else { Issue.record("explicit lifetime failed: \(end)"); return }
                #expect(finished.output == "ready\nfinished\n", "explicit lifetime output: \(String(reflecting: finished.output))")
                #expect(finished.exitCode == 0)
              }
            }
            await agent.shutdown()
          } catch {
            await agent.shutdown()
            throw error
          }
        }
        try await space.close()
      } catch {
        try await space.close()
        throw error
      }
    }
  }
}

private extension OperationAgent {
  func lifetimeFinalEvidence(_ operation: UUID) async throws -> Bool {
    while true {
      try Task.checkCancellation()
      guard let snapshot = inspect(operation) else { return false }
      if snapshot.verdict != nil, snapshot.finalOffsets["stdout"] != nil, snapshot.finalOffsets["stderr"] != nil { return true }
      await nextChange()
    }
  }
}

private struct LifetimeExec: Sendable {
  let id: ExecID
  let operation: UUID
  let peer: Peer<ExecStream>
  let events = LifetimeEvents()

  init(space: Space, machine: MachineID, plan: ExecToolPlan) async throws {
    @Dependency(\.uuid) var uuid
    let record = try await space.reserveExec(machine: machine)
    id = record.id
    var request = try #require(try await space.execRequest(id))
    operation = request.operation
    request.argv = plan.argv; request.cwd = plan.cwd; request.env = plan.env; request.secrets = plan.secrets
    request.timeout = plan.lifetime; request.maxOutput = plan.maxOutput
    let events = self.events
    peer = try #require(space.worker.attach(ExecStream.self, to: MachineCell.ID(machine.rawValue), opening: .init(exec: request, nonce: uuid())) {
      switch $0 {
      case let .frame(frame):
        switch frame {
        case .output: events.printed.withLock { $0 = true }; events.output.open()
        case let .exit(value):
          events.end.withLock { $0 = value }
          events.output.open(); events.ended.open()
        case .accepted: break
        }
      case .closed:
        events.output.open(); events.ended.open()
      }
    })
  }
}

private final class LifetimeEvents: Sendable {
  let output = Gate()
  let ended = Gate()
  let end = Mutex<ExecFinished?>(nil)
  let printed = Mutex(false)
}

private func advanceLifetime(_ space: Space, machine: MachineID, by seconds: Double) async throws {
  @Dependency(\.date) var date
  @Dependency(\.timeControl) var time
  await time.advance(to: date.now.addingTimeInterval(seconds))
  try await space.worker.call(MachineCell.ID(machine.rawValue)) { try $0.wake() }
}

private func completeLifetime(_ space: Space, agent: OperationAgent, machine: MachineID, exec: LifetimeExec) async throws {
  let retainedCompletion = try await agent.lifetimeFinalEvidence(exec.operation)
  // At most 10 s of injected time stays below the 28 s remaining lifetime and 30 s stop grace.
  for _ in 0 ..< 100 {
    try Task.checkCancellation()
    if exec.events.end.withLock({ $0 != nil }) { return }
    try await advanceLifetime(space, machine: machine, by: 0.1)
  }
  try #require(exec.events.end.withLock { $0 != nil }, "the native operation must deliver within the bounded clock advance (retained final evidence: \(retainedCompletion))")
}

private func isRunning(_ pid: Int32) -> Bool {
  guard kill(pid, 0) == 0 else { return false }
  #if os(Linux)
    if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8), let name = stat.lastIndex(of: ")") {
      return !stat[name...].hasPrefix(") Z")
    }
  #endif
  return true
}
