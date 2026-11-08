#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import enum JSONValue.JSONValue
import MachineContract
import OperationClient
import OperationProtocol
import OperationRuntime
import Scratch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(2))) struct CopyTests {
  /// One agent and one client per named machine, as the hub keeps one client per group; `intercept` sees every request a
  /// client sends to its machine and may refuse it. Every agent has wound down, its stages closed, when this returns.
  @discardableResult func withMachines<T: Sendable>(
    _ machines: [String: [AnyOperationKind]],
    intercept: @escaping @Sendable (String, Request) async throws -> Void = { _, _ in },
    body: (@escaping @Sendable (MachineID) async throws -> MachineOperations) async throws -> T,
  ) async throws -> T {
    var agents: [OperationAgent] = []
    var clients: [String: MachineOperations] = [:]
    for (name, kinds) in machines {
      let agent = try OperationAgent(machine: name, kinds: kinds, authorize: { _, _ in })
      agents.append(agent)
      clients[name] = try machineOperations { request in
        try await intercept(name, request)
        return try await agent.handler(request)
      }
    }
    let operations = clients
    return try await withThrowingTaskGroup(of: Void.self) { group in
      for agent in agents { group.addTask { await agent.run() } }
      let result: Result<T, any Error>
      do { result = .success(try await body { machine in try #require(operations[machine.rawValue]) }) } catch { result = .failure(error) }
      for client in operations.values { await client.shutdown() }
      for agent in agents { await agent.shutdown() }
      try await group.waitForAll()
      return try result.get()
    }
  }

  func sha256(_ bytes: some DataProtocol) -> String { SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }

  let a = MachineID(rawValue: "a"), b = MachineID(rawValue: "b")

  @Test func aFileCrossesMachinesWholeWithItsHashAndTheTargetsVersion() async throws {
    let folder = try ScratchFolder("copy-cross")
    let source = folder.url.appending(path: "source.bin").path, target = folder.url.appending(path: "target.bin").path
    let bytes = Data((0 ..< 3_000_000).map { UInt8(($0 * 7) % 253) })
    try bytes.write(to: URL(fileURLWithPath: source))
    let receipt = try await withMachines(["a": fileOperationKinds(), "b": fileOperationKinds()]) { operations in
      try await copyFile(from: .machine(a, path: source), to: .machine(b, path: target, replace: false), operations: operations)
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
    try await withMachines(["b": fileOperationKinds()]) { operations in
      await #expect(throws: CopyRefusal.targetExists) {
        try await copyFile(from: .bytes(Array("next".utf8)), to: .machine(b, path: target, replace: false), operations: operations)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("original".utf8))
      let receipt = try await copyFile(from: .bytes(Array("next".utf8)), to: .machine(b, path: target, replace: true), operations: operations)
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
    }) { operations in
      let copy = Task { try await copyFile(from: .bytes(Array(repeating: 7, count: 1_000_000)), to: .machine(b, path: target, replace: false), operations: operations) }
      for await _ in halfway { break }
      copy.cancel()
      cancelling.finish()
      #expect(await copy.result.isFailure)
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
    }) { operations in
      await #expect(throws: CopyRefusal.sourceChanged) {
        try await copyFile(from: .machine(a, path: source), to: .machine(b, path: target, replace: false), operations: operations)
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
    }) { operations in
      await #expect(throws: CopyRefusal.sourceChanged) {
        try await copyFile(from: .machine(a, path: source), to: .caller(limit: 64), operations: operations)
      }
    }
  }

  @Test func aCopyToTheCallerIsBoundedUpFrontAndRefusesFoldersAndMissingFiles() async throws {
    let folder = try ScratchFolder("copy-caller")
    let source = folder.url.appending(path: "source.txt").path
    try Data("twelve bytes".utf8).write(to: URL(fileURLWithPath: source))
    try await withMachines(["a": fileOperationKinds()]) { operations in
      let receipt = try await copyFile(from: .machine(a, path: source), to: .caller(limit: 12), operations: operations)
      #expect(receipt == CopyReceipt(bytes: 12, sha256: sha256(Data("twelve bytes".utf8)), landing: .caller(Array("twelve bytes".utf8))))
      await #expect(throws: CopyRefusal.sourceTooLarge(size: 12, limit: 11)) {
        try await copyFile(from: .machine(a, path: source), to: .caller(limit: 11), operations: operations)
      }
      await #expect(throws: CopyRefusal.sourceNotAFile) {
        try await copyFile(from: .machine(a, path: folder.url.path), to: .caller(limit: 12), operations: operations)
      }
      await #expect(throws: CopyRefusal.missing(.source)) {
        try await copyFile(from: .machine(a, path: source + ".gone"), to: .caller(limit: 12), operations: operations)
      }
    }
  }

  @Test func anAgentWithoutStagedWritesIsNamedAsUnsupported() async throws {
    let folder = try ScratchFolder("copy-old")
    let target = folder.url.appending(path: "target.txt").path
    let old = fileOperationKinds().filter { $0.descriptor.name != "stagedWrite.v1" }
    try await withMachines(["b": old]) { operations in
      await #expect(throws: CopyRefusal.unsupported(b)) {
        try await copyFile(from: .bytes([1]), to: .machine(b, path: target, replace: false), operations: operations)
      }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
  }

  @Test(arguments: ["digest", "length", "missing"])
  func aStagedWriteLandsOnlyOnAMatchingCommit(_ commit: String) async throws {
    let folder = try ScratchFolder("staged-commit")
    let target = folder.url.appending(path: "target.txt").path
    let bytes = Data("staged".utf8)
    let ending = try await withMachines(["b": fileOperationKinds()]) { operations in
      let operation = try await operations(b).open(.init(scope: "test", key: commit), machine: "b", start: .init(kind: "stagedWrite.v1", input: ["path": .string(target), "replace": false]))
      try await operation.write("data", .init(data: bytes), end: true)
      let record: JSONValue = switch commit {
      case "digest": ["bytes": .string(String(bytes.count)), "sha256": .string(String(repeating: "0", count: 64))]
      case "length": ["bytes": .string(String(bytes.count + 1)), "sha256": .string(sha256(bytes))]
      default: ["bytes": .string(String(bytes.count)), "sha256": .string(sha256(bytes))]
      }
      try await operation.write("commit", commit == "missing" ? .init(records: []) : .init(records: [record]), end: true)
      return try await operation.verdict()
    }
    #expect(ending.tag == .failed)
    #expect(ending.error?.code == .invalidInput)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
  }
}

extension Result {
  fileprivate var isFailure: Bool { if case .failure = self { true } else { false } }
}
