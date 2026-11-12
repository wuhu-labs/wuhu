import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
@testable import SpaceCore
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineV2ExecOutputBudgetTests {
  @Test(arguments: [(["abc"], 2, "ab"), (["ab", "c"], 2, "ab"), (["ab", "cd"], 3, "abc")])
  func outputBudgetKeepsExactlyTheAdmittedPrefix(_ chunks: [String], maxOutput: Int, expected: String) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "budget", operation: UUID(), createdAt: f.now, group: .shared, argv: ["chunks"], window: 128 * 1024, maxOutput: maxOutput)
      let stream = try await f.running(exec)
      defer { stream.close() }
      var offset: UInt64 = 0
      for chunk in chunks {
        try f.output(exec, from: offset, text: chunk)
        offset += UInt64(chunk.utf8.count)
        let through = offset
        try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.stdout == through }
        if f.space.worker.cell(f.cell).operation(exec.id)?.cut != nil { break }
      }
      try await f.wait { f.count(.operation(exec.operation, .stop)) == 1 }
      #expect(f.space.worker.cell(f.cell).operation(exec.id)?.stop == "outputLimit")
      let outputs = f.log.frames.withLock { $0.compactMap { if case let .output(pointer, _) = $0 { pointer } else { nil } } }
      let bytes = try outputs.reduce(into: Data()) { $0.append(try #require(f.space.machineBuffers.read($1))) }
      #expect(String(decoding: bytes, as: UTF8.self) == expected)
      f.answer(exec, .stop, verdict: .init(.stopped, reason: "outputLimit"), finals: ["stdout": .init(rawValue: offset)])
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.cut == true)
      #expect(f.ends.first?.cursor == maxOutput)
      #expect(f.ends.first?.error?.message == "outputLimit")
    }
  }

  @Test(arguments: [false, true])
  func anOverrunOnOneStreamKeepsTheOthersAdmittedOutput(_ stderrFirst: Bool) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "shared-budget", operation: UUID(), createdAt: f.now, group: .shared, argv: ["chunks"], maxOutput: 10)
      let stream = try await f.running(exec)
      defer { stream.close() }
      let first = stderrFirst ? "stderr" : "stdout"
      let second = stderrFirst ? "stdout" : "stderr"
      try f.output(exec, channel: first, text: "eeee")
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.cursor == 4 }
      try f.output(exec, channel: second, text: "oooooooo")
      try await f.wait { f.count(.operation(exec.operation, .stop)) == 1 }
      let outputs = f.log.frames.withLock { $0.compactMap { frame -> (String, Data)? in
        if case let .output(pointer, _) = frame { return (pointer.channel, f.space.machineBuffers.read(pointer)!) }
        return nil
      } }
      #expect(outputs.count == 2)
      #expect(outputs.first?.0 == first)
      #expect(outputs.first?.1 == Data("eeee".utf8))
      #expect(outputs.last?.0 == second)
      #expect(outputs.last?.1 == Data("oooooo".utf8))
      f.answer(exec, .stop, verdict: .init(.stopped, reason: "outputLimit"), finals: [first: .init(rawValue: 4), second: .init(rawValue: 8)])
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.cut == true)
      #expect(f.ends.first?.cursor == 10)
    }
  }

  @Test func aFullUnreadWindowPausesPollingUntilConsumed() async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "backpressure", operation: UUID(), createdAt: f.now, group: .shared, argv: ["chunks"], window: 128 * 1024)
      let stream = try await f.running(exec)
      defer { stream.close() }
      let tag = BoxTag.operation(exec.operation, .output("stdout"))
      try await f.wait { f.count(tag) == 1 }
      try f.output(exec, text: String(repeating: "x", count: 64 * 1024))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.cursor == 64 * 1024 }
      try await f.space.worker.call(f.cell) { try $0.wake() }
      #expect(f.count(tag) == 1)
      #expect(f.ends.isEmpty)
      stream.send(.consumed(64 * 1024))
      try await f.wait { f.count(tag) == 2 }
      let after = f.log.requests.withLock { $0.compactMap { request -> UInt64? in
        if case let .poll(_, channel, after, _, _, _) = request.exchange, channel == "stdout" { return after }
        return nil
      } }
      #expect(after == [0, 64 * 1024])
      #expect(f.space.worker.cell(f.cell).operation(exec.id)?.consumed == 64 * 1024)
    }
  }
}
