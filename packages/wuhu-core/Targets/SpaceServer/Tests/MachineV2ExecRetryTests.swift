import ControlledTime
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OperationProtocol
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

final class CellExecLog: Sendable {
  let requests = Mutex<[BoxSocket.Outgoing]>([])
  let frames = Mutex<[ExecStream.Outgoing]>([])
}

final class CellExecFixture: Sendable {
  let space: Space
  let cell = MachineCell.ID("exec-test-machine")
  let log: CellExecLog
  let box: Peer<BoxSocket>

  init() async throws {
    let space = try Space.inMemory()
    let log = CellExecLog()
    self.space = space
    self.log = log
    let pubkey = try await seedBoxKey(space: space, machine: cell.key)
    box = try #require(space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { log.requests.withLock { $0.append(frame) } }
    })
  }

  var now: Date {
    @Dependency(\.date) var date
    return date.now
  }

  var ends: [ExecFinished] {
    log.frames.withLock { $0.compactMap { if case let .exit(end) = $0 { end } else { nil } } }
  }

  func count(_ tag: BoxTag) -> Int { log.requests.withLock { $0.count { $0.tag == tag } } }

  func described() async throws {
    try await wait { self.count(.describe) == 1 }
    box.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
    try await wait { self.space.worker.cell(self.cell).presence.state == "attached" }
  }

  func open(_ exec: MachineExec) async throws -> Peer<ExecStream> {
    @Dependency(\.uuid) var uuid
    _ = try await space.worker.call(cell) { try $0.reserve(exec) }
    let log = self.log
    let stream = try #require(space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid())) {
      if case let .frame(frame) = $0 { log.frames.withLock { $0.append(frame) } }
    })
    try await wait { self.count(.operation(exec.operation, .start)) == 1 }
    return stream
  }

  func running(_ exec: MachineExec) async throws -> Peer<ExecStream> {
    try await described()
    let stream = try await open(exec)
    answer(exec, .start)
    try await wait { self.count(.operation(exec.operation, .control)) == 1 }
    return stream
  }

  func answer(_ exec: MachineExec, _ purpose: BoxPurpose, verdict: Verdict? = nil, finals: [String: Offset] = [:]) {
    let finalOffsets: [String: Offset] = verdict == nil ? finals : ["stdout": .zero, "stderr": .zero].merging(finals) { _, actual in actual }
    box.send(.init(tag: .operation(exec.operation, purpose), answer: .snapshot(.init(snapshot: .init(
      operation: exec.operation, verdict: verdict, terminalToken: verdict == nil ? nil : UUID(), finalOffsets: finalOffsets, outputConsumed: false,
    )))))
  }

  func output(_ exec: MachineExec, channel: String = "stdout", from: UInt64 = 0, text: String) throws {
    let bytes = Data(text.utf8)
    let pointer = try #require(space.machineBuffers.put(bytes, operation: exec.operation, channel: channel, from: from))
    box.send(.init(tag: .operation(exec.operation, .output(channel)), answer: .snapshot(.init(snapshot: .init(
      operation: exec.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: channel,
      from: .init(rawValue: from), through: .init(rawValue: from + UInt64(bytes.count)),
    ), output: pointer, tail: Data(bytes.suffix(51200))))))
  }

  func advance(_ seconds: Double) async throws {
    @Dependency(\.date) var date
    @Dependency(\.timeControl) var time
    await time.advance(to: date.now.addingTimeInterval(seconds + 0.000001))
    try await space.worker.call(cell) { try $0.wake() }
  }

  func wait(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
    for _ in 0 ..< 20000 {
      if predicate() { return }
      try Task.checkCancellation()
      try await space.worker.call(cell) { _ in }
    }
    try #require(predicate(), "MachineCell did not make the expected progress", sourceLocation: sourceLocation)
  }
}

func withCellExecFixture<R>(_ body: (CellExecFixture) async throws -> R) async throws -> R {
  try await withDependencies {
    $0.installTimeControl()
  } operation: {
    let fixture = try await CellExecFixture()
    do {
      let result = try await body(fixture)
      fixture.box.close()
      try await fixture.space.close()
      return result
    } catch {
      fixture.box.close()
      try await fixture.space.close()
      throw error
    }
  }
}

@Suite(.deterministicDependencies) struct MachineV2ExecRetryTests {
  enum RetrySite: CaseIterable, Sendable {
    case describe, reconcile, kill, race, cancel, timeout, outputLimit, callerGone
  }

