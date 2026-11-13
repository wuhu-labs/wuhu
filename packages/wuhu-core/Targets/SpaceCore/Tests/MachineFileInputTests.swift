import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import OperationProtocol
import Scratch
@testable import SpaceCore
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineFileInputTests {
  @Test func readinessIsSeparateFromDispatchAndOnlyEmittedOnce() async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    _ = try await f.next(.start)
    guard case .started = try await f.callerNext() else { Issue.record("Expected dispatch marker"); return }
    #expect(f.row?.inputReady == false)
    #expect(f.readyCount == 0)
    try await f.answer(.start, .snapshot(.init(snapshot: f.snapshot())))
    guard case let .ready(inputs, _) = try await f.callerNext() else { Issue.record("Expected ready"); return }
    #expect(inputs == ComputerKindSchemas.stagedWrite.inputChannels)
    #expect(f.row?.inputOffsets == ["data": 0, "commit": 0])
    try await f.answer(.start, .snapshot(.init(snapshot: f.snapshot())))
    #expect(f.readyCount == 1)
    #expect(f.frames.filter { if case .fileInput = $0.exchange { true } else { false } }.isEmpty)
    f.close(); try await space.close()
  }

  @Test func startPreparationRefusalDeletesTheRowWithoutSendingStop() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    _ = try await f.next(.start)
    guard case .started = try await f.callerNext() else { Issue.record("Expected dispatch marker"); return }
    let refusal = OperationError(.machineNotAuthorized, message: "captured machine key was revoked")
    try await f.answer(.start, .preparation(refusal))
    guard case let .failure(.operation(error)) = try await f.finished() else { Issue.record("Expected original preparation refusal"); return }
    #expect(error == refusal)
    await space.drain()
    #expect(f.row == nil)
    #expect(f.readyCount == 0)
    #expect(!f.frames.contains { $0.tag == .operation(f.operation, .stop) })
    f.close(); try await space.close()
  }

  @Test func partialReceiptsRetryOnlyTheSuffixAndChannelsUseTheirOwnUnits() async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    try await f.ready()
    let bytes = Data("payload-only-in-buffers".utf8)
    let pointer = try f.input(.init(data: bytes), channel: "data", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: pointer, end: true)
    try await f.receipt("data", through: 2)
    let suffix = MachinePointer(worker: pointer.worker, operation: pointer.operation, channel: "data", from: 2, through: pointer.through)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: suffix, end: true)
    #expect(space.machineBuffers.payload(suffix)?.data == Data(bytes.dropFirst(2)))
    #expect(f.row?.inputOffsets["data"] == 2)
    #expect(f.acceptedCount == 0)
    try await f.receipt("data", through: pointer.through)
    let eof = MachinePointer(worker: pointer.worker, operation: pointer.operation, channel: "data", from: pointer.through, through: pointer.through)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: eof, end: true)
    #expect(f.acceptedCount == 0)
    try await f.receipt("data", through: pointer.through, end: true)
    try await f.accepted("data", through: pointer.through, end: true)
    let commit: JSONValue = ["bytes": .string(String(bytes.count)), "sha256": "commit-marker-not-row"]
    let record = try f.input(.init(records: [commit]), channel: "commit", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "commit")), pointer: record, end: true)
    #expect(record.from == 0 && record.through == 1)
    try await f.receipt("data", through: 2)
    try await f.receipt("data", through: pointer.through, end: true)
    #expect(f.row?.inputOffsets["commit"] == 0)
    #expect(f.acceptedCount == 1)
    try await f.receipt("commit", through: 1, end: true)
    try await f.accepted("commit", through: 1, end: true)
    #expect(f.row?.inputEnded == Set(["data", "commit"]))
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 0)
    #expect(space.machineBuffers.retained(f.operation, channel: "commit") == 0)
    let operation = f.operation
    let persisted = try RawDatabase.open(space.databasePath) { db in
      try db.string("SELECT inputOffsets || inputEnded || flights || COALESCE(snapshot, '') FROM machine_file_operations WHERE id = ?", arguments: [operation.uuidString.lowercased()])!
    }
    #expect(!persisted.contains("payload-only-in-buffers"))
    #expect(!persisted.contains(bytes.base64EncodedString()))
    #expect(!persisted.contains("commit-marker-not-row"))
    #expect(f.frames.filter { $0.tag == .operation(f.operation, .start) }.count == 1)
    f.close(); try await space.close()
  }

  @Test func consecutiveFramesAndEmptyEOFWaitForWholeFrameAcceptance() async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    try await f.ready()
    for offset in 0 ..< 3 {
      let pointer = try f.input(.init(data: Data([UInt8(offset)])), channel: "data", end: false)
      #expect(pointer.from == UInt64(offset))
      FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: pointer, end: false)
      try await f.receipt("data", through: pointer.through)
      try await f.accepted("data", through: pointer.through, end: false)
    }
    let eof = try f.input(.init(data: Data()), channel: "data", end: true)
    #expect(eof.from == 3 && eof.through == 3)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: eof, end: true)
    try await f.receipt("data", through: 3, end: true)
    try await f.accepted("data", through: 3, end: true)
    #expect(f.row?.inputEnded == Set(["data"]))
    #expect(space.machineBuffers.pending(f.operation) == nil)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 0)
    f.close(); try await space.close()
  }

  @Test func lostStartResponseBecomesReadyFromReconciliationWithoutRestarting() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    _ = try await f.next(.start)
    guard case .started = try await f.callerNext() else { Issue.record("Expected dispatch"); return }
    try await f.answer(.start, .transport(.init(.transport)))
    #expect(f.row?.inputReady == false)
    try await f.replaceBox()
    _ = try await f.next(.control)
    try await f.answer(.control, .snapshot(.init(snapshot: f.snapshot())))
    guard case let .ready(inputs, _) = try await f.callerNext() else { Issue.record("Expected reconciled readiness"); return }
    #expect(inputs == ComputerKindSchemas.stagedWrite.inputChannels)
    #expect(f.row?.state == "running")
    let data = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: data, end: true)
    try await f.receipt("data", through: 3, end: true)
    try await f.accepted("data", through: 3, end: true)
    let commit = try f.input(.init(records: [["bytes": "3", "sha256": "digest"]]), channel: "commit", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "commit")), pointer: commit, end: true)
    try await f.receipt("commit", through: 1, end: true)
    try await f.accepted("commit", through: 1, end: true)
    let result: JSONValue = ["written": 3]
    let terminal = OperationSnapshot(operation: f.operation, verdict: .init(.completed, result: result), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
    try await f.answer(.control, .snapshot(.init(snapshot: terminal)))
    guard case let .success(actual) = try await f.finished() else { Issue.record("Expected actual result"); return }
    #expect(actual == result)
    #expect(f.readyCount == 1)
    #expect(f.frames.filter { $0.tag == .operation(f.operation, .start) }.count == 1)
    f.close(); try await space.close()
  }

  @Test func lostFinalReceiptReconcilesPastAnInflightPreterminalControl() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    try await f.ready()
    _ = try await f.next(.control)
    let data = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: data, end: true)
    try await f.receipt("data", through: 3, end: true)
    try await f.accepted("data", through: 3, end: true)
    let payload = ChannelPayload(records: [["bytes": "3", "sha256": "digest"]])
    let commit = try f.input(payload, channel: "commit", end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "commit")), pointer: commit, end: true)
    #expect(f.row?.flights[.control]?.waiting == true)
    try await f.answer(.fileInput(channel: "commit"), .box(.init(.operationEnded)))
    #expect(f.row?.state == "reconciling")
    #expect(f.row?.failure == nil)
    #expect(f.row?.inputOffsets["commit"] == 0)
    #expect(f.row?.flights[.fileInput(channel: "commit")] == nil)
    #expect(f.row?.flights[.control]?.waiting == true)
    try await f.answer(.control, .snapshot(.init(snapshot: f.snapshot())))
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "commit")), pointer: commit, end: true)
    #expect(f.row?.state == "running")
    try await f.answer(.fileInput(channel: "commit"), .box(.init(.operationEnded)))
    #expect(f.row?.state == "reconciling")
    #expect(f.row?.failure == nil)
    #expect(space.machineBuffers.pending(f.operation)?.0 == commit)
    #expect(space.machineBuffers.payload(commit) == payload)
    space.advance(by: 100)
    try await space.worker.call(MachineCell.ID(f.machine)) { cell in try cell.wakeFiles(presence: cell.presence) }
    _ = try await f.next(.control)
    let result: JSONValue = ["written": 3, "sha256": "digest"]
    let terminal = OperationSnapshot(operation: f.operation, verdict: .init(.completed, result: result), terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
    try await f.answer(.control, .snapshot(.init(snapshot: terminal)))
    guard case let .success(actual) = try await f.finished() else { Issue.record("Expected reconciled terminal result"); return }
    #expect(actual == result)
    #expect(f.readyCount == 1)
    #expect(f.acceptedCount == 1)
    #expect(f.frames.filter { $0.tag == .operation(f.operation, .start) }.count == 1)
    let inputs = f.frames.compactMap { frame -> MachinePointer? in
      if case let .fileInput(_, pointer, _) = frame.exchange { return pointer }
      return nil
    }
    #expect(inputs == [data, commit, commit])
    f.close(); try await space.close()
  }

  @Test func acceptedFramesBeyondFourMiBDoNotDependOnCleanupTasks() async throws {
    let space = try await MachineCellTestSpace.inMemory()
    defer { space.releaseHeldTasks() }
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    try await f.ready()
    await space.drain()
    let payload = ChannelPayload(data: Data(repeating: 7, count: 65536))
    for frame in 0 ..< 66 {
      guard space.machineBuffers.retained(f.operation, channel: "data") < 4 << 20 else {
        Issue.record("Acknowledged frames filled the physical input window at frame \(frame)")
        space.releaseHeldTasks()
        await space.drain()
        f.close(); try await space.close()
        return
      }
      let pointer = try f.input(payload, channel: "data", end: frame == 65)
      FileLaneFixture.expectInput(try await f.next(.fileInput(channel: "data")), pointer: pointer, end: frame == 65)
      let operation = f.operation
      try await space.worker.call(MachineCell.ID(f.machine)) { cell in
        space.holdNextTask()
        try cell.answer(.init(tag: .operation(operation, .fileInput(channel: "data")), answer: .input(.init(acceptedThrough: .init(rawValue: pointer.through), end: frame == 65, blocked: false))), from: cell.box!)
      }
      space.stopHoldingNextTask()
      try await f.accepted("data", through: pointer.through, end: frame == 65)
      #expect(f.row?.inputOffsets["data"] == UInt64((frame + 1) * 65536))
    }
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 0)
    space.releaseHeldTasks()
    await space.drain()
    f.close(); try await space.close()
  }

  @Test(arguments: ["data", "commit", "dataEnd", "emptyEnd"]) func callerReclamationDoesNotBlockTheNextFrame(firstFrame: String) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    defer { space.releaseHeldTasks() }
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    try await f.ready()
    await space.drain()
    let channel = firstFrame == "commit" ? "commit" : "data"
    let ended = firstFrame == "dataEnd" || firstFrame == "emptyEnd"
    let payload = channel == "commit" ? ChannelPayload(records: [.string(String(repeating: "x", count: 600))]) : ChannelPayload(data: firstFrame == "emptyEnd" ? Data() : Data([1, 2, 3]))
    let first = try f.input(payload, channel: channel, end: ended)
    _ = try await f.next(.fileInput(channel: channel))
    let operation = f.operation
    try await space.worker.call(MachineCell.ID(f.machine)) { cell in
      try cell.answer(.init(tag: .operation(operation, .fileInput(channel: channel)), answer: .input(.init(acceptedThrough: .init(rawValue: first.through), end: ended, blocked: false))), from: cell.box!)
    }
    try await f.accepted(channel, through: first.through, end: ended)
    #expect(f.row?.inputOffsets[channel] == first.through)
    #expect(f.row?.flights[.fileInput(channel: channel)] == nil)
    #expect(space.machineBuffers.pending(operation) == nil)
    let nextChannel = ended ? "commit" : channel
    let nextPayload = nextChannel == "commit" ? ChannelPayload(records: [.string(String(repeating: "y", count: 600))]) : payload
    let second = try f.input(nextPayload, channel: nextChannel, end: true)
    await space.drain()
    #expect(f.row != nil)
    #expect(f.row?.failure == nil)
    guard f.row != nil, f.row?.failure == nil else {
      space.releaseHeldTasks()
      f.close(); try await space.close()
      return
    }
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: nextChannel)), pointer: second, end: true)
    space.releaseHeldTasks()
    await space.drain()
    #expect(space.machineBuffers.pending(operation)?.0 == second)
    #expect(space.machineBuffers.payload(second) == nextPayload)
    try await f.receipt(nextChannel, through: second.through, end: true)
    try await f.accepted(nextChannel, through: second.through, end: true)
    await space.drain()
    #expect(f.row?.failure == nil)
    #expect(f.row?.inputEnded.contains(nextChannel) == true)
    #expect(space.machineBuffers.pending(operation) == nil)
    f.close(); try await space.close()
  }

  @Test(arguments: [false, true]) func completedInputHasNoFlightWhenCallerReclaimsBeforeReattachment(ended: Bool) async throws {
    let space = try await MachineCellTestSpace.inMemory()
    var f = try await FileLaneFixture.attach(space.space, worker: space.worker, buffers: space.machineBuffers)
    try await f.ready()
    let first = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: ended)
    _ = try await f.next(.fileInput(channel: "data"))
    try await f.receipt("data", through: first.through, end: ended)
    try await f.accepted("data", through: first.through, end: ended)
    await space.drain()
    #expect(f.row?.flights[.fileInput(channel: "data")] == nil)
    #expect(space.machineBuffers.pending(f.operation) == nil)
    try await f.replaceBox()
    _ = try await f.next(.control)
    #expect(f.row?.failure == nil)
    #expect(f.row?.flights[.fileInput(channel: "data")] == nil)
    #expect(f.row?.state == "reconciling")
    try await f.answer(.control, .snapshot(.init(snapshot: f.snapshot())))
    #expect(f.row?.state == "running")
    let channel = ended ? "commit" : "data"
    let payload = ended ? ChannelPayload(records: [.null]) : ChannelPayload(data: Data())
    let next = try f.input(payload, channel: channel, end: true)
    FileLaneFixture.expectInput(try await f.next(.fileInput(channel: channel)), pointer: next, end: true)
    try await f.receipt(channel, through: next.through, end: true)
    try await f.accepted(channel, through: next.through, end: true)
    #expect(f.row?.failure == nil)
    f.close(); try await space.close()
  }

  @Test func receiptBeyondTheSubmittedFrameIsAnInvalidResponse() async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    try await f.ready()
    _ = try f.input(.init(data: Data([1, 2])), channel: "data", end: true)
    _ = try await f.next(.fileInput(channel: "data"))
    try await f.receipt("data", through: 3, end: true)
    guard case let .failure(.operation(error)) = try await f.finished() else { Issue.record("Expected invalid receipt failure"); return }
    #expect(error.code == .invalidResponse)
    #expect(f.row?.inputOffsets["data"] == 0)
    #expect(f.acceptedCount == 0)
    _ = try await f.next(.stop)
    f.close(); try await space.close()
  }

  @Test(arguments: ["beforeReady", "wrongUnit", "recordTooLarge", "recordWindow", "chunkTooLarge", "gap", "missingPointer", "foreignPointer"])
  func invalidFramesFailWithoutForwardingPayload(reason: String) async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    if reason == "beforeReady" { _ = try await f.next(.start) }
    else { try await f.ready() }
    var channel = "data"
    let from: UInt64 = reason == "gap" ? 1 : 0
    var payload = ChannelPayload(data: Data([1]))
    switch reason {
    case "wrongUnit": payload = .init(records: [.null])
    case "recordTooLarge": channel = "commit"; payload = .init(records: [.string(String(repeating: "x", count: 1023))])
    case "recordWindow": channel = "commit"; payload = .init(records: Array(repeating: .string(String(repeating: "x", count: 600)), count: 2))
    case "chunkTooLarge": payload = .init(data: Data(repeating: 1, count: 65537))
    default: break
    }
    var pointer = try #require(space.machineBuffers.put(payload: payload, operation: f.operation, channel: channel, from: from))
    if reason == "missingPointer" { space.machineBuffers.discard(f.operation) }
    if reason == "foreignPointer" { pointer.worker = "foreign" }
    f.caller.send(.input(pointer, end: true))
    let result = try await f.finished()
    if reason == "missingPointer" {
      guard case .failure(.outcomeUnknown) = result else { Issue.record("Expected lost pointer outcomeUnknown"); return }
    } else {
      guard case let .failure(.operation(error)) = result else { Issue.record("Expected input error"); return }
      #expect(error.code == .invalidInput)
    }
    #expect(f.frames.filter { if case .fileInput = $0.exchange { true } else { false } }.isEmpty)
    _ = try await f.next(.stop)
    try await f.answer(.stop, .box(.init(.unknownOperation)))
    #expect(f.row == nil)
    f.close(); try await space.close()
  }

  @Test(arguments: [false, true]) func missingPendingPayloadIsUnknownAcrossBoxReattachment(reattach: Bool) async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    try await f.ready()
    _ = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: true)
    _ = try await f.next(.fileInput(channel: "data"))
    space.machineBuffers.discard(f.operation)
    if reattach { try await f.replaceBox() }
    else { try await f.receipt("data", through: 3, end: true) }
    guard case .failure(.outcomeUnknown) = try await f.finished() else { Issue.record("Expected lost input outcomeUnknown"); return }
    _ = try await f.next(.stop)
    #expect(f.frames.filter { $0.tag == .operation(f.operation, .start) }.count == 1)
    f.close(); try await space.close()
  }

  @Test func callerCloseAbandonsReceiptsAndOnlyStopsWithoutTerminalAck() async throws {
    let space = try Space.inMemory()
    var f = try await FileLaneFixture.attach(space)
    try await f.ready()
    _ = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: true)
    _ = try await f.next(.fileInput(channel: "data"))
    f.caller.close()
    let stop = try await f.next(.stop)
    guard case let .stop(_, reason) = stop.exchange else { Issue.record("Expected stop"); return }
    #expect(reason == "callerGone")
    try await f.receipt("data", through: 3, end: true)
    #expect(f.acceptedCount == 0)
    #expect(space.machineBuffers.retained(f.operation, channel: "data") == 0)
    try await f.answer(.stop, .snapshot(.init(snapshot: f.snapshot(completed: true))))
    #expect(f.row == nil)
    #expect(!f.frames.contains { if case .operation(_, .terminal) = $0.tag { true } else { false } })
    f.close(); try await space.close()
  }

  @Test func workerRollNeverReplaysAMutationOrItsInput() async throws {
    let folder = try ScratchFolder("file-input-worker-roll")
    defer { folder.remove() }
    let file = folder.url.appending(path: "space.sqlite")
    let old = try Space.open(file: file), new = try Space.open(file: file)
    var f = try await FileLaneFixture.attach(old)
    try await f.ready()
    _ = try f.input(.init(data: Data([1, 2, 3])), channel: "data", end: true)
    _ = try await f.next(.fileInput(channel: "data"))
    await old.stopWorker()
    var replacement = try await FileLaneFixture.attach(new, machine: f.machine, operation: UUID(), attachCaller: false)
    _ = try await replacement.next(.stop, operation: f.operation)
    let row = try #require(new.worker.cell(MachineCell.ID(f.machine)).fileOperation(f.operation))
    guard case .some(.outcomeUnknown) = row.failure else { Issue.record("Expected rolled mutation outcomeUnknown"); return }
    #expect(!replacement.frames.contains { if case .startFile = $0.exchange { true } else { false } })
    #expect(!replacement.frames.contains { if case .fileInput = $0.exchange { true } else { false } })
    f.close(); replacement.close(); try await old.close(); try await new.close()
  }
}

