import ControlledTime
import Crypto
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct FileSearch.SearchError
import JSONValue
import MachineContract
import OperationProtocol
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

func fileSnapshot(_ operation: UUID, result: JSONValue? = nil, channel: String? = nil, from: UInt64 = 0, through: UInt64 = 0, final: UInt64? = nil) -> OperationSnapshot {
  .init(operation: operation, verdict: result.map { .init(.completed, result: $0) }, terminalToken: result == nil ? nil : UUID(), finalOffsets: final.map { [channel!: Offset(rawValue: $0)] } ?? [:], outputConsumed: false, channel: channel, from: channel == nil ? nil : Offset(rawValue: from), through: channel == nil ? nil : Offset(rawValue: through))
}

func withFileBox<R: Sendable>(
  kinds: [KindDescriptor],
  respond: (BoxSocket.Outgoing, Peer<BoxSocket>, Space) async throws -> Void,
  operation: @escaping @Sendable (MachineFileClient) async throws -> R,
) async throws -> R {
  let space = try Space.inMemory()
  let machine = MachineID(rawValue: "file-client-test")
  let (requests, continuation) = AsyncStream<BoxSocket.Outgoing>.makeStream()
  let ready = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
  let peer = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine.rawValue), opening: .init(connection: UUID(), pubkey: pubkey, streams: 64)) {
    if case let .frame(frame) = $0 { continuation.yield(frame) }
  })
  space.worker.start()
  do {
    let result = try await withThrowingTaskGroup(of: R.self) { group in
      group.addTask {
        defer { continuation.finish() }
        for await _ in ready.stream { break }
        try Task.checkCancellation()
        return try await operation(MachineFileClient(space: space, machine: machine, caller: nil))
      }
      for await request in requests {
        if case .describe = request.exchange {
          peer.send(.init(tag: request.tag, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: kinds))))
          ready.continuation.yield(())
          ready.continuation.finish()
        } else { try await respond(request, peer, space) }
      }
      return try await group.next()!
    }
    peer.close()
    try await space.close()
    return result
  } catch {
    peer.close()
    try await space.close()
    throw error
  }
}

private func waitForFileConsumption(_ operation: UUID, channel: String, through: Int64, in space: Space) async throws {
  let watch = await watchSpaceTables(["machine_file_operations"], in: space)
  defer { watch.cancel() }
  for await _ in watch.changes {
    let row = try #require(testFileOperations(in: space).first { $0.row.id == operation.uuidString.lowercased() }?.row, "File operation disappeared before its consumption committed")
    let offset = try #require(row.offsets[channel])
    try #require(offset == 0 || offset == UInt64(through), "Unexpected file consumption offset")
    if offset == UInt64(through) { return }
  }
  try Task.checkCancellation()
  Issue.record("File consumption observation ended before the wanted offset committed")
  throw CancellationError()
}

