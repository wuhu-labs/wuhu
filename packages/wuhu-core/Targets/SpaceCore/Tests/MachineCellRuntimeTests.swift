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

@Suite(.deterministicDependencies) struct MachineCellRuntimeTests {
  @Test func pendingStartsShareTheDescriptionAndSteadyProgressUsesItsLimits() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "runtime").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let box = try await RuntimeBox.attach(space, id: id)
    let read = UUID(), stat = UUID()
    let readFrames = RuntimeLog<FileBulk.Outgoing>()
    let statFrames = RuntimeLog<FileBulk.Outgoing>()
    let reader = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: read, start: .init(kind: "read.v1", input: ["path": "/file"])))) {
      if case let .frame(frame) = $0 { readFrames.values.withLock { $0.append(frame) } }
    })
    let metadata = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: stat, start: .init(kind: "stat.v1", input: ["path": "/file"])))) {
      if case let .frame(frame) = $0 { statFrames.values.withLock { $0.append(frame) } }
    })
    let exec = MachineExec(id: "runtime-exec", operation: UUID(), createdAt: fixedDate, group: .shared, argv: ["true"])
    _ = try await space.worker.call(id) { try $0.reserve(exec) }
    let stream = try #require(space.worker.attach(ExecStream.self, to: id, opening: .init(exec: exec, nonce: UUID())) { _ in })
    await space.drain()
    #expect(box.frames.values.withLock { $0.count } == 1)
    #expect(space.worker.cell(id).fileOperation(read)?.dispatched == false)
    #expect(space.worker.cell(id).operation(exec.id)?.dispatched == false)

    var limits = OperationLimits()
    limits.leaseMs = 9000; limits.pollHoldMs = 5000; limits.pollBytes = 100; limits.resultBytes = 32
    let original = ComputerKindSchemas.exec
    let execKind = KindDescriptor(original.name, inputSchema: original.inputSchema, resultSchema: original.resultSchema, inputChannels: original.inputChannels, outputChannels: [.init("stdout", windowBytes: 23), .init("stderr", windowBytes: 17)])
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [ComputerKindSchemas.read, ComputerKindSchemas.stat, execKind])
    try await box.answer(.init(tag: .describe, answer: .description(description)), space: space, id: id)
    #expect(space.worker.cell(id).fileOperation(read)?.dispatched == true)
    #expect(space.worker.cell(id).fileOperation(stat)?.dispatched == true)
    #expect(space.worker.cell(id).operation(exec.id)?.dispatched == true)
    #expect(readFrames.values.withLock { $0.contains { if case .started = $0 { true } else { false } } })

    for operation in [read, exec.operation] {
      try await box.answer(.init(tag: .operation(operation, .start), answer: .snapshot(.init(snapshot: Self.snapshot(operation)))), space: space, id: id)
    }
    #expect(space.worker.cell(id).operation(exec.id)?.state == "running")
    #expect(space.worker.cell(id).fileOperation(read)?.state == "running")
    let polls = box.frames.values.withLock { $0.compactMap { frame -> (UUID, String?, Int, Int)? in
      guard case let .poll(operation, channel, _, hold, _, limit) = frame.exchange else { return nil }
      return (operation, channel, hold, limit)
    } }
    #expect(polls.contains { $0.0 == read && $0.1 == "data" && $0.2 == 3000 && $0.3 == limits.filePieceBytes })
    #expect(polls.contains { $0.0 == exec.operation && $0.1 == "stdout" && $0.3 == 23 })
    #expect(polls.contains { $0.0 == exec.operation && $0.1 == "stderr" && $0.3 == 17 })
    let pointer = try #require(space.machineBuffers.put(payload: .init(data: Data([1, 2, 3])), operation: read, channel: "data", from: 0))
    let output = OperationSnapshot(operation: read, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false, channel: "data", from: .init(rawValue: 0), through: .init(rawValue: 3))
    try await box.answer(.init(tag: .operation(read, .output("data")), answer: .snapshot(.init(snapshot: output, output: pointer))), space: space, id: id)
    reader.send(.want(channel: "data", offset: 3))
    await space.drain()
    #expect(space.worker.cell(id).fileOperation(read)?.offsets["data"] == 3)
    _ = try await space.worker.call(id) { $0.nextWake() }
    #expect(try await space.space.machineV2PresenceEvidence(machine.rawValue, group: .shared)?.state == .attached)
    let tooLarge = OperationSnapshot(operation: stat, verdict: .init(.completed, result: ["value": .string(String(repeating: "x", count: 40))]), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
    try await box.answer(.init(tag: .operation(stat, .start), answer: .snapshot(.init(snapshot: tooLarge))), space: space, id: id)
    #expect(statFrames.values.withLock { $0.contains { frame in
      if case let .finished(.failure(.operation(error))) = frame { return error.code == .resultTooLarge }
      return false
    } })

    let replacement = try await RuntimeBox.attach(space, id: id)
    #expect(replacement.frames.values.withLock { $0.first?.tag } == .describe)
    #expect(replacement.frames.values.withLock { $0.contains { if case .poll = $0.exchange { true } else { false } } })
    #expect(try await space.space.machineDescription(machine)?.instance == description.instance)
    reader.close(); metadata.close(); stream.close(); box.peer.close(); replacement.peer.close()
    try await space.close()
  }

  @Test(arguments: ["description", "snapshot", "input", "box", "transport", "preparation"])
  func leaseRenewalUsesTheLastAcceptedDurationForEveryPositiveAnswer(answerClass: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "runtime").machine.id.rawValue
    let id = MachineCell.ID(machine)
    let box = try await RuntimeBox.attach(space, id: id)
    var limits = OperationLimits()
    limits.leaseMs = 9000; limits.pollHoldMs = 3000
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [])
    try await box.answer(.init(tag: .describe, answer: .description(description)), space: space, id: id)
    try await space.worker.call(id) { cell in
      var p = cell.presence
      p.lease = cell.now + 1
      try cell.save(p)
    }
    let operation = UUID()
    let answer: BoxAnswer = switch answerClass {
    case "description": .description(description)
    case "snapshot": .snapshot(.init(snapshot: Self.snapshot(operation)))
    case "input": .input(.init(acceptedThrough: .init(rawValue: 0), end: false, blocked: false))
    case "box": .box(.init(.unknownOperation))
    case "transport": .transport(.init(.transport))
    case "preparation": .preparation(.init(.invalidInput))
    default: preconditionFailure()
    }
    try await box.answer(.init(tag: .operation(operation, .control), answer: answer), space: space, id: id)
    try await box.answer(.init(tag: .operation(operation, .control), answer: answer), space: space, id: id)
    try await space.worker.call(id) { cell in
      var p = cell.presence
      p.describeAt = cell.now; p.describeDeadline = nil
      try cell.save(p)
      try cell.answer(.init(tag: .operation(operation, .control), answer: answer), from: cell.box!)
    }
    await space.drain()
    #expect(box.frames.values.withLock { $0.last?.tag } == .describe)
    let duration = try await space.worker.call(id) { $0.presence.lease! - $0.now }
    #expect(duration == (["transport", "preparation"].contains(answerClass) ? 1 : 9000))
    try await space.worker.call(id) { cell in
      var p = cell.presence
      p.lease = cell.now
      try cell.save(p)
      try cell.wake()
    }
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(try await space.space.machineDescription(.init(rawValue: machine)) == nil)
    #expect(space.worker.cell(id).machineDescription?.instance == description.instance)
    box.peer.close()
    try await space.close()
  }

  @Test func sameTimeDescribeUpdatesMetadata() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "describe-writes").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let box = try await RuntimeBox.attach(space, id: id)
    let initial = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.stat])
    try await box.answer(.init(tag: .describe, answer: .description(initial)), space: space, id: id)
    let updated = MachineDescription(instance: UUID(), acceptingStarts: false, limits: .init(), kinds: [ComputerKindSchemas.stat])
    try await box.answer(.init(tag: .describe, answer: .description(updated)), space: space, id: id)
    #expect(try await space.space.machineDescription(machine)?.instance == updated.instance)
    #expect(try await space.space.machineDescription(machine)?.acceptingStarts == false)
    box.peer.close()
    try await space.close()
  }

  @Test func aDescriptionAdvertisingMoreThanFourMebibytePiecesIsRefused() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "piece-too-big").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let box = try await RuntimeBox.attach(space, id: id)
    var limits = OperationLimits()
    limits.filePieceBytes = 1024 * 1024 * 1024
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [])
    try await box.answer(.init(tag: .describe, answer: .description(description)), space: space, id: id)
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(space.worker.cell(id).presence.filePieceBytes == nil)
    #expect(try await space.space.machineDescription(machine) == nil)
    box.peer.close()
    try await space.close()
  }

  @Test func aPresenceFromBeforeThePieceColumnServesAFileAtSixtyFourKiB() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "old-piece").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let box = try await RuntimeBox.attach(space, id: id)
    var limits = OperationLimits(); limits.leaseMs = 9000; limits.pollHoldMs = 3000
    let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: limits, kinds: [ComputerKindSchemas.read])
    try await box.answer(.init(tag: .describe, answer: .description(description)), space: space, id: id)
    try await space.space.plant("UPDATE machine_presence SET filePieceBytes = NULL WHERE owner = ?", arguments: [machine.rawValue])
    #expect(space.worker.cell(id).presence.filePieceBytes == nil)
    #expect(try await space.worker.call(id) { $0.presence.runtime?.filePieceBytes } == 64 * 1024)
    let read = UUID()
    let reader = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: read, start: .init(kind: "read.v1", input: ["path": "/file"])))) { _ in })
    await space.drain()
    try await box.answer(.init(tag: .operation(read, .start), answer: .snapshot(.init(snapshot: Self.snapshot(read)))), space: space, id: id)
    let polls = box.frames.values.withLock { $0.compactMap { frame -> (UUID, String?, Int)? in
      guard case let .poll(operation, channel, _, _, _, limit) = frame.exchange else { return nil }
      return (operation, channel, limit)
    } }
    #expect(polls.contains { $0.0 == read && $0.1 == "data" && $0.2 == 64 * 1024 })
    reader.close(); box.peer.close()
    try await space.close()
  }

  @Test func wakePersistsInitialPresenceAndClearsStaleDeadlinesAndLeases() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "wake-writes").machine.id.rawValue
    let id = MachineCell.ID(machine)
    try await space.worker.call(id) { try $0.wake() }
    await space.drain()
    #expect(space.worker.cell(id).presence.state == "lost")
    try await space.worker.call(id) { try $0.wake() }
    await space.drain()
    try await space.worker.call(id) { cell in
      var p = cell.presence
      p.describeAt = cell.now + 1000; p.describeDeadline = cell.now + 5000
      try cell.save(p)
    }
    try await space.worker.call(id) { try $0.wake() }
    await space.drain()
    #expect(space.worker.cell(id).presence.describeAt == nil)
    #expect(space.worker.cell(id).presence.describeDeadline == nil)
    try await space.worker.call(id) { cell in
      var p = cell.presence
      p.state = "attached"; p.lease = cell.now
      try cell.save(p)
    }
    try await space.worker.call(id) { try $0.wake() }
    await space.drain()
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(space.worker.cell(id).presence.lease == nil)
    try await space.close()
  }

  private static func snapshot(_ operation: UUID) -> OperationSnapshot {
    OperationSnapshot(operation: operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)
  }
}

private struct RuntimeBox {
  let peer: Peer<BoxSocket>
  let frames: RuntimeLog<BoxSocket.Outgoing>

  static func attach(_ space: MachineCellTestSpace, id: MachineCell.ID) async throws -> Self {
    let pubkey = try await space.space.addMachineTestKey(id.key)
    let frames = RuntimeLog<BoxSocket.Outgoing>()
    let peer = try #require(space.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { frames.values.withLock { $0.append(frame) } }
    })
    await space.drain()
    #expect(frames.values.withLock { $0.first?.tag } == .describe)
    return Self(peer: peer, frames: frames)
  }

  func answer(_ frame: BoxSocket.Incoming, space: MachineCellTestSpace, id: MachineCell.ID) async throws {
    try await space.worker.call(id) { cell in try cell.answer(frame, from: cell.box!) }
    await space.drain()
  }
}

private final class RuntimeLog<Event: Sendable>: Sendable {
  let values = Mutex<[Event]>([])
}