  @Test(arguments: RetrySite.allCases, [false, true])
  func transientExchangeFailureIsRetriedNotFatal(_ site: RetrySite, requestDeadline: Bool) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "retry", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"], maxOutput: site == .outputLimit ? 3 : nil, timeout: site == .timeout ? 1 : nil)
      let failure: BoxAnswer = requestDeadline ? .box(.init(.requestDeadline)) : .transport(.init(.transport))
      if site == .describe {
        try await f.described()
        try await f.advance(20)
        try await f.wait { f.count(.describe) == 2 }
        f.box.send(.init(tag: .describe, answer: failure))
        try await f.wait { f.space.worker.cell(f.cell).presence.describeDeadline == nil }
        #expect(f.space.worker.cell(f.cell).presence.state == "attached")
        try await f.advance(0.099)
        #expect(f.count(.describe) == 2)
        try await f.advance(0.002)
        try await f.wait { f.count(.describe) == 3 }
        f.box.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
        try await f.wait { f.space.worker.cell(f.cell).presence.state == "attached" }
      } else { try await f.described() }
      let stream = try await f.open(exec)
      defer { stream.close() }
      if site != .race {
        f.answer(exec, .start)
        try await f.wait { f.count(.operation(exec.operation, .control)) == 1 }
      }
      let purpose: BoxPurpose
      switch site {
      case .describe, .reconcile: purpose = .control
      case .kill, .race:
        try await f.space.worker.call(f.cell) { try $0.stop(exec.id) }
        purpose = .stop
      case .cancel:
        stream.send(.kill); purpose = .stop
      case .timeout:
        try await f.advance(1); purpose = .stop
      case .outputLimit:
        try f.output(exec, text: "input"); purpose = .stop
      case .callerGone:
        stream.close(); purpose = .stop
      }
      if site == .race {
        #expect(f.count(.operation(exec.operation, .stop)) == 0)
        f.answer(exec, .start)
      }
      let tag = BoxTag.operation(exec.operation, purpose)
      try await f.wait { f.count(tag) >= 1 }
      let before = f.count(tag)
      f.box.send(.init(tag: tag, answer: failure))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.flights[purpose]?.waiting == false }
      #expect(f.space.worker.cell(f.cell).operation(exec.id)?.delivered == false)
      try await f.advance(0.099)
      #expect(f.count(tag) == before)
      try await f.advance(0.002)
      try await f.wait { f.count(tag) == before + 1 }
      #expect(f.count(.operation(exec.operation, .start)) == 1)
      if purpose == .stop {
        let expected: String = switch site {
        case .timeout: "timeout"
        case .outputLimit: "outputLimit"
        case .callerGone: "callerGone"
        default: "callerCancelled"
        }
        let reasons = f.log.requests.withLock { $0.compactMap { if case let .stop(_, reason) = $0.exchange { reason } else { nil } } }
        #expect(reasons == [expected, expected])
        let finals: [String: Offset] = site == .outputLimit ? ["stdout": .init(rawValue: 5)] : [:]
        f.answer(exec, .stop, verdict: .init(.stopped, reason: expected), finals: finals)
      } else {
        try f.output(exec, text: "input")
        try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.stdout == 5 }
        f.answer(exec, .control, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 7]]), finals: ["stdout": .init(rawValue: 5)])
      }
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.delivered == true }
      if site != .callerGone {
        try await f.wait { f.ends.count == 1 }
        let end = try #require(f.ends.first)
        if purpose == .control { #expect(end.status == .exited(code: 7)); #expect(end.cursor == 5) }
        else { #expect(end.error?.code == .operationEnded) }
        if site == .timeout { #expect(end.timedOut == .statusUnknown) }
        if site == .outputLimit { #expect(end.cut); #expect(end.cursor == 3) }
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func aLostStartIsReconciledButNeverDispatchedTwice(_ applied: Bool, requestDeadline: Bool) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "lost-start", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"])
      try await f.described()
      let stream = try await f.open(exec)
      defer { stream.close() }
      f.box.send(.init(tag: .operation(exec.operation, .start), answer: requestDeadline ? .box(.init(.requestDeadline)) : .transport(.init(.transport))))
      try await f.wait { f.count(.operation(exec.operation, .control)) == 1 }
      #expect(f.count(.operation(exec.operation, .start)) == 1)
      if applied {
        f.answer(exec, .control, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 7]]))
      } else {
        f.box.send(.init(tag: .operation(exec.operation, .control), answer: .box(.init(.unknownOperation))))
      }
      try await f.wait { f.ends.count == 1 }
      #expect(f.count(.operation(exec.operation, .start)) == 1)
      if applied { #expect(f.ends.first?.status == .exited(code: 7)) }
      else { #expect(f.ends.first?.error?.code == .unknownOperation) }
    }
  }

  @Test(arguments: [false, true])
  func aLostStopThatAlreadyLandedMayFinishOnItsRetry(_ requestDeadline: Bool) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "applied-stop", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"])
      let stream = try await f.running(exec)
      defer { stream.close() }
      stream.send(.kill)
      let tag = BoxTag.operation(exec.operation, .stop)
      try await f.wait { f.count(tag) == 1 }
      f.box.send(.init(tag: tag, answer: requestDeadline ? .box(.init(.requestDeadline)) : .transport(.init(.transport))))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.flights[.stop]?.waiting == false }
      try await f.advance(0.101)
      try await f.wait { f.count(tag) == 2 }
      f.answer(exec, .stop, verdict: .init(.stopped, reason: "callerCancelled"))
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.error?.message == "callerCancelled")
      #expect(f.count(.operation(exec.operation, .start)) == 1)
    }
  }

  @Test(arguments: ["timeout", "kill", "race"])
  func timedExecWhoseStopsAreLostEndsWithinTheGrace(_ path: String) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "lost-stops", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"], timeout: 1)
      try await f.described()
      let stream = try await f.open(exec)
      defer { stream.close() }
      if path != "race" {
        f.answer(exec, .start)
        try await f.wait { f.count(.operation(exec.operation, .control)) == 1 }
      }
      if path != "timeout" { try await f.space.worker.call(f.cell) { try $0.stop(exec.id) } }
      if path == "race" {
        #expect(f.count(.operation(exec.operation, .stop)) == 0)
        f.answer(exec, .start)
      }
      try await f.advance(1)
      let tag = BoxTag.operation(exec.operation, .stop)
      try await f.wait { f.count(tag) >= 1 }
      f.box.send(.init(tag: tag, answer: .transport(.init(.transport))))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.flights[.stop]?.waiting == false }
      try await f.advance(0.101)
      try await f.wait { f.count(tag) >= 2 }
      try await f.advance(29.898)
      #expect(f.ends.isEmpty)
      try await f.advance(0.002)
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.error?.code == .requestDeadline)
      #expect(f.space.worker.cell(f.cell).operation(exec.id)?.terminal == true)
      if path == "timeout" { #expect(f.ends.first?.timedOut == .statusUnknown) }
      #expect(f.count(.operation(exec.operation, .start)) == 1)
    }
  }

  @Test func aSetupFailureAfterTheTimeoutKeepsItsOwnMessage() async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "slow-setup", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"], timeout: 1)
      try await f.described()
      let stream = try await f.open(exec)
      defer { stream.close() }
      try await f.advance(1.5)
      #expect(f.space.worker.cell(f.cell).operation(exec.id)?.stop == "timeout")
      #expect(f.count(.operation(exec.operation, .stop)) == 0)
      #expect(f.count(.operation(exec.operation, .control)) == 0)
      f.box.send(.init(tag: .operation(exec.operation, .start), answer: .preparation(.init(.machineNotAuthorized, message: "setup refused"))))
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.error?.code == .machineNotAuthorized)
      #expect(f.ends.first?.error?.message == "setup refused")
      #expect(f.ends.first?.timedOut == nil)
      #expect(f.count(.operation(exec.operation, .start)) == 1)
      #expect(f.count(.operation(exec.operation, .stop)) == 0)
    }
  }

  @Test(arguments: [false, true])
  func aNonretryableStartOrPollFailureKeepsItsOwnDiagnostic(_ poll: Bool) async throws {
    try await withCellExecFixture { f in
      let exec = MachineExec(id: "fatal", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"])
      try await f.described()
      let stream = try await f.open(exec)
      defer { stream.close() }
      if poll {
        f.answer(exec, .start)
        try await f.wait { f.count(.operation(exec.operation, .control)) == 1 }
      }
      f.box.send(.init(tag: .operation(exec.operation, poll ? .control : .start), answer: .box(.init(.invalidInput, message: "refused"))))
      try await f.wait { f.ends.count == 1 }
      #expect(f.ends.first?.error?.code == .invalidInput)
      #expect(f.ends.first?.error?.message == "refused")
      #expect(f.ends.first?.timedOut == nil)
      #expect(f.count(.operation(exec.operation, .stop)) == 0)
    }
  }
}