@Suite(.deterministicDependencies(clock: VirtualClock())) struct MachineFileClientTests {
  @Test func aFullSharedBufferThrowsInsteadOfTrappingOrForwardingInput() async throws {
    let started = AsyncStream<UUID>.makeStream()
    let inputs = Mutex(0)
    _ = try await withFileBox(kinds: [ComputerKindSchemas.stagedWrite], respond: { request, peer, _ in
      switch request.exchange {
      case let .startFile(id, _):
        started.continuation.yield(id)
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
      case .fileInput: inputs.withLock { $0 += 1 }
      case .stop: peer.send(.init(tag: request.tag, answer: .box(.init(.unknownOperation))))
      default: break
      }
    }, operation: { client in
      let connection = try client.connect(.init(kind: "stagedWrite.v1", input: ["path": "/target", "replace": false]))
      defer { connection.close() }
      try await connection.ready()
      var operations = started.stream.makeAsyncIterator()
      let operation = try #require(await operations.next())
      _ = try #require(client.space.machineBuffers.put(Data(repeating: 0, count: 4 << 20), operation: operation, channel: "data", from: 65536))
      await #expect(throws: OperationError(.inputTooLarge)) {
        try await connection.write("data", .init(data: Data([1])))
      }
      #expect(inputs.withLock { $0 } == 0)
      return true
    })
  }

  @Test(arguments: [1, 2])
  func statRestartsOnceThenThrowsTypedRangeLoss(_ losses: Int) async throws {
    var starts: [UUID: Int] = [:]
    let entry: JSONValue = ["name": "file", "kind": "file", "size": 6, "token": "replacement", "mtime": 0]
    do {
      let result = try await withFileBox(kinds: [ComputerKindSchemas.stat], respond: { request, peer, _ in
        switch request.exchange {
        case let .startFile(id, start):
          #expect(start.kind == "stat.v1")
          #expect(start.input == ["path": "/file"])
          starts[id] = starts.count + 1
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        case let .poll(id, _, _, _, terminal, _):
          if terminal != nil { break }
          if starts[id]! <= losses {
            peer.send(.init(tag: request.tag, answer: .box(.init(.unknownOperation))))
          } else {
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: entry)))))
          }
        default: break
        }
      }, operation: { try await $0.vfs(.stat(path: "/file")) })
      #expect(losses == 1)
      guard case let .entry(actual) = result else { Issue.record("expected entry"); return }
      #expect(actual.name == "file")
      #expect(actual.token == "replacement")
    } catch let MachineFileFailure.rangeLost(offset) {
      #expect(losses == 2)
      #expect(offset == 0)
    }
    #expect(starts.count == 2)
  }

  @Test(arguments: [1, 2])
  func readRestartsOnceAtItsOriginalRangeAndDiscardsThePrefix(_ losses: Int) async throws {
    var reads: [UUID: Int] = [:]
    do {
      let result = try await withFileBox(kinds: [ComputerKindSchemas.read], respond: { request, peer, space in
        switch request.exchange {
        case let .startFile(id, start):
          #expect(start.kind == "read.v1")
          reads[id] = reads.count + 1
          #expect(start.input.object?["ifMatch"] == nil)
          #expect(start.input.object?["offset"] == "3")
          #expect(start.input.object?["length"] == "6")
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        case let .poll(id, channel, after, _, terminal, _):
          if terminal != nil || channel == nil { break }
          let lost = reads[id]! <= losses
          if lost, after == 3 {
            try await waitForFileConsumption(id, channel: channel!, through: 3, in: space)
            peer.send(.init(tag: request.tag, answer: .box(.init(.offsetExpired))))
          } else {
            let bytes = Data((lost ? "abc" : "defghi").utf8)
            let count = UInt64(bytes.count)
            let pointer = try #require(space.machineBuffers.put(bytes, operation: id, channel: channel!, from: 0))
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: lost ? nil : ["version": "replacement"], channel: channel, through: count, final: lost ? nil : count), output: pointer))))
          }
        default: break
        }
      }, operation: { try await $0.vfs(.read(path: "/file", offset: 3, length: 6)) })
      #expect(losses == 1)
      #expect(result == .file(token: "replacement", data: .init(Array("defghi".utf8))))
    } catch let MachineFileFailure.rangeLost(offset) {
      #expect(losses == 2)
      #expect(offset == 3)
    }
    #expect(reads.count == 2)
  }

  @Test(arguments: [1, 2])
  func listRestartsOnceFromZeroDiscardsItsPrefixAndSorts(_ losses: Int) async throws {
    var starts: [UUID: Int] = [:]
    do {
      let result = try await withFileBox(kinds: [ComputerKindSchemas.list], respond: { request, peer, space in
        switch request.exchange {
        case let .startFile(id, start):
          #expect(start.kind == "list.v1")
          #expect(start.input == ["path": "/"])
          starts[id] = starts.count + 1
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        case let .poll(id, channel, after, _, terminal, _):
          if terminal != nil || channel == nil { break }
          let lost = starts[id]! <= losses
          if lost, after == 1 {
            try await waitForFileConsumption(id, channel: channel!, through: 1, in: space)
            peer.send(.init(tag: request.tag, answer: .box(.init(.offsetExpired))))
            break
          }
          func entry(_ name: String) -> JSONValue { ["name": .string(name), "kind": "file", "size": 0, "token": "v", "mtime": 0] }
          let records = lost ? [entry("discarded")] : [entry("z"), entry("a")]
          let count = UInt64(records.count)
          let pointer = try #require(space.machineBuffers.put(payload: .init(records: records), operation: id, channel: channel!, from: 0))
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: lost ? nil : ["count": "2"], channel: channel, through: count, final: lost ? nil : count), output: pointer))))
        default: break
        }
      }, operation: { try await $0.vfs(.ls(path: "/")) })
      #expect(losses == 1)
      guard case let .entries(entries) = result else { Issue.record("expected entries"); return }
      #expect(entries.map(\.name) == ["a", "z"])
    } catch let MachineFileFailure.rangeLost(offset) {
      #expect(losses == 2)
      #expect(offset == 1)
    }
    #expect(starts.count == 2)
  }

  @Test(arguments: [1, 2])
  func searchRestartsOnceThenThrowsTypedRangeLoss(_ losses: Int) async throws {
    var starts: [UUID: Int] = [:]
    var input: JSONValue?
    do {
      let page = try await withFileBox(kinds: [ComputerKindSchemas.search], respond: { request, peer, _ in
        switch request.exchange {
        case let .startFile(id, start):
          #expect(start.kind == "search.v1")
          if let input { #expect(start.input == input) } else { input = start.input }
          starts[id] = starts.count + 1
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        case let .poll(id, _, _, _, terminal, _):
          if terminal != nil { break }
          if starts[id]! <= losses {
            peer.send(.init(tag: request.tag, answer: .box(.init(.unknownOperation))))
          } else {
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["hits": [["path": "/replacement", "line": 1, "text": "match"]], "scanned": 1, "skipped": []])))))
          }
        default: break
        }
      }, operation: { try await $0.search(.init(mode: .grep, pattern: "match", root: "/", scope: "test")) })
      #expect(losses == 1)
      #expect(page.hits.map(\.path) == ["/replacement"])
    } catch let MachineFileFailure.rangeLost(offset) {
      #expect(losses == 2)
      #expect(offset == 0)
    }
    #expect(starts.count == 2)
  }

  @Test func searchReturnsPagesAndTypesErrors() async throws {
    let page = try await withFileBox(kinds: [ComputerKindSchemas.search], respond: { request, peer, _ in
      if case let .startFile(id, _) = request.exchange {
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["hits": [["path": "/fixture", "line": 1, "text": "match"]], "scanned": 1, "skipped": []])))))
      }
    }, operation: { try await $0.search(.init(mode: .grep, pattern: "match", root: "/", scope: "test")) })
    #expect(page.hits.map(\.path) == ["/fixture"])
    let error = await #expect(throws: SearchError.self) {
      try await withFileBox(kinds: [ComputerKindSchemas.search], respond: { request, peer, _ in
        if case let .startFile(id, _) = request.exchange {
          let verdict = Verdict(.failed, error: .init(.invalidInput, message: "invalid pattern: [", details: ["search": "invalidPattern"]))
          let snapshot = OperationSnapshot(operation: id, verdict: verdict, terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: snapshot))))
        }
      }, operation: { try await $0.search(.init(mode: .grep, pattern: "[", root: "/", scope: "test")) })
    }
    #expect(error?.code == .invalidPattern)
  }

  @Test(arguments: [false, true])
  func collectedReadAndListKeepTheEightMiBBound(_ list: Bool) async throws {
    let result = try await withFileBox(kinds: [ComputerKindSchemas.read, ComputerKindSchemas.list], respond: { request, peer, space in
      switch request.exchange {
      case let .startFile(id, _):
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
      case let .poll(id, channel, after, _, terminal, _):
        if terminal != nil || channel == nil { break }
        let payload: ChannelPayload = list
          ? .init(records: [["name": .string(String(repeating: "a", count: 60000)), "kind": "file", "size": 0, "token": "v", "mtime": 0]])
          : .init(data: Data(repeating: 1, count: 65536))
        let pointer = try #require(space.machineBuffers.put(payload: payload, operation: id, channel: channel!, from: after))
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, channel: channel, from: after, through: pointer.through), output: pointer))))
      default: break
      }
    }, operation: { try await $0.vfs(list ? .ls(path: "/") : .read(path: "/file")) })
    guard case let .error(error) = result else { Issue.record("oversized collector succeeded"); return }
    #expect(error.code == .tooLarge)
  }

  @Test(arguments: [false, true])
  func missingSearchCapabilityRefusesBeforeStart(_ old: Bool) async throws {
    let kinds = old ? [KindDescriptor("find.v1", inputSchema: ["type": "object"], resultSchema: ["type": "object"])] : []
    let error = await #expect(throws: OperationError.self) {
      try await withFileBox(kinds: kinds, respond: { _, _, _ in
        Issue.record("unsupported search reached the box")
      }, operation: { try await $0.search(.init(mode: .grep, pattern: "match", root: "/", scope: "test")) })
    }
    #expect(error?.code == .kindUnavailable)
    #expect(error?.details == ["kind": "search.v1", "reason": "agentTooOld", "started": false])
  }

  @Test func filesystemFailureCategoriesStayAtTheVFSBoundary() throws {
    let cases: [(OperationError, MachineErrorCode)] = [
      (.init(.fileChanged), .conflict),
      (.init(.invalidInput), .invalidArgument),
      (.init(.resultTooLarge), .tooLarge),
      (.init(.inputTooLarge), .tooLarge),
      (.init(.recordTooLarge), .tooLarge),
      (.init(.fileUnavailable, details: ["errno": 2, "lookup": true]), .notFound),
      (.init(.fileUnavailable, details: ["errno": 13, "lookup": true]), .notFound),
      (.init(.fileUnavailable, details: ["errno": 20, "lookup": true]), .notFound),
      (.init(.fileUnavailable, details: ["errno": 17]), .conflict),
      (.init(.fileUnavailable, details: ["errno": 2]), .io),
      (.init(.fileUnavailable, details: ["errno": 13]), .io),
      (.init(.fileUnavailable), .io),
    ]
    for (error, code) in cases {
      let result = try MachineFileClient.fileError(error)
      guard case let .error(failure) = result else { Issue.record("file failure became success"); continue }
      #expect(failure.code == code)
    }
    #expect(throws: OperationError.self) { try MachineFileClient.fileError(.init(.machineUnavailable)) }
    #expect(throws: OperationError.self) { try MachineFileClient.fileError(.init(.invalidResponse)) }
  }

  @Test func invalidReadRangesRefuseBeforeStart() async throws {
    let cases: [(VFSOp, MachineErrorCode)] = [
      (.read(path: "/file", offset: -1), .invalidArgument),
      (.read(path: "/file", length: -1), .invalidArgument),
      (.read(path: "/file", length: VFSDefaults.maxReadBytes + 1), .tooLarge),
    ]
    for (op, code) in cases {
      let result = try await withFileBox(kinds: [], respond: { _, _, _ in
        Issue.record("invalid read range reached the box")
      }, operation: { try await $0.vfs(op) })
      guard case let .error(error) = result else { Issue.record("invalid range succeeded"); continue }
      #expect(error.code == code)
    }
  }

  @Test func pendingMutationDrainedBeforeDispatchIsKnownNotStartedWithoutRedo() async throws {
    let space = try Space.inMemory()
    let machine = MachineID(rawValue: "pending-file-client-test")
    let starts = Mutex(0)
    let (requests, continuation) = AsyncStream<BoxSocket.Outgoing>.makeStream()
    let pubkey = try await seedBoxKey(space: space, machine: machine.rawValue)
    let box = try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine.rawValue), opening: .init(connection: UUID(), pubkey: pubkey, streams: 64)) {
      if case let .frame(frame) = $0 {
        if case .startFile = frame.exchange { starts.withLock { $0 += 1 } }
        continuation.yield(frame)
      }
    })
    space.worker.start()
    var iterator = requests.makeAsyncIterator()
    let description = try #require(await iterator.next())
    guard case .describe = description.exchange else { Issue.record("expected description request"); return }
    try await withThrowingTaskGroup(of: OperationError?.self) { group in
      group.addTask {
        await #expect(throws: OperationError.self) {
          try await MachineFileClient(space: space, machine: machine, caller: nil).vfs(.mkdir(path: "/directory"))
        }
      }
      var pending = false
      for _ in 0 ..< 1000 {
        pending = try await space.worker.call(MachineCell.ID(machine.rawValue)) { cell in
          let callers = cell.ctx.sockets(of: FileBulk.self)
          return callers.count == 1 && callers[0].opening.request.start.kind == "mkdir.v1"
            && cell.fileOperation(callers[0].opening.request.operation)?.dispatched == false
        }
        if pending { break }
        await Task.yield()
      }
      try #require(pending)
      await space.stopWorker()
      let error = try #require(try await group.next()!)
      #expect(error.code == .machineUnavailable)
      #expect(error.details == ["started": false])
    }
    #expect(starts.withLock { $0 } == 0)
    box.close()
    continuation.finish()
    try await space.close()
  }

  @Test func mutationDoesNotRestartAfterWorkerDrain() async throws {
    var starts = 0
    do {
      _ = try await withFileBox(kinds: [ComputerKindSchemas.mkdir], respond: { request, _, space in
        if case .startFile = request.exchange {
          starts += 1
          await space.stopWorker()
        }
      }, operation: { try await $0.vfs(.mkdir(path: "/directory")) })
      Issue.record("mutation succeeded without a final result")
    } catch MachineFileFailure.outcomeUnknown {}
    #expect(starts == 1)
  }

  @Test(arguments: [0, 20, 130_000])
  func writeChunksToTheAdvertisedWindowAndSendsDigestPinAndEOF(_ count: Int) async throws {
    let bytes = Data(repeating: 7, count: count)
    let window = count == 20 ? 7 : 65536
    let kind = KindDescriptor("write.v1", inputSchema: ComputerKindSchemas.write.inputSchema, resultSchema: ComputerKindSchemas.write.resultSchema, inputChannels: [.init("data", windowBytes: window)])
    var landed = Data()
    var ended = false
    var pendingControl: (UUID, BoxTag)?
    let result = try await withFileBox(kinds: [kind], respond: { request, peer, space in
      switch request.exchange {
      case let .startFile(id, start):
        #expect(start.input.object?["path"] == "/file")
        #expect(start.input.object?["bytes"] == .string(String(count)))
        #expect(start.input.object?["ifMatch"] == "pin")
        #expect(start.input.object?["digest"] == .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
        peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
      case let .fileInput(id, pointer, end):
        let data = try #require(space.machineBuffers.payload(pointer)?.data)
        #expect(data.count <= window)
        #expect(pointer.from == UInt64(landed.count))
        landed.append(data)
        peer.send(.init(tag: request.tag, answer: .input(.init(acceptedThrough: .init(rawValue: pointer.through), end: end, blocked: false))))
        ended = end
        if end, let (operation, tag) = pendingControl {
          peer.send(.init(tag: tag, answer: .snapshot(.init(snapshot: fileSnapshot(operation, result: ["version": "written"])))))
        }
        #expect(id == pointer.operation)
      case let .poll(id, _, _, _, terminal, _):
        if terminal != nil { break }
        if ended { peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["version": "written"]))))) }
        else { pendingControl = (id, request.tag) }
      default: break
      }
    }, operation: { try await $0.vfs(.write(path: "/file", data: .init(Array(bytes)), ifMatch: "pin")) })
    #expect(result == .written(token: "written"))
    #expect(landed == bytes)
    #expect(ended)
  }

  @Test func writeDoesNotRestartAfterDispatchAndWorkerDrain() async throws {
    var starts = 0
    do {
      _ = try await withFileBox(kinds: [ComputerKindSchemas.write], respond: { request, _, space in
        if case .startFile = request.exchange { starts += 1; await space.stopWorker() }
      }, operation: { try await $0.vfs(.write(path: "/file", data: .init([1]), ifMatch: nil)) })
      Issue.record("write succeeded without a result")
    } catch MachineFileFailure.outcomeUnknown {}
    #expect(starts == 1)
  }
}
