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

@Suite(.deterministicDependencies) struct MachineAdmissionTests {
  @Test(arguments: [false, true]) func inputFileAndExecAdmissionsShareTheTunnelBudget(_ execFirst: Bool) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "admission").machine.id.rawValue
    let id = MachineCell.ID(machine)
    let pubkey = try await space.space.addMachineTestKey(machine)
    let output = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let box = try #require(space.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { output.continuation.yield(frame) }
      else { output.continuation.finish() }
    })
    defer { box.close() }
    var frames = output.stream.makeAsyncIterator()
    #expect(try #require(await frames.next()).tag == .describe)
    try await space.worker.call(id) { cell in
      try cell.answer(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, ComputerKindSchemas.stagedWrite]))), from: cell.box!)
    }
    let exec = MachineExec(id: "exec", operation: UUID(), createdAt: Date(), group: .shared, argv: ["true"])
    var execution: Peer<ExecStream>?
    if execFirst {
      execution = try await attachExec(exec, space: space, id: id)
      while let frame = await frames.next() {
        if frame.tag == .operation(exec.operation, .start) { break }
      }
      #expect(space.worker.cell(id).operation(exec.id)?.dispatched == true)
    }
    defer { execution?.close() }
    let acceptedFiles = execFirst ? 13 : 15
    var files: [Peer<FileBulk>] = []
    defer { for file in files { file.close() } }
    for index in 0 ..< acceptedFiles {
      let operation = UUID()
      let callerOutput = AsyncStream<FileBulk.Outgoing>.makeStream()
      let caller = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: operation, start: .init(kind: "stagedWrite.v1", input: ["path": .string("/file-\(index)"), "replace": false])))) {
        if case let .frame(frame) = $0 { callerOutput.continuation.yield(frame) }
        else { callerOutput.continuation.finish() }
      })
      files.append(caller)
      var iterator = callerOutput.stream.makeAsyncIterator()
      guard case .started = try #require(await iterator.next()) else { Issue.record("Expected admitted file"); return }
      #expect(space.worker.cell(id).fileOperation(operation)?.dispatched == true)
    }
    #expect(space.worker.cell(id).dispatchedFileStreams == acceptedFiles * 2)
    if execFirst {
      let operation = UUID()
      let refusedOutput = AsyncStream<FileBulk.Outgoing>.makeStream()
      let refused = try #require(space.worker.attach(FileBulk.self, to: id, opening: .init(request: .init(operation: operation, start: .init(kind: "stagedWrite.v1", input: ["path": "/overflow", "replace": false])))) {
        if case let .frame(frame) = $0 { refusedOutput.continuation.yield(frame) }
        else { refusedOutput.continuation.finish() }
      })
      files.append(refused)
      var iterator = refusedOutput.stream.makeAsyncIterator()
      guard case let .finished(.failure(.operation(error))) = try #require(await iterator.next()) else { Issue.record("Expected file capacity refusal"); return }
      #expect(error.code == .capacityExceeded)
      #expect(space.worker.cell(id).fileOperation(operation) == nil)
    } else {
      execution = try await attachExec(exec, space: space, id: id)
      await space.drain()
      let row = try #require(space.worker.cell(id).operation(exec.id))
      #expect(row.dispatched == false)
      #expect(row.diagnostic?.code == .capacityExceeded)
    }
    #expect(space.worker.cell(id).dispatchedFileStreams == acceptedFiles * 2)
    try await space.close()
  }

  private func attachExec(_ request: MachineExec, space: MachineCellTestSpace, id: MachineCell.ID) async throws -> Peer<ExecStream> {
    _ = try await space.worker.call(id) { try $0.reserve(request) }
    return try #require(space.worker.attach(ExecStream.self, to: id, opening: .init(exec: request, nonce: UUID())) { _ in })
  }
}
