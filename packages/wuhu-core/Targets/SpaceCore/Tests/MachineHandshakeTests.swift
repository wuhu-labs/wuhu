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

@Suite(.deterministicDependencies) struct MachineHandshakeTests {
  @Test func unansweredFirstSocketNeverAttachesOrTakesAnExec() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "silent").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let box = try await HandshakeBox.attach(space, id: id)
    #expect(space.worker.cell(id).presence.lease == nil)
    #expect(try await space.space.machineV2PresenceEvidence(machine.rawValue, group: .shared)?.state == .lost)
    let before = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(before.request.id)?.diagnostic?.code == .machineUnavailable)
    #expect(box.frames.value.withLock { $0.count } == 1)
    try await expireNextWake(space, id: id)
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(space.worker.cell(id).presence.describeDeadline == nil)
    #expect(box.closed.value.withLock { $0 })
    let after = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(after.request.id)?.diagnostic?.code == .machineUnavailable)
    #expect(space.worker.cell(id).operation(after.request.id)?.dispatched == false)
    before.peer.close(); after.peer.close()
    try await space.close()
  }

  @Test func quickReconnectWaitsForItsOwnDescriptionThenExecSucceeds() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "reconnect").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let old = try await HandshakeBox.attach(space, id: id)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    let observed = try #require(try await space.space.machineV2PresenceEvidence(machine.rawValue, group: .shared)).observedAt
    let lease = space.worker.cell(id).presence.lease
    space.advance(by: 1000)
    let replacement = try await HandshakeBox.attach(space, id: id)
    #expect(old.closed.value.withLock { $0 })
    #expect(space.worker.cell(id).presence.lease == lease)
    let pending = try #require(try await space.space.machineV2PresenceEvidence(machine.rawValue, group: .shared))
    #expect(pending.state == .attached && pending.observedAt == observed)
    let exec = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(exec.request.id)?.diagnostic == nil)
    #expect(space.worker.cell(id).operation(exec.request.id)?.dispatched == false)
    #expect(replacement.frames.value.withLock { $0.count } == 1)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    #expect(space.worker.cell(id).operation(exec.request.id)?.dispatched == false)
    replacement.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    #expect(space.worker.cell(id).operation(exec.request.id)?.dispatched == true)
    #expect(replacement.frames.value.withLock { $0.filter { $0.tag == .operation(exec.request.operation, .start) }.count } == 1)
    let completed = OperationSnapshot(operation: exec.request.operation, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]), terminalToken: UUID(), finalOffsets: ["stdout": .init(rawValue: 0), "stderr": .init(rawValue: 0)], outputConsumed: false)
    replacement.peer.send(.init(tag: .operation(exec.request.operation, .start), answer: .snapshot(.init(snapshot: completed))))
    await space.drain()
    #expect(exec.frames.value.withLock { $0.contains { if case let .exit(end) = $0 { end.error == nil && end.status == .exited(code: 0) } else { false } } })
    #expect(space.worker.cell(id).presence.lease == lease! + 1000)
    exec.peer.close(); replacement.peer.close()
    try await space.close()
  }

  @Test(arguments: [false, true], [false, true]) func reconnectDeadlineLosesWaitingAndOutstandingExecs(replaceAgain: Bool, lateAnswer: Bool) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "deadline").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let old = try await HandshakeBox.attach(space, id: id)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    let outstanding = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(outstanding.request.id)?.dispatched == true)
    let lease = space.worker.cell(id).presence.lease
    space.advance(by: 1000)
    var replacement = try await HandshakeBox.attach(space, id: id)
    let waiting = try await attachExec(space, id: id)
    if replaceAgain {
      space.advance(by: 1000)
      replacement = try await HandshakeBox.attach(space, id: id)
    }
    #expect(space.worker.cell(id).presence.lease == lease)
    replacement.peer.send(.init(tag: .describe, answer: .transport(.init(.transport))))
    await space.drain()
    #expect(space.worker.cell(id).presence.lease == lease)
    #expect(replacement.frames.value.withLock { $0.count } == 1)
    if lateAnswer {
      let deadline = try #require(space.worker.cell(id).presence.describeDeadline)
      let now = try await space.worker.call(id) { $0.now }
      space.advance(by: deadline - now)
      replacement.peer.send(.init(tag: .describe, answer: .description(description)))
      await space.drain()
    } else { try await expireNextWake(space, id: id) }
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(replacement.closed.value.withLock { $0 })
    for exec in [outstanding, waiting] {
      #expect(space.worker.cell(id).operation(exec.request.id)?.diagnostic?.details?.object?["reason"] == "leaseSilence")
      #expect(space.worker.cell(id).operation(exec.request.id)?.terminal == true)
      exec.peer.close()
    }
    let recovery = try await HandshakeBox.attach(space, id: id)
    let refused = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(refused.request.id)?.diagnostic?.code == .machineUnavailable)
    #expect(recovery.frames.value.withLock { $0.count } == 1)
    refused.peer.close(); recovery.peer.close()
    try await space.close()
  }

  @Test(arguments: [0, 1000]) func expiredLeaseIsSettledBeforeTheFreshHandshake(overdue: Int64) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "expired").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let old = try await HandshakeBox.attach(space, id: id)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    let outstanding = try await attachExec(space, id: id)
    let file = try await attachFile(space, id: id)
    #expect(space.worker.cell(id).operation(outstanding.request.id)?.dispatched == true)
    #expect(space.worker.cell(id).fileOperation(file.operation)?.dispatched == true)
    let lease = try #require(space.worker.cell(id).presence.lease)
    let now = try await space.worker.call(id) { $0.now }
    space.advance(by: lease - now + overdue)
    let replacement = try await HandshakeBox.attach(space, id: id)
    #expect(space.worker.cell(id).presence.state == "lost")
    #expect(space.worker.cell(id).presence.lease == nil)
    #expect(old.closed.value.withLock { $0 })
    #expect(!replacement.closed.value.withLock { $0 })
    #expect(space.worker.cell(id).operation(outstanding.request.id)?.diagnostic?.details?.object?["reason"] == "leaseSilence")
    #expect(space.worker.cell(id).fileOperation(file.operation) == nil)
    #expect(file.frames.value.withLock { $0.contains { if case .finished(.failure(.rangeLost(offset: 0))) = $0 { true } else { false } } })
    let refused = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(refused.request.id)?.diagnostic?.code == .machineUnavailable)
    try await space.worker.call(id) { try $0.wake() }
    await space.drain()
    #expect(!replacement.closed.value.withLock { $0 })
    replacement.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    #expect(space.worker.cell(id).presence.state == "attached")
    #expect(!replacement.closed.value.withLock { $0 })
    let fresh = try await attachExec(space, id: id)
    #expect(space.worker.cell(id).operation(fresh.request.id)?.dispatched == true)
    outstanding.peer.close(); file.peer.close(); refused.peer.close(); fresh.peer.close(); replacement.peer.close()
    try await space.close()
  }

  @Test func fileFailedDuringReconnectSendsItsStopOnlyAfterDescribe() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "file-stop").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let old = try await HandshakeBox.attach(space, id: id)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    let file = try await attachFile(space, id: id)
    #expect(space.worker.cell(id).fileOperation(file.operation)?.dispatched == true)
    let replacement = try await HandshakeBox.attach(space, id: id)
    file.peer.send(.cancel)
    await space.drain()
    #expect(file.frames.value.withLock { $0.contains { if case let .finished(.failure(.operation(error))) = $0 { error.code == .requestCancelled } else { false } } })
    #expect(space.worker.cell(id).fileOperation(file.operation)?.state == "stopping")
    #expect(replacement.frames.value.withLock { $0.count } == 1)
    replacement.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    #expect(replacement.frames.value.withLock { frames in
      frames.contains { frame in
        if case let .stop(operation, reason) = frame.exchange { operation == file.operation && reason == "callerCancelled" } else { false }
      }
    })
    #expect(replacement.frames.value.withLock { !$0.contains { if case .startFile = $0.exchange { true } else { false } } })
    replacement.peer.close()
    try await space.close()
  }

  @Test func lostMachineRefusesFileWhileNewSocketIsHandshaking() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "file-lost").machine.id
    let id = MachineCell.ID(machine.rawValue)
    let old = try await HandshakeBox.attach(space, id: id)
    old.peer.send(.init(tag: .describe, answer: .description(description)))
    await space.drain()
    let silent = try await HandshakeBox.attach(space, id: id)
    try await expireNextWake(space, id: id)
    #expect(silent.closed.value.withLock { $0 })
    let box = try await HandshakeBox.attach(space, id: id)
    #expect(space.worker.cell(id).presence.describeDeadline != nil)
    let file = try await attachFile(space, id: id)
    #expect(file.frames.value.withLock { $0.contains { if case let .finished(.failure(.operation(error))) = $0 { error.code == .machineUnavailable } else { false } } })
    #expect(file.closed.value.withLock { $0 })
    #expect(space.worker.cell(id).fileOperation(file.operation) == nil)
    #expect(box.frames.value.withLock { $0.count } == 1)
    box.peer.close()
    try await space.close()
  }

  private func attachFile(_ space: MachineCellTestSpace, id: MachineCell.ID) async throws -> HandshakeFile {
    let operation = UUID()
    let frames = HandshakeLog<[FileBulk.Outgoing]>([])
    let closed = HandshakeLog(false)
    let peer = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: operation, start: .init(kind: "read.v1", input: ["path": "/file"])))) {
      switch $0 {
      case let .frame(frame): frames.value.withLock { $0.append(frame) }
      case .closed: closed.value.withLock { $0 = true }
      }
    })
    await space.drain()
    return HandshakeFile(operation: operation, peer: peer, frames: frames, closed: closed)
  }

  private var description: MachineDescription {
    MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, ComputerKindSchemas.read])
  }

  private func expireNextWake(_ space: MachineCellTestSpace, id: MachineCell.ID) async throws {
    // Existing operation polls may wake before the handshake deadline.
    let deadline = try #require(space.worker.cell(id).presence.describeDeadline)
    while let next = space.worker.cell(id).nextWake(), next.milliseconds <= deadline {
      let now = try await space.worker.call(id) { $0.now }
      space.advance(by: next.milliseconds - now)
      try await space.worker.call(id) { try $0.wake() }
      await space.drain()
    }
  }

  private func attachExec(_ space: MachineCellTestSpace, id: MachineCell.ID) async throws -> HandshakeExec {
    let request = MachineExec(id: UUID().uuidString, operation: UUID(), createdAt: fixedDate, group: .shared, argv: ["true"])
    _ = try await space.worker.call(id) { try $0.reserve(request) }
    let frames = HandshakeLog<[ExecStream.Outgoing]>([])
    let peer = try #require(space.worker.attach(ExecStream.self, to: id, opening: .init(exec: request, nonce: UUID())) {
      if case let .frame(frame) = $0 { frames.value.withLock { $0.append(frame) } }
    })
    await space.drain()
    return HandshakeExec(request: request, peer: peer, frames: frames)
  }
}