struct FileLaneFixture {
  let space: Space
  let worker: Worker
  let machineBuffers: MachineBuffers
  let machine: String
  let pubkey: String
  let operation: UUID
  var box: Peer<BoxSocket>
  let caller: Peer<FileBulk>
  let boxFrames: FileLaneHistory<BoxSocket.Outgoing>
  let callerFrames: FileLaneHistory<FileBulk.Outgoing>
  var boxIterator: AsyncStream<BoxSocket.Outgoing>.Iterator
  var callerIterator: AsyncStream<FileBulk.Outgoing>.Iterator

  static func attach(_ space: Space, machine: String? = nil, operation: UUID = UUID(), kind: String = "stagedWrite.v1", attachCaller: Bool = true, worker: Worker? = nil, buffers: MachineBuffers? = nil) async throws -> Self {
    let worker = worker ?? space.worker
    let buffers = buffers ?? space.machineBuffers
    let id: String
    if let machine { id = machine }
    else { id = try await space.addMachineV2(name: "input").machine.id.rawValue }
    let machine = id
    let pubkey = try await space.addMachineTestKey(machine)
    let boxStream = AsyncStream<BoxSocket.Outgoing>.makeStream(), callerStream = AsyncStream<FileBulk.Outgoing>.makeStream()
    let boxFrames = FileLaneHistory<BoxSocket.Outgoing>(), callerFrames = FileLaneHistory<FileBulk.Outgoing>()
    let box = try #require(worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { boxFrames.frames.withLock { $0.append(frame) }; boxStream.continuation.yield(frame) }
      else { boxStream.continuation.finish() }
    })
    var boxIterator = boxStream.stream.makeAsyncIterator()
    #expect(try #require(await boxIterator.next()).tag == .describe)
    try await Self.describe(worker: worker, machine: machine)
    let request = MachineFile(operation: operation, start: .init(kind: kind, input: kind == "stagedWrite.v1" ? ["path": "/target", "replace": false] : ["path": "/target"]))
    let callerMachine = attachCaller ? machine : try await space.addMachineV2(name: "unused").machine.id.rawValue
    let caller = try #require(worker.attach(FileBulk.self, to: MachineCell.ID(callerMachine), opening: .init(request: request)) {
      if case let .frame(frame) = $0 { callerFrames.frames.withLock { $0.append(frame) }; callerStream.continuation.yield(frame) }
      else { callerStream.continuation.finish() }
    })
    return Self(space: space, worker: worker, machineBuffers: buffers, machine: machine, pubkey: pubkey, operation: operation, box: box, caller: caller, boxFrames: boxFrames, callerFrames: callerFrames, boxIterator: boxIterator, callerIterator: callerStream.stream.makeAsyncIterator())
  }

  private static func describe(worker: Worker, machine: String) async throws {
    let description = Self.description
    try await worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(.init(tag: .describe, answer: .description(description)), from: cell.box!)
    }
  }

  static var description: MachineDescription { .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.stagedWrite, ComputerKindSchemas.read, ComputerKindSchemas.list]) }
  var frames: [BoxSocket.Outgoing] { boxFrames.frames.withLock { $0 } }
  var row: MachineFileOperation? { worker.cell(MachineCell.ID(machine)).fileOperation(operation) }
  var readyCount: Int { callerFrames.frames.withLock { $0.filter { if case .ready = $0 { true } else { false } }.count } }
  var acceptedCount: Int { callerFrames.frames.withLock { $0.filter { if case .accepted = $0 { true } else { false } }.count } }
  func snapshot(completed: Bool = false) -> OperationSnapshot { .init(operation: operation, verdict: completed ? .init(.completed, result: [:]) : nil, terminalToken: completed ? UUID() : nil, finalOffsets: [:], outputConsumed: false) }
  mutating func callerNext() async throws -> FileBulk.Outgoing { try #require(await callerIterator.next()) }
  mutating func next(_ purpose: BoxPurpose, operation: UUID? = nil) async throws -> BoxSocket.Outgoing {
    while let frame = await boxIterator.next() { if frame.tag == .operation(operation ?? self.operation, purpose) { return frame } }
    throw FileLaneFixtureEnded()
  }

  mutating func ready() async throws {
    _ = try await next(.start)
    try await answer(.start, .snapshot(.init(snapshot: snapshot())))
    while let frame = await callerIterator.next() { if case .ready = frame { return } }
    throw FileLaneFixtureEnded()
  }

  func answer(_ purpose: BoxPurpose, _ answer: BoxAnswer) async throws {
    let operation = operation
    try await worker.call(MachineCell.ID(machine)) { cell in
      try cell.answer(.init(tag: .operation(operation, purpose), answer: answer), from: cell.box!)
    }
  }

  func receipt(_ channel: String, through: UInt64, end: Bool = false) async throws {
    try await answer(.fileInput(channel: channel), .input(.init(acceptedThrough: .init(rawValue: through), end: end, blocked: false)))
  }

  func input(_ payload: ChannelPayload, channel: String, end: Bool) throws -> MachinePointer {
    let from = row!.inputOffsets[channel]!
    let pointer = try #require(machineBuffers.put(payload: payload, operation: operation, channel: channel, from: from))
    caller.send(.input(pointer, end: end)); return pointer
  }

  static func expectInput(_ frame: BoxSocket.Outgoing, pointer: MachinePointer, end: Bool) {
    guard case let .fileInput(id, actual, actualEnd) = frame.exchange else { Issue.record("Expected file input"); return }
    #expect(id == pointer.operation && actual == pointer && actualEnd == end)
  }

  mutating func accepted(_ channel: String, through: UInt64, end: Bool) async throws {
    guard case let .accepted(actualChannel, actualOffset, actualEnd) = try await callerNext() else { Issue.record("Expected whole-frame receipt"); return }
    #expect(actualChannel == channel && actualOffset == through && actualEnd == end)
    machineBuffers.accepted(operation, channel: actualChannel, through: actualOffset, ended: actualEnd)
  }

  mutating func finished() async throws -> Result<JSONValue, MachineFileFailure> {
    while let frame = await callerIterator.next() { if case let .finished(result) = frame { return result } }
    throw FileLaneFixtureEnded()
  }

  mutating func replaceBox() async throws {
    let stream = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let frames = boxFrames
    box = try #require(worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { frames.frames.withLock { $0.append(frame) }; stream.continuation.yield(frame) }
      else { stream.continuation.finish() }
    })
    boxIterator = stream.stream.makeAsyncIterator()
    #expect(try #require(await boxIterator.next()).tag == .describe)
    try await Self.describe(worker: worker, machine: machine)
  }

  func close() { caller.close(); box.close() }
}

private struct FileLaneFixtureEnded: Error {}

final class FileLaneHistory<Element: Sendable>: Sendable {
  let frames = Mutex<[Element]>([])
}
