#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ControlledTime
import Dependencies
import OperationProtocol
@testable import SpaceCore
import Testing
import Wuwei
import WuweiQueries

extension MachineCellTests {
  private func reply(_ snapshot: OperationSnapshot, purpose: BoxPurpose, output: MachinePointer? = nil, tail: Data = Data(), in space: Space) async throws {
    try await space.worker.call(cell) { cell in
      let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
      try cell.answer(.init(tag: .operation(snapshot.operation, purpose), answer: .snapshot(.init(snapshot: snapshot, output: output, tail: tail))), from: box)
    }
  }

  @Test func channelEndBeforeVerdictSuppressesPollingWithoutLosingTheFinalOffsetAck() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "early-eof", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"])
      try await starting(space, peer, exec)
      let stdout = BoxTag.operation(exec.operation, .output("stdout"))
      try await until("initial stdout poll emits") { requests.value.contains { $0.tag == stdout } }
      let count = requests.value.filter { $0.tag == stdout }.count
      let eof = OperationSnapshot(operation: exec.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: "stdout", from: .zero, through: .zero, channelEnd: true)
      try await reply(eof, purpose: .output("stdout"), in: space)
      var answered = count
      for _ in 0 ..< 4 {
        await time.advance(by: 0.05)
        try await space.worker.call(cell) { try $0.wake() }
        if requests.value.filter({ $0.tag == stdout }).count > answered {
          answered += 1
          try await reply(eof, purpose: .output("stdout"), in: space)
        }
      }
      print("MachineCell early EOF extra polls/200ms: \(requests.value.filter { $0.tag == stdout }.count - count)")
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.output("stdout")]?.waiting == nil)
      #expect(requests.value.filter { $0.tag == stdout }.count == count)
      let bytes = Data("x".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stderr", from: 0))
      let lastBytes = OperationSnapshot(operation: exec.operation, verdict: nil, terminalToken: nil, finalOffsets: ["stderr": .init(rawValue: 1)], outputConsumed: false, channel: "stderr", from: .zero, through: .init(rawValue: 1), channelEnd: true)
      try await reply(lastBytes, purpose: .output("stderr"), output: pointer, tail: bytes, in: space)
      try await until("other-channel progress is acknowledged immediately") {
        requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stderr" && after == 1 } else { false } }
      }
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.output("stderr")]?.retry == 100)
      let stderrCount = requests.value.filter { $0.tag == .operation(exec.operation, .output("stderr")) }.count
      let acknowledgedEnd = OperationSnapshot(operation: exec.operation, verdict: nil, terminalToken: nil, finalOffsets: ["stderr": .init(rawValue: 1)], outputConsumed: false, channel: "stderr", from: .init(rawValue: 1), through: .init(rawValue: 1), channelEnd: true)
      try await reply(acknowledgedEnd, purpose: .output("stderr"), in: space)
      try await reply(snapshot(exec), purpose: .control, in: space)
      await time.advance(by: 0.2)
      try await space.worker.call(cell) { try $0.wake() }
      #expect(requests.value.filter { $0.tag == stdout }.count == count)
      #expect(requests.value.filter { $0.tag == .operation(exec.operation, .output("stderr")) }.count == stderrCount)
      peer.close()
      try await space.close()
    }
  }

  @Test func aKnownVerdictSuppressesControlAndRetriesUnsettledTerminalAcknowledgments() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "verdict-backpressure", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"], window: 131_072)
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) { _ in })
      try await until("stream dispatches") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      try await reply(snapshot(exec), purpose: .start, in: space)
      let control = BoxTag.operation(exec.operation, .control)
      try await until("initial control poll emits") { requests.value.contains { $0.tag == control } }
      let bytes = Data(repeating: 65, count: 65536)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let verdict = Verdict(.completed, result: ["termination": ["tag": "exit", "code": 0]])
      let finals: [String: Offset] = ["stdout": .init(rawValue: 131_072), "stderr": .zero]
      try await reply(snapshot(exec, channel: "stdout", from: 0, through: 65536, verdict: verdict, finals: finals), purpose: .output("stdout"), output: pointer, tail: bytes.suffix(51200), in: space)
      let count = requests.value.filter { $0.tag == control }.count
      let ended = snapshot(exec, verdict: verdict, finals: finals)
      try await reply(ended, purpose: .control, in: space)
      var answered = count
      for _ in 0 ..< 4 {
        await time.advance(by: 0.05)
        try await space.worker.call(cell) { try $0.wake() }
        if requests.value.filter({ $0.tag == control }).count > answered {
          answered += 1
          try await reply(ended, purpose: .control, in: space)
        }
      }
      print("MachineCell verdict extra control polls/200ms: \(requests.value.filter { $0.tag == control }.count - count)")
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.control]?.waiting == nil)
      #expect(requests.value.filter { $0.tag == control }.count == count)
      #expect(!requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 65536 } else { false } })
      try await space.worker.call(cell) { cell in
        let stream = try #require(cell.ctx.sockets(of: ExecStream.self).first)
        try cell.stream(.consumed(65536), from: stream)
      }
      try await until("consumption resumes output after control polling is suppressed") {
        requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 65536 } else { false } }
      }
      let rest = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 65536))
      try await reply(snapshot(exec, channel: "stdout", from: 65536, through: 131_072, verdict: verdict, finals: finals), purpose: .output("stdout"), output: rest, tail: bytes.suffix(51200), in: space)
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == true)
      try await reply(ended, purpose: .terminal("stdout"), in: space)
      try await reply(ended, purpose: .terminal("stderr"), in: space)
      #expect(space.worker.cell(cell).operation(exec.id)?.terminal == false)
      let terminal = BoxTag.operation(exec.operation, .terminal("stdout"))
      let before = requests.value.filter { $0.tag == terminal }.count
      try #require(space.worker.cell(cell).operation(exec.id)?.flights[.terminal("stdout")]?.waiting == false)
      await time.advance(by: 0.1)
      try await space.worker.call(cell) { try $0.wake() }
      try await until("unsettled terminal ACK retries at its deadline") { requests.value.filter { $0.tag == terminal }.count == before + 1 }
      #expect(requests.value.filter { $0.tag == control }.count == count)
      try await space.worker.call(cell) { cell in
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(.init(tag: terminal, answer: .box(.init(.unknownOperation))), from: box)
      }
      #expect(space.worker.cell(cell).operation(exec.id)?.terminal == true)
      stream.close(); peer.close()
      try await space.close()
    }
  }

  @Test func zeroHoldQuietPollsBackOffToABoundAndProgressResetsTheRetry() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      _ = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      var limits = OperationLimits()
      limits.pollHoldMs = 0
      peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [ComputerKindSchemas.exec]))))
      try await until("zero-hold description commits") { space.worker.cell(cell).db.rows(MachinePresence.all).first?.state == "attached" }
      let exec = MachineExec(id: "zero-hold", operation: UUID(), createdAt: anchor, group: .shared, argv: ["sleep"])
      try await starting(space, peer, exec)
      let output = BoxTag.operation(exec.operation, .output("stdout"))
      let quiet = snapshot(exec, channel: "stdout", from: 0, through: 0)
      try await until("initial zero-hold poll emits") { requests.value.contains { $0.tag == output } }
      let initial = requests.value.filter { $0.tag == output }.count
      var answered = initial
      try await reply(quiet, purpose: .output("stdout"), in: space)
      for _ in 0 ..< 8 {
        await time.advance(by: 0.05)
        try await space.worker.call(cell) { try $0.wake() }
        if requests.value.filter({ $0.tag == output }).count > answered {
          answered += 1
          try await reply(quiet, purpose: .output("stdout"), in: space)
        }
      }
      print("MachineCell zero-hold extra output polls/400ms: \(requests.value.filter { $0.tag == output }.count - initial)")
      #expect(requests.value.filter { $0.tag == output }.count == initial + 2)
      for delay: Int64 in [800, 1600, 2000, 2000] {
        let flight = try #require(space.worker.cell(cell).operation(exec.id)?.flights[.output("stdout")])
        try #require(!flight.waiting)
        let remaining = try await space.worker.call(cell) { flight.due - $0.now }
        await time.advance(by: Double(remaining) / 1000)
        try await space.worker.call(cell) { try $0.wake() }
        try await reply(quiet, purpose: .output("stdout"), in: space)
        #expect(try await space.worker.call(cell) { $0.operation(exec.id)!.flights[.output("stdout")]!.due - $0.now } == delay)
        #expect(space.worker.cell(cell).operation(exec.id)?.flights[.output("stdout")]?.retry ?? 0 <= 2000)
      }
      let bytes = Data("x".utf8)
      let buffers = space.machineBuffers
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      try await reply(snapshot(exec, channel: "stdout", from: 0, through: 1), purpose: .output("stdout"), output: pointer, tail: bytes, in: space)
      try await until("real output resets the retry and acknowledges immediately") {
        requests.value.contains { if case let .poll(_, channel, after, _, _, _) = $0.exchange { channel == "stdout" && after == 1 } else { false } }
      }
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.output("stdout")]?.retry == 100)
      peer.close()
      try await space.close()
    }
  }

  @Test func unchangedInputReceiptsBackOffAndProgressResetsTheRetry() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "input-stalled", operation: UUID(), createdAt: anchor, group: .shared, argv: ["cat"])
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) { _ in })
      try await until("input stream dispatches") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      try await reply(snapshot(exec), purpose: .start, in: space)
      let pointer = try #require(buffers.put(Data("data".utf8), operation: exec.operation, channel: "stdin", from: 0))
      try await space.worker.call(cell) { cell in
        let stream = try #require(cell.ctx.sockets(of: ExecStream.self).first)
        try cell.stream(.stdin(pointer), from: stream)
      }
      let input = BoxTag.operation(exec.operation, .input)
      try await until("initial input emits") { requests.value.contains { $0.tag == input } }
      let count = requests.value.filter { $0.tag == input }.count
      for (blocked, delay) in [(false, 100), (true, 200)] {
        try await space.worker.call(cell) { cell in
          let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
          try cell.answer(.init(tag: input, answer: .input(.init(acceptedThrough: .zero, end: false, blocked: blocked))), from: box)
        }
        try #require(space.worker.cell(cell).operation(exec.id)?.flights[.input]?.waiting == false)
        #expect(try await space.worker.call(cell) { $0.operation(exec.id)!.flights[.input]!.due - $0.now } == Int64(delay))
        await time.advance(by: Double(delay) / 1000)
        try await space.worker.call(cell) { try $0.wake() }
      }
      try await until("stalled input retries on both deadlines") { requests.value.filter { $0.tag == input }.count == count + 2 }
      try await space.worker.call(cell) { cell in
        let box = try #require(cell.ctx.sockets(of: BoxSocket.self).first)
        try cell.answer(.init(tag: input, answer: .input(.init(acceptedThrough: .init(rawValue: 2), end: false, blocked: false))), from: box)
      }
      try await until("accepted input repolls the remaining bytes immediately") {
        requests.value.contains { if case let .input(_, pointer, _) = $0.exchange { pointer.from == 2 && pointer.through == 4 } else { false } }
      }
      #expect(space.worker.cell(cell).operation(exec.id)?.flights[.input]?.retry == 100)
      stream.close(); peer.close()
      try await space.close()
    }
  }

  @Test func reorderedChannelFinalOffsetsStillDeliverExitWithoutMoreNormalPolls() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let buffers = setup(space)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, requests)
      try await described(peer, space)
      let exec = MachineExec(id: "reordered-finals", operation: UUID(), createdAt: anchor, group: .shared, argv: ["echo"])
      _ = try await space.worker.call(cell) { try $0.reserve(exec) }
      let events = Box<[ExecStream.Outgoing]>([])
      @Dependency(\.uuid) var uuid
      let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) {
        if case let .frame(frame) = $0 { events.withLock { $0.append(frame) } }
      })
      try await until("reordered-finals stream dispatches") { space.worker.cell(cell).operation(exec.id)?.dispatched == true }
      try await reply(snapshot(exec), purpose: .start, in: space)
      let verdict = Verdict(.completed, result: ["termination": ["tag": "exit", "code": 0]])
      let token = UUID()
      let control = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: [:], outputConsumed: false)
      try await reply(control, purpose: .control, in: space)
      let bytes = Data("out".utf8)
      let pointer = try #require(buffers.put(bytes, operation: exec.operation, channel: "stdout", from: 0))
      let delayedStdout = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: ["stdout": .init(rawValue: 3)], outputConsumed: false, channel: "stdout", from: .zero, through: .init(rawValue: 3), channelEnd: true)
      let newerStderr = OperationSnapshot(operation: exec.operation, verdict: verdict, terminalToken: token, finalOffsets: ["stdout": .init(rawValue: 3), "stderr": .zero], outputConsumed: false, channel: "stderr", from: .zero, through: .zero, channelEnd: true)
      try await reply(newerStderr, purpose: .output("stderr"), in: space)
      #expect(space.worker.cell(cell).operation(exec.id)?.delivered == false)
      let normalPolls = requests.value.filter {
        switch $0.tag {
        case .operation(_, .control), .operation(_, .output): true
        default: false
        }
      }.count
      try await reply(delayedStdout, purpose: .output("stdout"), output: pointer, tail: bytes, in: space)
      let row = try #require(space.worker.cell(cell).operation(exec.id))
      #expect(row.stdout == 3 && row.stderr == 0)
      #expect(row.snapshot?.finalOffsets == ["stdout": .init(rawValue: 3), "stderr": .zero])
      #expect(requests.value.filter {
        switch $0.tag {
        case .operation(_, .control), .operation(_, .output): true
        default: false
        }
      }.count == normalPolls)
      try #require(row.delivered)
      try await until("merged channel finals deliver the stream exit") { events.value.contains { if case .exit = $0 { true } else { false } } }
      let exit = try #require(events.value.compactMap { if case let .exit(exit) = $0 { exit } else { nil } }.first)
      #expect(exit.status == .exited(code: 0))
      #expect(exit.tail == bytes && exit.cursor == 3)
      stream.close(); peer.close()
      try await space.close()
    }
  }
}
