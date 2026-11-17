import ControlledTime
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
@testable import Machines
import MachinesContract
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.Offset
import struct OperationProtocol.Verdict
@testable import SpaceCore
import SpaceIDs
import Synchronization
import Wuwei

public final class CellExecLog: Sendable {
  public let requests = Mutex<[BoxSocket.Outgoing]>([])
  public let frames = Mutex<[ExecStream.Outgoing]>([])
  public init() {}
}

/// One machine cell with a box socket the test drives by hand: what a machine cell answers to a described box.
public final class CellExecFixture: Sendable {
  public let space: Space
  public let cell: MachineCell.ID
  public let log: CellExecLog
  public let box: Peer<BoxSocket>

  public init(machine name: String = "exec-test") async throws {
    let space = try Space.inMemory().registeringMachines()
    let record = try await space.machineFamily.addMachineV2(name: name).machine
    let cell = MachineCell.ID(record.id.rawValue)
    let log = CellExecLog()
    self.space = space
    self.cell = cell
    self.log = log
    let pubkey = try await seedBoxKey(space: space, machine: cell.key)
    guard let box = try await space.worker.attach(BoxSocket.self, to: cell, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32), output: {
      if case let .frame(frame) = $0 { log.requests.withLock { $0.append(frame) } }
    }) else { throw MachineFixtureError("the machine box did not attach") }
    self.box = box
  }

  public var now: Date {
    @Dependency(\.date) var date
    return date.now
  }

  public var ends: [ExecFinished] {
    log.frames.withLock { $0.compactMap { if case let .exit(end) = $0 { end } else { nil } } }
  }

  public func count(_ tag: BoxTag) -> Int { log.requests.withLock { $0.count { $0.tag == tag } } }

  public func described() async throws {
    try await wait { self.count(.describe) == 1 }
    box.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
    try await wait { try await self.space.machineFamily.machineDescription(MachineID(rawValue: self.cell.key)) != nil }
  }

  public func open(_ exec: MachineExec) async throws -> Peer<ExecStream> {
    @Dependency(\.uuid) var uuid
    _ = try await space.worker.call(cell) { try $0.reserve(exec) }
    let log = self.log
    guard let stream = try await space.worker.attach(ExecStream.self, to: cell, opening: .init(exec: exec, nonce: uuid()), output: {
      if case let .frame(frame) = $0 { log.frames.withLock { $0.append(frame) } }
    }) else { throw MachineFixtureError("the exec stream did not attach") }
    try await wait { self.count(.operation(exec.operation, .start)) == 1 }
    return stream
  }

  public func running(_ exec: MachineExec) async throws -> Peer<ExecStream> {
    try await described()
    let stream = try await open(exec)
    answer(exec, .start)
    try await wait { self.count(.operation(exec.operation, .control)) == 1 }
    return stream
  }

  public func answer(_ exec: MachineExec, _ purpose: BoxPurpose, verdict: Verdict? = nil, finals: [String: Offset] = [:]) {
    let finalOffsets: [String: Offset] = verdict == nil ? finals : ["stdout": .zero, "stderr": .zero].merging(finals) { _, actual in actual }
    box.send(.init(tag: .operation(exec.operation, purpose), answer: .snapshot(.init(snapshot: .init(
      operation: exec.operation, verdict: verdict, terminalToken: verdict == nil ? nil : UUID(), finalOffsets: finalOffsets, outputConsumed: false,
    )))))
  }

  public func output(_ exec: MachineExec, channel: String = "stdout", from: UInt64 = 0, text: String) throws {
    let bytes = Data(text.utf8)
    guard let pointer = space.machineFamily.buffers.put(bytes, operation: exec.operation, channel: channel, from: from) else {
      throw MachineFixtureError("the output buffer refused \(bytes.count) bytes")
    }
    box.send(.init(tag: .operation(exec.operation, .output(channel)), answer: .snapshot(.init(snapshot: .init(
      operation: exec.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: channel,
      from: .init(rawValue: from), through: .init(rawValue: from + UInt64(bytes.count)),
    ), output: pointer, tail: Data(bytes.suffix(51200))))))
  }

  public func advance(_ seconds: Double) async throws {
    @Dependency(\.date) var date
    @Dependency(\.timeControl) var time
    await time.advance(to: date.now.addingTimeInterval(seconds + 0.000001))
    try await space.worker.call(cell) { try $0.wake() }
  }

  public func wait(_ predicate: () async throws -> Bool) async throws {
    for _ in 0 ..< 20000 {
      if try await predicate() { return }
      try Task.checkCancellation()
      try await space.worker.call(cell) { _ in }
    }
    guard try await predicate() else { throw MachineFixtureError("the machine cell did not make the expected progress") }
  }
}

public func withCellExecFixture<R>(_ body: (CellExecFixture) async throws -> R) async throws -> R {
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
