import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import enum JSONValue.JSONValue
import OperationProtocol
import Scratch
@testable import SpaceCore
import StructuredQueries
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineFileCellTests {
  @Test func onlyTheCallersWantedOffsetAdvancesConsumptionAndReleasesBytes() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    let poll = try await box.next(operation, .output("data"))
    expectPoll(poll, channel: "data", after: 0)
    let bytes = Data(String(repeating: "cell-file-payload-marker", count: 2000).utf8)
    let pointer = try box.output(operation, payload: .init(data: bytes), channel: "data", from: 0)
    #expect(try await caller.output() == pointer)
    expectPoll(try await box.next(operation, .output("data")), channel: "data", after: UInt64(bytes.count))
    let first = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    #expect(first.offsets["data"] == 0)
    #expect(first.offered["data"] == UInt64(bytes.count))
    #expect(first.snapshot?.payload == nil)
    await space.drain()
    #expect(space.machineBuffers.payload(pointer)?.data == bytes)
    #expect(box.outputPolls(operation, channel: "data") == [0, UInt64(bytes.count)])
    let persisted = try await space.writer.read { db in
      try String.fetchOne(db, sql: "SELECT request || COALESCE(snapshot, '') FROM machine_file_operations WHERE id = ?", arguments: [operation.uuidString.lowercased()])!
    }
    #expect(persisted.utf8.count < 4096)
    #expect(!persisted.contains("cell-file-payload-marker"))
    #expect(!persisted.contains(bytes.base64EncodedString()))
    #expect(try await space.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM machine_operations") } == 0)

    caller.peer.send(.want(channel: "data", offset: 7))
    let suffix = try await caller.output()
    #expect(suffix.from == 7 && suffix.through == UInt64(bytes.count))
    await space.drain()
    #expect(space.machineBuffers.payload(suffix)?.data == Data(bytes.dropFirst(7)))
    await expectRetained(space, operation: operation, count: bytes.count - 7)
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == bytes.count - 7)
    #expect(box.outputPolls(operation, channel: "data") == [0, UInt64(bytes.count)])
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation)?.offsets["data"] == 7)

    caller.peer.send(.want(channel: "data", offset: UInt64(bytes.count)))
    #expect(box.outputPolls(operation, channel: "data") == [0, UInt64(bytes.count)])
    await expectRetained(space, operation: operation, count: 0)
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == 0)
    caller.peer.close(); box.peer.close()
    try await space.close()
  }

  @Test func listOffsetsCountRecordsAndCompletionWaitsForExplicitConsumption() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation, kind: "list.v1")
    try await box.start(operation)
    expectPoll(try await box.next(operation, .output("entries")), channel: "entries", after: 0)
    let records = ChannelPayload(records: [["name": "first-long-entry"], ["name": "second-long-entry"]])
    _ = try box.output(operation, payload: records, channel: "entries", from: 0, completed: true)
    let pointer = try await caller.output()
    #expect(pointer.through == 2)
    #expect(records.byteCount > records.count)
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation)?.delivered == false)
    #expect(box.terminalPolls(operation).isEmpty)
    caller.peer.send(.want(channel: "entries", offset: 1))
    let suffix = try await caller.output()
    #expect(suffix.from == 1 && suffix.through == 2)
    await space.drain()
    #expect(space.machineBuffers.payload(suffix) == records.slice(1 ..< 2))
    #expect(box.outputPolls(operation, channel: "entries") == [0])
    caller.peer.send(.want(channel: "entries", offset: 2))
    guard case .success = try await caller.finished() else { Issue.record("Expected list completion"); return }
    let terminal = try await box.next(operation, .terminal("entries"))
    guard case let .poll(_, channel, after, _, token, _) = terminal.exchange else { Issue.record("Expected terminal poll"); return }
    #expect(channel == "entries" && after == 2 && token != nil)
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "entries") == 0)
    #expect(box.stops(operation).isEmpty)
    let consumed = OperationSnapshot(operation: operation, verdict: .init(.completed, result: [:]), terminalToken: token, finalOffsets: ["entries": .init(rawValue: 2)], outputConsumed: true)
    try await box.answer(.init(tag: terminal.tag, answer: .snapshot(.init(snapshot: consumed))))
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    box.peer.close()
    try await space.close()
  }

  @Test func closingAnUnfinishedCallerStopsWithCallerGone() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    _ = try box.output(operation, payload: .init(data: Data([1, 2, 3])), channel: "data", from: 0)
    _ = try await caller.output()
    caller.peer.close()
    let stop = try await box.next(operation, .stop)
    guard case let .stop(stopped, reason) = stop.exchange else { Issue.record("Expected stop"); return }
    #expect(stopped == operation && reason == "callerGone")
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == 0)
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation)?.stop == "callerGone")
    #expect(box.starts(operation).count == 1)
    #expect(box.terminalPolls(operation).isEmpty)
    try await box.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    box.peer.close()
    try await space.close()
  }

  @Test(arguments: ["offsetExpired", "missingPointer", "foreignPointer", "unknownOperation"])
  func lostReadRangesAreTypedAndNeverRestarted(reason: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    let originalHistory = box.history
    var expected: UInt64 = 0
    switch reason {
    case "offsetExpired":
      _ = try box.output(operation, payload: .init(data: Data([1, 2, 3, 4])), channel: "data", from: 0)
      _ = try await caller.output()
      caller.peer.send(.want(channel: "data", offset: 4))
      expectPoll(try await box.next(operation, .output("data")), channel: "data", after: 4)
      expected = 4
      box.peer.send(.init(tag: .operation(operation, .output("data")), answer: .box(.init(.offsetExpired))))
    case "unknownOperation":
      box = try await FileTestBox.attach(space, machine: machine)
      _ = try await box.next(operation, .output("data"))
      #expect(box.starts(operation).isEmpty)
      box.peer.send(.init(tag: .operation(operation, .output("data")), answer: .box(.init(.unknownOperation))))
    case "missingPointer", "foreignPointer":
      let pointer = MachinePointer(worker: reason == "foreignPointer" ? "another-worker" : space.machineBuffers.worker, operation: operation, channel: "data", from: 0, through: 4)
      box.peer.send(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation, channel: "data", from: 0, through: 4), output: pointer))))
    default: preconditionFailure("Unknown fixture")
    }
    guard case let .failure(.rangeLost(offset)) = try await caller.finished() else { Issue.record("Expected typed rangeLost"); return }
    #expect(offset == expected)
    let row = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    #expect(row.delivered && row.failure != nil)
    expectStop(try await box.next(operation, .stop), operation: operation, reason: "rangeLost")
    #expect(originalHistory.frames.withLock { $0.filter { $0.tag == .operation(operation, .start) }.count } == 1)
    #expect(box.stops(operation).count == 1)
    box.peer.close()
    try await space.close()
  }

  @Test func oversizedMetadataResultIsRejectedBeforePersistence() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation, kind: "mkdir.v1")
    try await box.start(operation)
    _ = try await box.next(operation, .control)
    let snapshot = OperationSnapshot(operation: operation, verdict: .init(.completed, result: .string(String(repeating: "x", count: 65537))), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
    try await box.answer(.init(tag: .operation(operation, .control), answer: .snapshot(.init(snapshot: snapshot))))
    guard case let .failure(.operation(error)) = try await caller.finished() else { Issue.record("Expected bounded metadata failure"); return }
    #expect(error.code == .resultTooLarge)
    let row = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    #expect(row.snapshot?.verdict == nil)
    expectStop(try await box.next(operation, .stop), operation: operation, reason: "resultTooLarge")
    box.peer.close()
    try await space.close()
  }

  @Test func boxRestartMakesAnUnreportedMutationOutcomeUnknown() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation, kind: "mkdir.v1")
    try await box.start(operation)
    let originalHistory = box.history
    box = try await FileTestBox.attach(space, machine: machine)
    _ = try await box.next(operation, .control)
    box.peer.send(.init(tag: .operation(operation, .control), answer: .box(.init(.unknownOperation))))
    guard case .failure(.outcomeUnknown) = try await caller.finished() else { Issue.record("Expected outcomeUnknown"); return }
    #expect(originalHistory.frames.withLock { $0.filter { $0.tag == .operation(operation, .start) }.count } == 1)
    #expect(box.starts(operation).isEmpty)
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation)?.delivered == true)
    expectStop(try await box.next(operation, .stop), operation: operation, reason: "outcomeUnknown")
    box.peer.close()
    try await space.close()
  }

  @Test func workerRollLosesTheOldRangeAndOnlyTheCallerCanRestartItsOriginalRead() async throws {
    let folder = try ScratchFolder("file-cell-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try await MachineCellTestSpace.open(file: file), new = try await MachineCellTestSpace.open(file: file)
    let machine = try await old.addMachineV2(name: "files").machine.id.rawValue
    var first = try await FileTestBox.attach(old, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(old, machine: machine, operation: operation)
    try await first.start(operation)
    _ = try await first.next(operation, .output("data"))
    let original = try first.output(operation, payload: .init(data: Data([1, 2, 3, 4])), channel: "data", from: 0)
    _ = try await caller.output()
    expectPoll(try await first.next(operation, .output("data")), channel: "data", after: 4)
    caller.peer.send(.want(channel: "data", offset: 2))
    let unconsumed = try await caller.output()
    #expect(unconsumed.from == 2 && unconsumed.through == 4)
    await new.drain()
    #expect(new.machineBuffers.payload(unconsumed) == nil)
    #expect(first.outputPolls(operation, channel: "data") == [0, 4])
    await old.stopWorker()
    #expect(caller.closed.value.withLock { $0 })
    let fresh = UUID()
    #expect(fresh != operation)
    var restarted = try FileTestCaller.attach(new, machine: machine, operation: fresh, input: ["path": "/file", "offset": 0])
    try await expectFileCreated(new, machine: machine, operation: fresh)
    let waiting = try #require(new.worker.cell(MachineCell.ID(machine)).fileOperation(fresh))
    #expect(!waiting.dispatched && waiting.failure == nil && !waiting.delivered)
    #expect(restarted.history.finishedCount == 0)
    #expect(!restarted.closed.value.withLock { $0 })
    var replacement = try await FileTestBox.attach(new, machine: machine)
    let lost = try #require(new.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    guard case let .rangeLost(offset)? = lost.failure else { Issue.record("Expected rangeLost after roll"); return }
    #expect(offset == 2)
    #expect(lost.delivered)
    expectStop(try await replacement.next(operation, .stop), operation: operation, reason: "rangeLost")
    await new.drain()
    #expect(new.machineBuffers.payload(original) == nil)
    #expect(replacement.starts(operation).isEmpty)
    try await replacement.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(new.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)

    let start = try await replacement.start(fresh)
    #expect(start.input.object?["offset"] == 0)
    #expect(start.input.object?["ifMatch"] == nil)
    expectPoll(try await replacement.next(fresh, .output("data")), channel: "data", after: 0)
    let replacementBytes = Data([5, 6, 7, 8])
    _ = try replacement.output(fresh, payload: .init(data: replacementBytes), channel: "data", from: 0, completed: true)
    let received = try await restarted.output()
    await new.drain()
    #expect(new.machineBuffers.payload(received)?.data == replacementBytes)
    restarted.peer.send(.want(channel: "data", offset: UInt64(replacementBytes.count)))
    guard case .success = try await restarted.finished() else { Issue.record("Expected a complete fresh read from the original offset"); return }
    #expect(replacement.starts(operation).isEmpty)
    #expect(replacement.starts(fresh).count == 1)
    replacement.peer.close()
    try await old.close()
    try await new.close()
  }

  @Test(arguments: [false, true])
  func delayedOverlappingOutputDoesNotInvalidateTheWantedCachedSuffix(consumerReachedOffer: Bool) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    let initial = consumerReachedOffer ? Data([1, 2]) : Data([1, 2, 3, 4])
    let original = try box.output(operation, payload: .init(data: initial), channel: "data", from: 0)
    _ = try await caller.output()
    expectPoll(try await box.next(operation, .output("data")), channel: "data", after: UInt64(initial.count))
    caller.peer.send(.want(channel: "data", offset: 2))
    let suffix: MachinePointer
    if consumerReachedOffer {
      await expectRetained(space, operation: operation, count: 0)
      _ = try #require(space.machineBuffers.put(Data([1, 2, 3, 4]), operation: operation, channel: "data", from: 0))
      suffix = try #require(space.machineBuffers.get(operation, channel: "data", from: 2))
    } else {
      suffix = try await caller.output()
      await expectRetained(space, operation: operation, count: 2)
    }
    #expect(suffix.from == 2 && suffix.through == 4)
    await space.drain()
    #expect(space.machineBuffers.payload(original) == nil)
    let delivered = caller.history.outputs.count
    let delayed = MachinePointer(worker: space.machineBuffers.worker, operation: operation, channel: "data", from: 0, through: 4)
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation, channel: "data", from: 0, through: 4), output: delayed))))
    #expect(caller.history.outputs.count == delivered)
    let ignored = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    #expect(ignored.offsets["data"] == 2)
    #expect(ignored.offered["data"] == (consumerReachedOffer ? 2 : 4))
    #expect(ignored.failure == nil && !ignored.delivered)
    if consumerReachedOffer {
      try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation, channel: "data", from: 2, through: 4), output: suffix))))
      #expect(try await caller.output() == suffix)
    }
    #expect(!caller.closed.value.withLock { $0 })
    await space.drain()
    #expect(space.machineBuffers.payload(suffix)?.data == Data([3, 4]))
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == 2)
    if consumerReachedOffer { expectPoll(try await box.next(operation, .output("data")), channel: "data", after: 4) }
    #expect(box.outputPolls(operation, channel: "data") == (consumerReachedOffer ? [0, 2, 4] : [0, 4]))
    #expect(box.stops(operation).isEmpty)
    caller.peer.send(.want(channel: "data", offset: 2))
    #expect(try await caller.output() == suffix)
    caller.peer.send(.want(channel: "data", offset: 4))
    _ = try box.output(operation, payload: .init(data: Data([5, 6])), channel: "data", from: 4, completed: true)
    let last = try await caller.output()
    #expect(last.from == 4 && last.through == 6)
    caller.peer.send(.want(channel: "data", offset: 6))
    guard case .success = try await caller.finished() else { Issue.record("Expected completion after delayed overlap"); return }
    #expect(box.starts(operation).count == 1)
    #expect(box.stops(operation).isEmpty)
    box.peer.close()
    try await space.close()
  }

  @Test func aDelayedLargerFinalOutputCannotEndAnUnacceptedRange() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    expectPoll(try await box.next(operation, .output("data")), channel: "data", after: 0)
    let first = try box.output(operation, payload: .init(data: Data([1, 2])), channel: "data", from: 0)
    #expect(try await caller.output() == first)
    let delayed = try #require(space.machineBuffers.put(Data([1, 2, 3, 4]), operation: operation, channel: "data", from: 0))
    let token = UUID()
    let final = OperationSnapshot(operation: operation, verdict: .init(.completed, result: [:]), terminalToken: token, finalOffsets: ["data": .init(rawValue: 4)], outputConsumed: false, channel: "data", from: .init(rawValue: 0), through: .init(rawValue: 4), channelEnd: true)
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: final, output: delayed))))
    #expect(caller.history.outputs == [first])
    let offered = try #require(space.worker.cell(id).fileOperation(operation))
    #expect(offered.offsets["data"] == 0 && offered.offered["data"] == 2)
    #expect(!offered.endedChannels.contains("data"))
    #expect(caller.history.finishedCount == 0)

    caller.peer.send(.want(channel: "data", offset: 1))
    let admitted = try await caller.output()
    #expect(admitted.from == 1 && admitted.through == 2)
    #expect(space.machineBuffers.payload(admitted)?.data == Data([2]))
    #expect(space.worker.cell(id).fileOperation(operation)?.received["data"] == 2)
    caller.peer.send(.want(channel: "data", offset: 2))
    expectPoll(try await box.next(operation, .output("data")), channel: "data", after: 2)
    let suffix = try #require(space.machineBuffers.get(operation, channel: "data", from: 2))
    await space.drain()
    #expect(space.machineBuffers.payload(suffix)?.data == Data([3, 4]))
    let remainder = OperationSnapshot(operation: operation, verdict: final.verdict, terminalToken: token, finalOffsets: final.finalOffsets, outputConsumed: false, channel: "data", from: .init(rawValue: 2), through: .init(rawValue: 4), channelEnd: true)
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: remainder, output: suffix))))
    #expect(try await caller.output() == suffix)
    #expect(caller.history.finishedCount == 0)
    caller.peer.send(.want(channel: "data", offset: 4))
    guard case .success = try await caller.finished() else { Issue.record("Expected completion after consuming the full final range"); return }
    #expect(caller.history.finishedCount == 1)
    #expect(box.outputPolls(operation, channel: "data") == [0, 2])
    #expect(box.starts(operation).count == 1)
    #expect(box.stops(operation).isEmpty)
    box.peer.close()
    try await space.close()
  }

  @Test func delayedOldWorkerCleanupCannotCloseANewOperationWithTheSameLocalSocketID() async throws {
    let folder = try ScratchFolder("file-socket-id-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try await MachineCellTestSpace.open(file: file), new = try await MachineCellTestSpace.open(file: file)
    let machine = try await old.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    var first = try await FileTestBox.attach(old, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(old, machine: machine, operation: operation)
    try await first.start(operation)
    _ = try await first.next(operation, .output("data"))
    _ = try first.output(operation, payload: .init(data: Data([1, 2])), channel: "data", from: 0)
    _ = try await caller.output()
    let persistedOld = try #require(old.worker.cell(id).fileOperation(operation))
    let oldWorker = old.machineBuffers.worker
    await old.stopWorker()
    var replacement = try await FileTestBox.attach(new, machine: machine)
    expectStop(try await replacement.next(operation, .stop), operation: operation, reason: "rangeLost")
    let fresh = UUID()
    var resumed = try FileTestCaller.attach(new, machine: machine, operation: fresh)
    try await replacement.start(fresh)
    _ = try await replacement.next(fresh, .output("data"))
    let current = try #require(new.worker.cell(id).fileOperation(fresh))
    #expect(persistedOld.stream == current.stream)
    #expect(persistedOld.request.operation != current.request.operation)
    #expect(persistedOld.worker != current.worker)
    let matches = try await new.worker.call(id) { cell in
      var wrongWorker = cell.fileOperation(fresh)!
      wrongWorker.worker = oldWorker
      let acceptsWrongWorker = cell.fileSocket(wrongWorker) != nil
      var wrongOperation = persistedOld
      wrongOperation.worker = cell.buffers.worker
      let acceptsWrongOperation = cell.fileSocket(wrongOperation) != nil
      var delayed = persistedOld
      try cell.failFile(&delayed, .rangeLost(offset: 0))
      return (acceptsWrongWorker, acceptsWrongOperation)
    }
    #expect(!matches.0 && !matches.1)
    #expect(!resumed.closed.value.withLock { $0 })
    #expect(new.worker.cell(id).fileOperation(fresh)?.failure == nil)
    _ = try replacement.output(fresh, payload: .init(data: Data([3, 4])), channel: "data", from: 0, completed: true)
    let received = try await resumed.output()
    #expect(received.operation == fresh)
    await new.drain()
    #expect(new.machineBuffers.payload(received)?.data == Data([3, 4]))
    resumed.peer.send(.want(channel: "data", offset: 2))
    guard case .success = try await resumed.finished() else { Issue.record("Expected fresh operation to survive stale cleanup"); return }
    #expect(first.starts(operation).count == 1)
    #expect(replacement.starts(operation).isEmpty)
    #expect(replacement.starts(fresh).count == 1)
    replacement.peer.close()
    try await old.close()
    try await new.close()
  }

  @Test func identicalOutputBeforeWantIsDeliveredOnlyOnce() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    let pointer = try box.output(operation, payload: .init(data: Data([1, 2, 3, 4])), channel: "data", from: 0)
    #expect(try await caller.output() == pointer)
    #expect(caller.history.outputs == [pointer])
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation, channel: "data", from: 0, through: 4), output: pointer))))
    #expect(caller.history.outputs == [pointer])
    let row = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
    #expect(row.offsets["data"] == 0 && row.offered["data"] == 4)
    #expect(row.failure == nil && !row.delivered)
    await space.drain()
    #expect(space.machineBuffers.payload(pointer)?.data == Data([1, 2, 3, 4]))
    caller.peer.send(.want(channel: "data", offset: 2))
    let suffix = try await caller.output()
    #expect(suffix.from == 2 && suffix.through == 4)
    #expect(caller.history.outputs == [pointer, suffix])
    caller.peer.send(.want(channel: "data", offset: 4))
    expectPoll(try await box.next(operation, .output("data")), channel: "data", after: 4)
    _ = try box.output(operation, payload: .init(data: Data([5])), channel: "data", from: 4, completed: true)
    _ = try await caller.output()
    caller.peer.send(.want(channel: "data", offset: 5))
    guard case .success = try await caller.finished() else { Issue.record("Expected completion after duplicate output"); return }
    #expect(box.starts(operation).count == 1)
    #expect(box.stops(operation).isEmpty)
    box.peer.close()
    try await space.close()
  }

  @Test(arguments: ["callerGone", "acceptedStop", "missingRow"])
  func lateOutputDiscardsNewlyCachedBytesWithoutDeliveringAnything(state: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    let caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    caller.peer.close()
    expectStop(try await box.next(operation, .stop), operation: operation)
    if state == "acceptedStop" {
      try await box.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
      #expect(space.worker.cell(id).fileOperation(operation) == nil)
    }
    if state == "missingRow" {
      try await space.worker.call(id) { cell in
        try cell.db.execute(MachineFileOperation.where { $0.id.eq(operation.uuidString.lowercased()) }.delete())
      }
      #expect(space.worker.cell(id).fileOperation(operation) == nil)
    }
    let pointer = try #require(space.machineBuffers.put(Data([9, 8]), operation: operation, channel: "data", from: 0))
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == 2)
    try await box.answer(.init(tag: .operation(operation, .output("data")), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation, channel: "data", from: 0, through: 2), output: pointer))))
    await expectRetained(space, operation: operation, count: 0)
    await space.drain()
    #expect(space.machineBuffers.payload(pointer) == nil)
    #expect(caller.history.outputs.isEmpty)
    #expect(caller.history.finishedCount == 0)
    #expect(box.starts(operation).count == 1)
    if state == "callerGone" {
      let row = try #require(space.worker.cell(id).fileOperation(operation))
      #expect(row.offsets["data"] == 0 && row.offered["data"] == 0)
      #expect(row.failure == nil)
    } else { #expect(space.worker.cell(id).fileOperation(operation) == nil) }
    box.peer.close()
    try await space.close()
  }

  @Test func anInvalidWantedOffsetClosesTheCallerAndStopsWithoutAbandonedAcknowledgments() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .output("data"))
    _ = try box.output(operation, payload: .init(data: Data([1, 2])), channel: "data", from: 0)
    _ = try await caller.output()
    caller.peer.send(.want(channel: "data", offset: 3))
    expectStop(try await box.next(operation, .stop), operation: operation)
    #expect(caller.closed.value.withLock { $0 })
    #expect(caller.history.finishedCount == 0)
    await expectRetained(space, operation: operation, count: 0)
    #expect(box.terminalPolls(operation).isEmpty)
    try await box.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    #expect(box.stops(operation).count == 1)
    box.peer.close()
    try await space.close()
  }

  @Test func closingAllSocketsCannotDispatchAPendingMutationOnSameWorkerReattach() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    let first = try await FileTestBox.attach(space, machine: machine)
    first.peer.close()
    try await expectBoxClosed(space, machine: machine)
    let operation = UUID()
    let caller = try FileTestCaller.attach(space, machine: machine, operation: operation, kind: "mkdir.v1")
    try await expectFileCreated(space, machine: machine, operation: operation)
    #expect(space.worker.cell(id).fileOperation(operation)?.dispatched == false)
    try await space.worker.call(id) { $0.closeBoxes() }
    let replacement = try await FileTestBox.attach(space, machine: machine)
    try await expectFileDeleted(space, machine: machine, operation: operation)
    #expect(caller.closed.value.withLock { $0 })
    #expect(caller.history.startedCount == 0)
    #expect(first.starts(operation).isEmpty && replacement.starts(operation).isEmpty)
    #expect(first.stops(operation).isEmpty && replacement.stops(operation).isEmpty)
    #expect(replacement.terminalPolls(operation).isEmpty)
    replacement.peer.close()
    try await space.close()
  }

  @Test(arguments: ["conflictingSnapshot", "unknownOperation", "transportThenSnapshot"])
  func failedFileCleanupAcceptsStopWithoutRevalidatingRejectedEvidence(answer: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .control)
    let token = UUID()
    let known = OperationSnapshot(operation: operation, verdict: .init(.completed, result: [:]), terminalToken: token, finalOffsets: ["data": .init(rawValue: 2)], outputConsumed: false)
    let conflict = OperationSnapshot(operation: operation, verdict: known.verdict, terminalToken: token, finalOffsets: ["data": .init(rawValue: 3)], outputConsumed: false)
    try await box.answer(.init(tag: .operation(operation, .control), answer: .snapshot(.init(snapshot: known))))
    try await box.answer(.init(tag: .operation(operation, .control), answer: .snapshot(.init(snapshot: conflict))))
    guard case let .failure(.operation(error)) = try await caller.finished() else { Issue.record("Expected conflicting-evidence failure"); return }
    #expect(error.code == .invalidResponse)
    expectStop(try await box.next(operation, .stop), operation: operation, reason: "invalidResponse")
    try await box.answer(.init(tag: .operation(operation, .control), answer: .snapshot(.init(snapshot: conflict))))
    let failed = try #require(space.worker.cell(id).fileOperation(operation))
    #expect(failed.snapshot?.finalOffsets["data"] == .init(rawValue: 2))
    #expect(caller.history.finishedCount == 1)
    #expect(box.terminalPolls(operation).isEmpty)
    if answer == "transportThenSnapshot" {
      try await box.answer(.init(tag: .operation(operation, .stop), answer: .transport(.init(.transport))))
      let retry = try #require(space.worker.cell(id).fileOperation(operation)?.flights[.stop])
      #expect(!retry.waiting && retry.retry == 200)
      #expect(caller.history.finishedCount == 1)
    }
    let stopAnswer: BoxAnswer = answer == "unknownOperation" ? .box(.init(.unknownOperation)) : .snapshot(.init(snapshot: conflict))
    try await box.answer(.init(tag: .operation(operation, .stop), answer: stopAnswer))
    #expect(space.worker.cell(id).fileOperation(operation) == nil)
    try await box.answer(.init(tag: .operation(operation, .stop), answer: stopAnswer))
    #expect(space.worker.cell(id).fileOperation(operation) == nil)
    #expect(box.stops(operation).count == 1)
    #expect(caller.history.finishedCount == 1)
    box.peer.close()
    try await space.close()
  }

  @Test func startedIsPublishedOnceBeforeTheStartIsDispatchedAndBeforeAcceptance() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let order = FileTestOrder()
    var box = try await FileTestBox.attach(space, machine: machine, order: order)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation, order: order)
    let start = try await box.next(operation, .start)
    try await caller.started()
    #expect(order.events.withLock { $0 } == ["started", "startFile"])
    #expect(caller.history.startedCount == 1)
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation)?.snapshot == nil)
    try await box.answer(.init(tag: start.tag, answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    try await box.answer(.init(tag: start.tag, answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(caller.history.startedCount == 1)
    #expect(box.starts(operation).count == 1)
    caller.peer.close()
    expectStop(try await box.next(operation, .stop), operation: operation)
    box.peer.close()
    try await space.close()
  }

  @Test func anUndispatchedMutationIsKnownNotStartedAcrossWorkerRollover() async throws {
    let folder = try ScratchFolder("file-pending-mutation-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try await MachineCellTestSpace.open(file: file), new = try await MachineCellTestSpace.open(file: file)
    let machine = try await old.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    let first = try await FileTestBox.attach(old, machine: machine)
    first.peer.close()
    try await expectBoxClosed(old, machine: machine)
    let operation = UUID()
    let caller = try FileTestCaller.attach(old, machine: machine, operation: operation, kind: "mkdir.v1")
    try await expectFileCreated(old, machine: machine, operation: operation)
    let pending = try #require(old.worker.cell(id).fileOperation(operation))
    #expect(!pending.dispatched && pending.failure == nil)
    #expect(caller.history.startedCount == 0)
    #expect(first.starts(operation).isEmpty)
    await old.stopWorker()
    #expect(caller.closed.value.withLock { $0 })

    let policy = try await new.worker.call(id) { cell in cell.lostFile(pending) }
    expectNotStarted(policy)
    let replacement = try await FileTestBox.attach(new, machine: machine)
    try await new.worker.call(id) { cell in try cell.wakeFiles(presence: cell.presence) }
    #expect(new.worker.cell(id).fileOperation(operation) == nil)
    #expect(first.starts(operation).isEmpty)
    #expect(replacement.starts(operation).isEmpty)
    #expect(replacement.stops(operation).isEmpty)
    replacement.peer.close()
    try await expectBoxClosed(new, machine: machine)
    try await old.close()
    try await new.close()
  }

  @Test func aPendingMutationWhosePresenceLeaseExpiresIsKnownNotStarted() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    let box = try await FileTestBox.attach(space, machine: machine)
    box.peer.close()
    try await expectBoxClosed(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation, kind: "mkdir.v1")
    try await expectFileCreated(space, machine: machine, operation: operation)
    let pending = try #require(space.worker.cell(id).fileOperation(operation))
    #expect(!pending.dispatched && pending.failure == nil)
    #expect(caller.history.startedCount == 0)
    try await space.worker.call(id) { cell in
      var presence = cell.presence
      presence.lease = cell.now
      try cell.save(presence)
      try cell.wake()
    }
    guard case let .failure(failure) = try await caller.finished() else { Issue.record("Expected known-not-started failure"); return }
    expectNotStarted(failure)
    #expect(space.worker.cell(id).fileOperation(operation) == nil)
    #expect(caller.history.finishedCount == 1)
    #expect(box.starts(operation).isEmpty && box.stops(operation).isEmpty)
    try await space.close()
  }

  @Test(arguments: ["wrongOperation", "missingTerminalToken", "changedVerdict", "changedFinalOffset"])
  func malformedBoxAnswersFailWithoutCrashingOrReplacingKnownEvidence(reason: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    let id = MachineCell.ID(machine)
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .control)
    let token = UUID()
    let first = OperationSnapshot(operation: operation, verdict: .init(.completed, result: ["count": "2"]), terminalToken: token, finalOffsets: ["data": .init(rawValue: 2)], outputConsumed: false)
    if reason == "changedVerdict" || reason == "changedFinalOffset" {
      try await box.answer(.init(tag: .operation(operation, .control), answer: .snapshot(.init(snapshot: first))))
      #expect(caller.history.finishedCount == 0)
    }
    let answer: BoxAnswer
    switch reason {
    case "wrongOperation": answer = .snapshot(.init(snapshot: FileTestBox.snapshot(UUID())))
    case "missingTerminalToken":
      answer = .snapshot(.init(snapshot: OperationSnapshot(operation: operation, verdict: .init(.completed, result: [:]), terminalToken: nil, finalOffsets: [:], outputConsumed: false)))
    case "changedVerdict":
      answer = .snapshot(.init(snapshot: OperationSnapshot(operation: operation, verdict: .init(.failed, error: .init(.permissionDenied)), terminalToken: token, finalOffsets: ["data": .init(rawValue: 2)], outputConsumed: false)))
    case "changedFinalOffset":
      answer = .snapshot(.init(snapshot: OperationSnapshot(operation: operation, verdict: first.verdict, terminalToken: token, finalOffsets: ["data": .init(rawValue: 3)], outputConsumed: false)))
    default: preconditionFailure("Unknown malformed-answer fixture")
    }
    try await box.answer(.init(tag: .operation(operation, .control), answer: answer))
    guard case let .failure(.operation(error)) = try await caller.finished() else { Issue.record("Expected invalidResponse"); return }
    #expect(error.code == .invalidResponse)
    #expect(caller.history.finishedCount == 1)
    expectStop(try await box.next(operation, .stop), operation: operation, reason: "invalidResponse")
    let row = try #require(space.worker.cell(id).fileOperation(operation))
    if reason == "changedVerdict" || reason == "changedFinalOffset" {
      #expect(row.snapshot?.verdict == first.verdict)
      #expect(row.snapshot?.finalOffsets["data"] == .init(rawValue: 2))
    }
    try await box.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(space.worker.cell(id).fileOperation(operation) == nil)
    #expect(box.starts(operation).count == 1)
    box.peer.close()
    try await space.close()
  }

  @Test(arguments: ["callerCancelled", "permissionDenied"])
  func stopPreservesTheActualFailureReason(reason: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    let machine = try await space.addMachineV2(name: "files").machine.id.rawValue
    var box = try await FileTestBox.attach(space, machine: machine)
    let operation = UUID()
    var caller = try FileTestCaller.attach(space, machine: machine, operation: operation)
    try await box.start(operation)
    _ = try await box.next(operation, .control)
    if reason == "callerCancelled" { caller.peer.send(.cancel) }
    else { try await box.answer(.init(tag: .operation(operation, .control), answer: .box(.init(.permissionDenied)))) }
    guard case let .failure(.operation(error)) = try await caller.finished() else { Issue.record("Expected operation failure"); return }
    #expect(error.code == (reason == "callerCancelled" ? .requestCancelled : .permissionDenied))
    expectStop(try await box.next(operation, .stop), operation: operation, reason: reason)
    #expect(box.terminalPolls(operation).isEmpty)
    try await box.answer(.init(tag: .operation(operation, .stop), answer: .snapshot(.init(snapshot: FileTestBox.snapshot(operation)))))
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
    #expect(caller.history.finishedCount == 1)
    box.peer.close()
    try await space.close()
  }

  private func expectNotStarted(_ failure: MachineFileFailure) {
    guard case let .operation(error) = failure else { Issue.record("Expected known-not-started operation error"); return }
    #expect(error.code == .machineUnavailable)
    #expect(error.details?.object?["started"] == .bool(false))
  }

  @Test func aTwoHundredMiBTransportSinkRetainsOnlyOneReusedChunk() throws {
    let buffers = MachineBuffers(worker: "sink")
    let operation = UUID()
    let chunk = Data(repeating: 0x5A, count: 65536)
    var count: UInt64 = 0
    for _ in 0 ..< 3200 {
      let pointer = try #require(buffers.put(chunk, operation: operation, channel: "data", from: count))
      let payload = try #require(buffers.payload(pointer)?.data)
      #expect(payload.count == chunk.count && payload.first == 0x5A && payload.last == 0x5A)
      #expect(buffers.retained(operation, channel: "data") == chunk.count)
      count = pointer.through
      buffers.release(operation, channel: "data", before: count)
      #expect(buffers.retained(operation, channel: "data") == 0)
    }
    #expect(count == 200 * 1024 * 1024)
  }

  private func expectFileDeleted(_ space: MachineCellTestSpace, machine: String, operation: UUID) async throws {
    await space.drain()
    #expect(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation) == nil)
  }

  private func expectFileCreated(_ space: MachineCellTestSpace, machine: String, operation: UUID) async throws {
    await space.drain()
    _ = try #require(space.worker.cell(MachineCell.ID(machine)).fileOperation(operation))
  }

  private func expectBoxClosed(_ space: MachineCellTestSpace, machine: String) async throws {
    await space.drain()
    #expect(space.worker.cell(MachineCell.ID(machine)).box == nil)
  }

  private func expectRetained(_ space: MachineCellTestSpace, operation: UUID, count: Int) async {
    await space.drain()
    await space.drain()
    #expect(space.machineBuffers.retained(operation, channel: "data") == count)
  }

  private func expectStop(_ request: BoxSocket.Outgoing, operation: UUID, reason expected: String = "callerGone") {
    guard case let .stop(stopped, reason) = request.exchange else { Issue.record("Expected cleanup stop"); return }
    #expect(stopped == operation && reason == expected)
  }

  private func expectPoll(_ request: BoxSocket.Outgoing, channel: String, after: UInt64) {
    guard case let .poll(_, actualChannel, actualOffset, _, terminal, limit) = request.exchange else { Issue.record("Expected output poll"); return }
    #expect(actualChannel == channel && actualOffset == after && terminal == nil)
    #expect(limit == 65536)
  }
}

private struct FileTestBox {
  let space: MachineCellTestSpace
  let machine: String
  let peer: Peer<BoxSocket>
  let history: FileTestHistory
  var iterator: AsyncStream<BoxSocket.Outgoing>.Iterator

  static func attach(_ space: MachineCellTestSpace, machine: String, order: FileTestOrder? = nil) async throws -> Self {
    let pubkey = try await space.space.addMachineTestKey(machine)
    let stream = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let history = FileTestHistory()
    let peer = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      switch $0 {
      case let .frame(frame):
        if case .startFile = frame.exchange { order?.events.withLock { $0.append("startFile") } }
        history.frames.withLock { $0.append(frame) }; stream.continuation.yield(frame)
      case .closed: stream.continuation.finish()
      }
    })
    var result = Self(space: space, machine: machine, peer: peer, history: history, iterator: stream.stream.makeAsyncIterator())
    let describe = try #require(await result.iterator.next())
    #expect(describe.tag == .describe)
    peer.send(.init(tag: .describe, answer: .description(MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.read, ComputerKindSchemas.list, ComputerKindSchemas.mkdir]))))
    await space.drain()
    return result
  }

  mutating func next(_ operation: UUID, _ purpose: BoxPurpose) async throws -> BoxSocket.Outgoing {
    while let frame = await iterator.next() {
      if frame.tag == .operation(operation, purpose) {
        await space.drain()
        return frame
      }
    }
    throw FileFixtureEnded()
  }

  func answer(_ frame: BoxSocket.Incoming) async throws {
    try await space.worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(frame, from: cell.box!)
    }
    await space.drain()
  }

  @discardableResult mutating func start(_ operation: UUID) async throws -> StartRequest {
    let frame = try await next(operation, .start)
    guard case let .startFile(id, start) = frame.exchange else { throw FileFixtureEnded() }
    #expect(id == operation)
    peer.send(.init(tag: frame.tag, answer: .snapshot(.init(snapshot: Self.snapshot(operation)))))
    await space.drain()
    return start
  }

  func output(_ operation: UUID, payload: ChannelPayload, channel: String, from: UInt64, completed: Bool = false) throws -> MachinePointer {
    let pointer = try #require(space.machineBuffers.put(payload: payload, operation: operation, channel: channel, from: from))
    peer.send(.init(tag: .operation(operation, .output(channel)), answer: .snapshot(.init(snapshot: Self.snapshot(operation, channel: channel, from: from, through: pointer.through, completed: completed), output: pointer))))
    return pointer
  }

  static func snapshot(_ operation: UUID, channel: String? = nil, from: UInt64 = 0, through: UInt64 = 0, completed: Bool = false) -> OperationSnapshot {
    OperationSnapshot(operation: operation, verdict: completed ? .init(.completed, result: [:]) : nil, terminalToken: completed ? UUID() : nil, finalOffsets: completed ? [channel!: .init(rawValue: through)] : [:], outputConsumed: false, channel: channel, from: channel.map { _ in .init(rawValue: from) }, through: channel.map { _ in .init(rawValue: through) }, channelEnd: completed)
  }

  func starts(_ operation: UUID) -> [BoxSocket.Outgoing] { history.frames.withLock { $0.filter { $0.tag == .operation(operation, .start) } } }
  func stops(_ operation: UUID) -> [BoxSocket.Outgoing] { history.frames.withLock { $0.filter { $0.tag == .operation(operation, .stop) } } }
  func outputPolls(_ operation: UUID, channel: String) -> [UInt64] {
    history.frames.withLock { frames in frames.compactMap { frame in
      guard frame.tag == .operation(operation, .output(channel)), case let .poll(_, _, offset, _, _, _) = frame.exchange else { return nil }
      return offset
    } }
  }

  func terminalPolls(_ operation: UUID) -> [BoxSocket.Outgoing] {
    history.frames.withLock { $0.filter { frame in
      guard case let .operation(id, .terminal(_)) = frame.tag else { return false }
      return id == operation
    } }
  }
}

