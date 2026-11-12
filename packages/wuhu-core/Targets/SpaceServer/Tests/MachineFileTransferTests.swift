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
  @discardableResult func withMachines<T: Sendable>(
    _ machines: [String: [AnyOperationKind]],
    intercept: @escaping @Sendable (String, Request) async throws -> Void = { _, _ in },
    interceptResponse: @escaping @Sendable (String, Request, Response) async throws -> Response = { _, _, response in response },
    body: (MachineFileTransfer) async throws -> T,
  ) async throws -> T {
    try await withLiveDate {
      let space = try Space.inMemory()
      var agents: [OperationAgent] = []
      var links: [(BoxLink, FetchClient)] = []
      for (name, kinds) in machines {
        let agent = try OperationAgent(machine: name, kinds: kinds, authorize: { _, _ in })
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
        do { result = .success(try await body(MachineFileTransfer(space: space, caller: nil))) }
        catch { result = .failure(error) }
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
      let copy = Task { try await transfer.copy(from: .bytes(Array(repeating: 7, count: 1_000_000)), to: .machine(b, path: target, replace: false)) }
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
    let bytes = Data(repeating: 9, count: 400_000)
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
        #expect((2 * 65536 ... 3 * 65536).contains(consumed))
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
