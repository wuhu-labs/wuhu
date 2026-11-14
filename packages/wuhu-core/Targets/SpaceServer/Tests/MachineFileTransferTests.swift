#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import DeterministicDependencies
import Fetch
import enum JSONValue.JSONValue
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies(clock: ContinuousClock())) struct MachineFileTransferTests {
  /// The box every file test runs against: the largest piece the protocol allows, so each exchange carries what a real box
  /// that advertises four mebibytes sends.
  static var pieceSized: OperationLimits {
    var limits = OperationLimits()
    limits.filePieceBytes = OperationLimits.maxFilePieceBytes
    return limits
  }

  @discardableResult func withMachines<T: Sendable>(
    _ machines: [String: [AnyOperationKind]],
    limits: OperationLimits = MachineFileTransferTests.pieceSized,
    intercept: @escaping @Sendable (String, Request) async throws -> Void = { _, _ in },
    interceptResponse: @escaping @Sendable (String, Request, Response) async throws -> Response = { _, _, response in response },
    body: (MachineFileTransfer) async throws -> T,
  ) async throws -> T {
    try await withLiveDate {
      let space = try Space.inMemory()
      var agents: [OperationAgent] = []
      var links: [(BoxLink, FetchClient)] = []
      for (name, kinds) in machines {
        let agent = try OperationAgent(machine: name, kinds: kinds, limits: limits, authorize: { _, _ in })
        agents.append(agent)
        let pubkey = try await seedBoxKey(space: space, machine: name)
        let link = try #require(BoxLink(worker: space.worker, machine: name, pubkey: pubkey, connection: UUID(), streams: 1024, buffers: space.machineBuffers) { _ in preconditionFailure("file-only fixture") })
        links.append((link, FetchClient { request in
          try await intercept(name, request)
          let response = try await agent.handler(request)
          return try await interceptResponse(name, request, response)
        }))
      }
      space.worker.start()
      return try await withThrowingTaskGroup(of: Void.self) { group in
        for agent in agents { group.addTask { await agent.run() } }
        for (link, client) in links { group.addTask { await link.run(client: client) } }
        let result: Result<T, any Error>
        do {
          for name in machines.keys { try await waitForMachineDescription(MachineCell.ID(name), in: space) }
          result = .success(try await body(MachineFileTransfer(space: space, caller: nil)))
        } catch { result = .failure(error) }
        for (link, _) in links { link.close() }
        for agent in agents { await agent.shutdown() }
        group.cancelAll()
        try await group.waitForAll()
        try await space.close()
        return try result.get()
      }
    }
  }

  func sha256(_ bytes: some DataProtocol) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

  let a = MachineID(rawValue: "a"), b = MachineID(rawValue: "b")

  @Test func aFileCrossesMachinesWholeWithItsHashAndTheTargetsVersion() async throws {
    let folder = try ScratchFolder("copy-cross")
    let source = folder.url.appending(path: "source.bin").path, target = folder.url.appending(path: "target.bin").path
    let bytes = Data((0 ..< 3_000_000).map { UInt8(($0 * 7) % 253) })
    try bytes.write(to: URL(fileURLWithPath: source))
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()]) { transfer in
      try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
    }
    #expect(receipt.bytes == bytes.count)
    #expect(receipt.sha256 == sha256(bytes))
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.url.path)) == ["source.bin", "target.bin"])
    guard case let .machine(token) = receipt.landing else { Issue.record("expected a machine landing"); return }
    #expect(!token.isEmpty)
  }

  /// What one exchange with a box carried.
  enum Exchange: Hashable {
    case describe, start(kind: String), piece(bytes: Int), inputEnd, commit, terminalAck
    /// A poll answered without a piece: its hold ran out, or it brought the verdict or a channel's end.
    case poll
  }

  static func exchange(_ request: Request, _ response: Response) async throws -> Exchange {
    let path = Array(request.url.pathComponents.dropFirst(5))
    switch (request.method, path.count) {
    case (.get, 0): return .describe
    case (.post, 2): return try await .start(kind: #require(request.body?.replay()).json(StartRequest.self).kind)
    case (.get, 2):
      if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "terminalAck" }) == true { return .terminalAck }
      let bytes = try await #require(response.body.replay()).json(OperationSnapshot.self).payload?.byteCount ?? 0
      return bytes > 0 ? .piece(bytes: bytes) : .poll
    case (.put, 4) where path[3] == "commit": return .commit
    case (.put, 4) where path[3] == "data":
      let write = try await #require(request.body?.replay()).json(WriteRequest.self)
      if write.payload.byteCount > 0 { return .piece(bytes: write.payload.byteCount) }
      #expect(write.end, "an empty input that does not end its channel")
      return .inputEnd
    default:
      Issue.record("unexpected exchange \(request.method) \(request.url.path)")
      return .poll
    }
  }

  /// A copy moves one whole piece per exchange on each side: a 100 MiB file of 4 MiB pieces is 25 of them. Every other
  /// exchange is one of a fixed few, except the polls whose holds a slow host lets run out.
  @Test(.timeLimit(.minutes(1))) func aHundredMiBCopyMovesInOnePieceExchanges() async throws {
    let folder = try ScratchFolder("copy-hundred")
    let source = folder.url.appending(path: "source.bin").path, target = folder.url.appending(path: "target.bin").path
    let piece = 4 * 1024 * 1024
    var limits = OperationLimits()
    limits.filePieceBytes = piece
    limits.leaseMs = 3_600_000
    let chunk = Data((0 ..< piece).map { UInt8(($0 * 7) % 251) })
    var content = Data(capacity: 25 * piece)
    for _ in 0 ..< 25 { content.append(chunk) }
    try content.write(to: URL(fileURLWithPath: source))
    let exchanges = Mutex<[String: [Exchange: Int]]>([:])
    let (acks, acked) = AsyncStream<Void>.makeStream()
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()], limits: limits, interceptResponse: { name, request, response in
      let exchange = try await Self.exchange(request, response)
      if exchange != .poll { exchanges.withLock { $0[name, default: [:]][exchange, default: 0] += 1 } }
      if exchange == .terminalAck { acked.yield() }
      return response
    }) { transfer in
      let receipt = try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
      // The copy returns on the target's verdict, before every terminal acknowledgement need have reached its box.
      for await _ in acks.prefix(3) {}
      return receipt
    }
    #expect(receipt.bytes == 25 * piece)
    #expect(receipt.sha256 == sha256(try Data(contentsOf: URL(fileURLWithPath: target))))
    let counted = exchanges.withLock { $0 }
    let sourced = try #require(counted["a"])
    var landed = try #require(counted["b"])
    #expect(sourced == [.describe: 1, .start(kind: "stat.v1"): 1, .start(kind: "read.v1"): 1, .piece(bytes: piece): 25, .terminalAck: 2], "\(sourced)")
    // The data channel's end rides the last piece, or follows it alone when the source's end arrives after that piece.
    let inputEnds = landed.removeValue(forKey: .inputEnd) ?? 0
    #expect(inputEnds <= 1)
    #expect(landed == [.describe: 1, .start(kind: "stagedWrite.v1"): 1, .piece(bytes: piece): 25, .commit: 1, .terminalAck: 1], "\(landed)")
  }

  /// A box that advertises today's limits keeps moving 64 KiB pieces: the piece is what it advertises, not a constant.
  @Test func aBoxAtTodaysLimitsStillMovesSixtyFourKiBPieces() async throws {
    let folder = try ScratchFolder("copy-today")
    let source = folder.url.appending(path: "source.bin").path, target = folder.url.appending(path: "target.bin").path
    let bytes = Data((0 ..< 1024 * 1024).map { UInt8(($0 * 13) % 251) })
    try bytes.write(to: URL(fileURLWithPath: source))
    let exchanges = Mutex<[String: [Int]]>([:])
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()], limits: OperationLimits(), intercept: { name, request in
      exchanges.withLock { $0[name, default: []].append(Int(request.body?.contentLength ?? 0)) }
    }) { transfer in
      try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
    }
    #expect(receipt.bytes == bytes.count)
    let sizes = try #require(exchanges.withLock { $0["b"] })
    // 1 MiB in 64 KiB pieces; a write request carries one piece base64-encoded inside the snapshot.
    #expect(sizes.count >= 16, "b exchanged only \(sizes.count) times")
    #expect((sizes.max() ?? 0) <= 64 * 1024 * 4 / 3 + 4096, "b moved a piece of \(sizes.max() ?? 0) bytes")
  }

  /// A box whose piece sits between the response cap and twice it still moves whole pieces: the answer frame follows the
  /// poll's limit, so a piece that base64-encodes past 256 KiB is not refused.
  @Test(.timeLimit(.minutes(1))) func aBoxWithPiecesBetweenTheCapsMovesWholePieces() async throws {
    let folder = try ScratchFolder("copy-200k")
    let source = folder.url.appending(path: "source.bin").path, target = folder.url.appending(path: "target.bin").path
    let bytes = Data((0 ..< 1024 * 1024).map { UInt8(($0 * 11) % 251) })
    try bytes.write(to: URL(fileURLWithPath: source))
    var limits = OperationLimits()
    limits.filePieceBytes = 200 * 1024
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()], limits: limits) { transfer in
      try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
    }
    #expect(receipt.bytes == bytes.count)
    #expect(receipt.sha256 == sha256(bytes))
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
  }

  @Test func anExistingTargetIsRefusedUnlessReplacedAndThenReplacedWhole() async throws {
    let folder = try ScratchFolder("copy-exists")
    let target = folder.url.appending(path: "target.txt").path
    try Data("original".utf8).write(to: URL(fileURLWithPath: target))
    try await withMachines(["b": fileOperationKinds()]) { transfer in
      await #expect(throws: CopyRefusal.targetExists) {
        try await transfer.copy(from: .bytes(Array("next".utf8)), to: .machine(b, path: target, replace: false))
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("original".utf8))
      let receipt = try await transfer.copy(from: .bytes(Array("next".utf8)), to: .machine(b, path: target, replace: true))
      #expect(receipt.bytes == 4)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("next".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["target.txt"])
  }

  /// A listing answers records on a 256 KiB channel: the poll asks for the channel's window, not the box's piece, which on a
  /// four-mebibyte box the box refuses.
  @Test func aListingOnAFourMebibyteBoxDeliversItsEntries() async throws {
    let folder = try ScratchFolder("list-piece")
    let directory = folder.url.appending(path: "dir")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let names = (0 ..< 8).map { "entry-\($0)" }
    for name in names { try Data(name.utf8).write(to: directory.appending(path: name)) }
    try await withMachines(["a": fileOperationKinds()]) { transfer in
      let client = MachineFileClient(space: transfer.space, machine: a, caller: nil)
      let result = try await client.vfs(.ls(path: directory.path))
      guard case let .entries(entries) = result else { Issue.record("expected entries"); return }
      #expect(entries.map(\.name).sorted() == names)
    }
  }

  @Test func aCopyCancelledHalfwayLeavesNothingAtItsTarget() async throws {
    let folder = try ScratchFolder("copy-cut")
    let target = folder.url.appending(path: "target.bin").path
    let inputs = Mutex(0)
    let (halfway, reached) = AsyncStream<Void>.makeStream()
    let (cancelled, cancelling) = AsyncStream<Void>.makeStream()
    try await withMachines(["b": fileOperationKinds()], intercept: { _, request in
      guard request.method == .put, request.url.path.hasSuffix("/inputs/data"), inputs.withLock({ $0 += 1; return $0 }) == 3 else { return }
      reached.yield()
      for await _ in cancelled {}
    }) { transfer in
      let copy = Task { try await transfer.copy(from: .bytes(Array(repeating: 7, count: 3 * OperationLimits.maxFilePieceBytes)), to: .machine(b, path: target, replace: false)) }
      for await _ in halfway { break }
      copy.cancel()
      cancelling.finish()
      if case .success = await copy.result { Issue.record("cancelled copy succeeded") }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
  }

  @Test func aSourceChangedAfterItsStatIsRefused() async throws {
    let folder = try ScratchFolder("copy-changed")
    let source = folder.url.appending(path: "source.txt").path, target = folder.url.appending(path: "target.txt").path
    try Data("first".utf8).write(to: URL(fileURLWithPath: source))
    let starts = Mutex(0)
    try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()], intercept: { machine, request in
      guard machine == "a", request.method == .post else { return }
      if starts.withLock({ $0 += 1; return $0 }) == 2 { try Data("second, longer".utf8).write(to: URL(fileURLWithPath: source)) }
    }) { transfer in
      await #expect(throws: CopyRefusal.sourceChanged) {
        try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
      }
    }
    #expect(!FileManager.default.fileExists(atPath: target))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["source.txt"])
  }

  @Test(arguments: ["removed", "folder"])
  func aSourceGoneAfterItsStatHasChanged(_ change: String) async throws {
    let folder = try ScratchFolder("copy-gone")
    let source = folder.url.appending(path: "source.txt").path
    try Data("first".utf8).write(to: URL(fileURLWithPath: source))
    let starts = Mutex(0)
    try await withMachines(["a": fileOperationKinds()], intercept: { _, request in
      guard request.method == .post, starts.withLock({ $0 += 1; return $0 }) == 2 else { return }
      try FileManager.default.removeItem(atPath: source)
      if change == "folder" { try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: false) }
    }) { transfer in
      await #expect(throws: CopyRefusal.sourceChanged) {
        try await transfer.copy(from: .machine(a, path: source), to: .caller(limit: 64))
      }
    }
  }

  @Test func aCopyToTheCallerIsBoundedUpFrontAndRefusesFoldersAndMissingFiles() async throws {
    let folder = try ScratchFolder("copy-caller")
    let source = folder.url.appending(path: "source.txt").path
    try Data("twelve bytes".utf8).write(to: URL(fileURLWithPath: source))
    try await withMachines(["a": fileOperationKinds()]) { transfer in
      let receipt = try await transfer.copy(from: .machine(a, path: source), to: .caller(limit: 12))
      #expect(receipt == CopyReceipt(bytes: 12, sha256: sha256(Data("twelve bytes".utf8)), landing: .caller(Array("twelve bytes".utf8))))
      await #expect(throws: CopyRefusal.sourceTooLarge(size: 12, limit: 11)) {
        try await transfer.copy(from: .machine(a, path: source), to: .caller(limit: 11))
      }
      await #expect(throws: CopyRefusal.sourceNotAFile) {
        try await transfer.copy(from: .machine(a, path: folder.url.path), to: .caller(limit: 12))
      }
      await #expect(throws: CopyRefusal.missing(.source)) {
        try await transfer.copy(from: .machine(a, path: source + ".gone"), to: .caller(limit: 12))
      }
    }
  }

  @Test func anAgentWithoutStagedWritesIsNamedAsUnsupported() async throws {
    let folder = try ScratchFolder("copy-old")
    let target = folder.url.appending(path: "target.txt").path
    let old = fileOperationKinds().filter { $0.descriptor.name != "stagedWrite.v1" }
    try await withMachines(["b": old]) { transfer in
      await #expect(throws: CopyRefusal.unsupported(b)) {
        try await transfer.copy(from: .bytes([1]), to: .machine(b, path: target, replace: false))
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["TESTBRIDGE_TEST_ONLY"] == "MachineFileTransferTests/transportCopyRate()"))
  func transportCopyRate() async throws {
    let folder = try ScratchFolder("copy-rate")
    let source = folder.url.appending(path: "source.bin").path
    let target = folder.url.appending(path: "target.bin").path
    let count = 100 * 1024 * 1024
    let bytes = Data(repeating: 0x71, count: count)
    try bytes.write(to: URL(fileURLWithPath: source))
    let expectedHash = sha256(bytes)
    try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()]) { transfer in
      let clock = ContinuousClock()
      let before = clock.now
      let receipt = try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false))
      let elapsed = before.duration(to: clock.now)
      let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      print("MACHINE_FILE_COPY_RATE bytes=\(receipt.bytes) seconds=\(seconds) MiB_per_second=\(Double(count) / 1_048_576 / seconds)")
      #expect(receipt.bytes == count)
      #expect(receipt.sha256 == expectedHash)
    }
    #expect(sha256(try Data(contentsOf: URL(fileURLWithPath: target))) == expectedHash)
  }

  @Test(arguments: [false, true])
  func copyNeverRestartsALostSourceRange(_ duringRead: Bool) async throws {
    var kinds: [String] = []
    do {
      _ = try await withFileBox(kinds: [ComputerKindSchemas.stat, ComputerKindSchemas.read], respond: { request, peer, space in
        switch request.exchange {
        case let .startFile(id, start):
          kinds.append(start.kind)
          if start.kind == "stat.v1", duringRead {
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["name": "file", "kind": "file", "size": 6, "token": "pin", "mtime": 0])))))
          } else { peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id))))) }
        case let .poll(id, channel, after, _, terminal, _):
          if terminal != nil { break }
          if !duringRead || after == 3 {
            peer.send(.init(tag: request.tag, answer: .box(.init(.offsetExpired))))
          } else if let channel {
            let pointer = try #require(space.machineBuffers.put(Data("abc".utf8), operation: id, channel: channel, from: 0))
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, channel: channel, through: 3), output: pointer))))
          }
        default: break
        }
      }, operation: { client in
        try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .machine(client.machine, path: "/file"), to: .caller(limit: 64))
      })
      Issue.record("lost copy succeeded")
    } catch MachineFileFailure.rangeLost {}
    #expect(kinds == (duringRead ? ["stat.v1", "read.v1"] : ["stat.v1"]))
  }

  @Test(arguments: [2, 8])
  func statSizeMismatchNeverReturnsAPartialCopy(_ actual: Int) async throws {
    await #expect(throws: CopyRefusal.sourceChanged) {
      try await withFileBox(kinds: [ComputerKindSchemas.stat, ComputerKindSchemas.read], respond: { request, peer, space in
        switch request.exchange {
        case let .startFile(id, start):
          if start.kind == "stat.v1" {
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["name": "file", "kind": "file", "size": 6, "token": "stat-token", "mtime": 0])))))
          } else {
            #expect(start.input == ["path": "/file", "ifMatch": "stat-token"])
            peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
          }
        case let .poll(id, channel, _, _, terminal, _):
          guard terminal == nil, let channel else { break }
          let pointer = try #require(space.machineBuffers.put(Data(repeating: 7, count: actual), operation: id, channel: channel, from: 0))
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["version": "v"], channel: channel, through: UInt64(actual), final: UInt64(actual)), output: pointer))))
        default: break
        }
      }, operation: { client in
        try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .machine(client.machine, path: "/file"), to: .caller(limit: 64))
      })
    }
  }

  @Test func copyDoesNotRestartAnUnknownTargetOutcome() async throws {
    var starts = 0
    do {
      _ = try await withFileBox(kinds: [ComputerKindSchemas.stagedWrite], respond: { request, _, space in
        if case .startFile = request.exchange { starts += 1; await space.stopWorker() }
      }, operation: { client in
        try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .bytes([1, 2, 3]), to: .machine(client.machine, path: "/target", replace: true))
      })
      Issue.record("target loss succeeded")
    } catch MachineFileFailure.outcomeUnknown {}
    #expect(starts == 1)
  }

  @Test(arguments: [false, true])
  func emptySourcesStillCommitTheEmptyDigest(_ fromMachine: Bool) async throws {
    let folder = try ScratchFolder("copy-empty")
    let source = folder.url.appending(path: "source").path
    let target = folder.url.appending(path: "target").path
    try Data().write(to: URL(fileURLWithPath: source))
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()]) { transfer in
      try await transfer.copy(from: fromMachine ? .machine(a, path: source) : .bytes([]), to: .machine(b, path: target, replace: false))
    }
    #expect(receipt.bytes == 0)
    #expect(receipt.sha256 == sha256(Data()))
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)).isEmpty)
  }

  @Test func aBlockedTargetBoundsTheSourceConsumerCursorToOneReadAheadChunk() async throws {
    let folder = try ScratchFolder("copy-backpressure")
    let source = folder.url.appending(path: "source").path
    let target = folder.url.appending(path: "target").path
    let piece = OperationLimits.maxFilePieceBytes
    let bytes = Data(repeating: 9, count: 8 * piece)
    try bytes.write(to: URL(fileURLWithPath: source))
    let inputs = Mutex(0)
    let (blocked, didBlock) = AsyncStream<Void>.makeStream()
    let (released, release) = AsyncStream<Void>.makeStream()
    try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()], intercept: { machine, request in
      guard machine == "b", request.method == .put, request.url.path.hasSuffix("/inputs/data"),
            inputs.withLock({ $0 += 1; return $0 }) == 3 else { return }
      didBlock.yield()
      for await _ in released {}
    }) { transfer in
      try await withThrowingTaskGroup(of: CopyReceipt.self) { group in
        group.addTask { try await transfer.copy(from: .machine(a, path: source), to: .machine(b, path: target, replace: false)) }
        defer { release.finish(); group.cancelAll() }
        for await _ in blocked { break }
        let consumed = try await transfer.space.worker.call(MachineCell.ID(a.rawValue)) { cell in
          let caller = cell.ctx.sockets(of: FileBulk.self).first { $0.opening.request.start.kind == "read.v1" }!
          return cell.fileOperation(caller.opening.request.operation)!.offsets["data"]!
        }
        #expect((UInt64(2 * piece) ... UInt64(3 * piece)).contains(consumed))
        release.finish()
        let receipt = try #require(try await group.next())
        #expect(receipt.bytes == bytes.count)
      }
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == bytes)
  }

  @Test(arguments: ["data", "end", "commit"], [false, true])
  func terminalVerdictBeforeInputReceiptOnlyCompletesTheFinalCommit(_ stage: String, _ failed: Bool) async throws {
    let bytes = Data([1, 2, 3])
    let digest = sha256(bytes)
    var pendingControl: BoxTag?
    var inputs: [String] = []
    var terminalSent = false
    let receipt: CopyReceipt?
    do {
      receipt = try await withFileBox(kinds: [ComputerKindSchemas.stagedWrite], respond: { request, peer, space in
        switch request.exchange {
        case let .startFile(id, _):
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id)))))
        case let .poll(_, channel, _, _, terminal, _):
          if terminal == nil {
            #expect(channel == nil)
            pendingControl = request.tag
          }
        case let .fileInput(id, pointer, end):
          let payload = try #require(space.machineBuffers.payload(pointer))
          let current = pointer.channel == "commit" ? "commit" : end ? "end" : "data"
          inputs.append(current)
          switch current {
          case "data": #expect(payload.data == bytes); #expect(!end)
          case "end": #expect(payload.data == Data()); #expect(end)
          default:
            #expect(payload.records == [["bytes": "3", "sha256": .string(digest)]])
            #expect(end)
          }
          if current == stage {
            let control = try #require(pendingControl)
            let verdict = failed ? Verdict(.failed, error: .init(.fileUnavailable, details: ["errno": 17])) : Verdict(.completed, result: ["version": "committed"])
            let snapshot = OperationSnapshot(operation: id, verdict: verdict, terminalToken: UUID(), finalOffsets: [:], outputConsumed: false)
            peer.send(.init(tag: control, answer: .snapshot(.init(snapshot: snapshot))))
            terminalSent = true
          }
          peer.send(.init(tag: request.tag, answer: .input(.init(acceptedThrough: .init(rawValue: pointer.through), end: end, blocked: false))))
        default: break
        }
      }, operation: { client in
        try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .bytes(Array(bytes)), to: .machine(client.machine, path: "/target", replace: false))
      })
    } catch let error as CopyRefusal {
      #expect(failed)
      #expect(error == .targetExists)
      receipt = nil
    } catch let error as OperationError {
      #expect(!failed && stage != "commit")
      #expect(error.code == .operationEnded)
      receipt = nil
    }
    #expect(terminalSent)
    #expect(inputs == (stage == "data" ? ["data"] : stage == "end" ? ["data", "end"] : ["data", "end", "commit"]))
    #expect(receipt == (!failed && stage == "commit" ? CopyReceipt(bytes: bytes.count, sha256: digest, landing: .machine(token: "committed")) : nil))
  }

  @Test func aRefusedTargetDoesNotStartThePinnedSourceRead() async throws {
    var kinds: [String] = []
    let unsupported = await #expect(throws: CopyRefusal.self) {
      try await withFileBox(kinds: [ComputerKindSchemas.stat, ComputerKindSchemas.read], respond: { request, peer, _ in
        if case let .startFile(id, start) = request.exchange {
          kinds.append(start.kind)
          #expect(start.kind == "stat.v1")
          peer.send(.init(tag: request.tag, answer: .snapshot(.init(snapshot: fileSnapshot(id, result: ["name": "file", "kind": "file", "size": 6, "token": "pin", "mtime": 0])))))
        }
      }, operation: { client in
        try await MachineFileTransfer(space: client.space, caller: nil).copy(from: .machine(client.machine, path: "/source"), to: .machine(client.machine, path: "/target", replace: false))
      })
    }
    #expect(unsupported == .unsupported(.init(rawValue: "file-client-test")))
    #expect(kinds == ["stat.v1"])
  }
}