private struct FileTestCaller {
  let space: MachineCellTestSpace
  let peer: Peer<FileBulk>
  let closed: FileTestClosed
  let history: FileTestBulkHistory
  var iterator: AsyncStream<FileBulk.Outgoing>.Iterator

  static func attach(_ space: MachineCellTestSpace, machine: String, operation: UUID, kind: String = "read.v1", input: JSONValue = ["path": "/file"], order: FileTestOrder? = nil) throws -> Self {
    let stream = AsyncStream<FileBulk.Outgoing>.makeStream()
    let closed = FileTestClosed()
    let history = FileTestBulkHistory()
    let request = MachineFile(operation: operation, start: StartRequest(kind: kind, input: input))
    let peer = try #require(space.worker.attach(FileBulk.self, to: MachineCell.ID(machine), opening: .init(request: request)) {
      switch $0 {
      case let .frame(frame):
        if case .started = frame { order?.events.withLock { $0.append("started") } }
        history.frames.withLock { $0.append(frame) }; stream.continuation.yield(frame)
      case .closed: closed.value.withLock { $0 = true }; stream.continuation.finish()
      }
    })
    return Self(space: space, peer: peer, closed: closed, history: history, iterator: stream.stream.makeAsyncIterator())
  }

  mutating func started() async throws {
    guard let frame = await iterator.next(), case .started = frame else { throw FileFixtureEnded() }
    await space.drain()
  }

  mutating func output() async throws -> MachinePointer {
    while let frame = await iterator.next() {
      switch frame {
      case .started, .ready, .accepted: continue
      case let .output(pointer):
        await space.drain()
        return pointer
      case .finished: throw FileFixtureEnded()
      }
    }
    throw FileFixtureEnded()
  }

  mutating func finished() async throws -> Result<JSONValue, MachineFileFailure> {
    while let frame = await iterator.next() {
      if case let .finished(result) = frame {
        await space.drain()
        return result
      }
    }
    throw FileFixtureEnded()
  }
}

private struct FileFixtureEnded: Error {}

private final class FileTestOrder: Sendable {
  let events = Mutex<[String]>([])
}

private final class FileTestHistory: Sendable {
  let frames = Mutex<[BoxSocket.Outgoing]>([])
}

private final class FileTestClosed: Sendable {
  let value = Mutex(false)
}

private final class FileTestBulkHistory: Sendable {
  let frames = Mutex<[FileBulk.Outgoing]>([])
  var outputs: [MachinePointer] {
    frames.withLock { $0.compactMap { frame in
      if case let .output(pointer) = frame { return pointer }
      return nil
    } }
  }

  var startedCount: Int {
    frames.withLock { $0.filter { frame in
      if case .started = frame { return true }
      return false
    }.count }
  }

  var finishedCount: Int {
    frames.withLock { $0.filter { frame in
      if case .finished = frame { return true }
      return false
    }.count }
  }
}