private struct HandshakeBox {
  let peer: Peer<BoxSocket>
  let frames: HandshakeLog<[BoxSocket.Outgoing]>
  let closed: HandshakeLog<Bool>

  static func attach(_ space: MachineCellTestSpace, id: MachineCell.ID) async throws -> Self {
    let pubkey = try await space.space.addMachineTestKey(id.key)
    let frames = HandshakeLog<[BoxSocket.Outgoing]>([])
    let closed = HandshakeLog(false)
    let peer = try #require(space.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      switch $0 {
      case let .frame(frame): frames.value.withLock { $0.append(frame) }
      case .closed: closed.value.withLock { $0 = true }
      }
    })
    await space.drain()
    #expect(frames.value.withLock { $0.count == 1 && $0.first?.tag == .describe })
    return Self(peer: peer, frames: frames, closed: closed)
  }
}

private struct HandshakeExec {
  let request: MachineExec
  let peer: Peer<ExecStream>
  let frames: HandshakeLog<[ExecStream.Outgoing]>
}

private final class HandshakeLog<Value: Sendable>: Sendable {
  let value: Mutex<Value>

  init(_ value: Value) { self.value = Mutex(value) }
}

private struct HandshakeFile {
  let operation: UUID
  let peer: Peer<FileBulk>
  let frames: HandshakeLog<[FileBulk.Outgoing]>
  let closed: HandshakeLog<Bool>
}
