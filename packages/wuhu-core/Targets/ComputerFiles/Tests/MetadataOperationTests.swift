#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import Crypto
import Dispatch
import Fetch
import enum JSONValue.JSONValue
import MachineContract
@testable import OperationClient
import OperationProtocol
import OperationRuntime
import Scratch
import Synchronization
import Testing

@Suite struct MetadataOperationTests {
  func withClient<T: Sendable>(files: ComputerFileSystem = .local, fetch: (@Sendable (Request, @escaping @Sendable (Request) async throws -> Response) async throws -> Response)? = nil, body: (OperationClient) async throws -> T) async throws -> T {
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init { request in
      if let fetch { return try await fetch(request, agent.handler) }
      return try await agent.handler(request)
    }, store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      do { _ = try await client.describe("disk"); let result = try await body(client); await client.shutdown(); await agent.shutdown(); return result }
      catch { await client.shutdown(); await agent.shutdown(); throw error }
    }
  }

  func owner(_ key: String = UUID().uuidString) -> OperationOwner { .init(scope: "files", key: key) }

  @Test func allKindsRoundTripWithLargeStreamedWriteAndReadToken() async throws {
    let folder = try ScratchFolder("metadata-kinds")
    let directory = folder.url.appending(path: "nested/child").path
    let path = directory + "/file"
    let moved = directory + "/moved"
    let bytes = Data((0 ..< 400_000).map { UInt8($0 % 251) })
    try await withClient { client in
      try await client.mkdir(machine: "disk", path: directory, owner: owner())
      let token = try await client.writeFile(machine: "disk", path: path, data: bytes, owner: owner())
      let entry = try await client.stat(machine: "disk", path: path, owner: owner())
      #expect(entry.kind == .file); #expect(entry.size == bytes.count); #expect(entry.token == token); #expect(entry.mtime > 0)
      #expect(try await client.list(machine: "disk", path: directory, owner: owner()) == [entry])
      let read = try await client.vfs(machine: "disk", op: .read(path: path), owner: owner())
      #expect(read == .file(token: token, data: .init([UInt8](bytes))))
      let next = try await client.writeFile(machine: "disk", path: path, data: Data("replaced".utf8), ifMatch: token, owner: owner())
      #expect(next != token)
      let conflict = try await client.vfs(machine: "disk", op: .write(path: path, data: .init([1]), ifMatch: token), owner: owner())
      guard case let .error(error) = conflict else { Issue.record("expected conflict"); return }
      #expect(error.code == .conflict)
      try await client.move(machine: "disk", from: path, to: moved, owner: owner())
      try await client.remove(machine: "disk", path: folder.url.appending(path: "nested").path, owner: owner())
      #expect(!FileManager.default.fileExists(atPath: moved))
    }
  }

  @Test func filesystemFailuresPreserveV1Categories() async throws {
    let folder = try ScratchFolder("metadata-errors")
    let a = folder.url.appending(path: "a").path; let b = folder.url.appending(path: "b").path
    try Data([1]).write(to: URL(fileURLWithPath: a)); try Data([2]).write(to: URL(fileURLWithPath: b))
    try await withClient { client in
      for (op, code) in [(VFSOp.stat(path: b + "-missing"), MachineErrorCode.notFound), (.rm(path: b + "-missing", ifMatch: "stale"), .conflict), (.mv(from: a, to: b), .conflict), (.read(path: a, offset: -1), .invalidArgument), (.read(path: a, length: VFSDefaults.maxReadBytes + 1), .tooLarge)] {
        let result = try await client.vfs(machine: "disk", op: op, owner: owner())
        guard case let .error(error) = result else { Issue.record("expected error for \(op)"); continue }
        #expect(error.code == code)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: a)) == Data([1])); #expect(try Data(contentsOf: URL(fileURLWithPath: b)) == Data([2]))
    }
  }

  @Test func listStreamsBeyondResultCapAndReportsSymlinkItself() async throws {
    let folder = try ScratchFolder("metadata-list")
    for index in 0 ..< 500 { try Data().write(to: folder.url.appending(path: String(format: "%04d", index))) }
    let link = folder.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url)
    try await withClient { client in
      let entries = try await client.list(machine: "disk", path: folder.url.path, owner: owner())
      #expect(entries.count == 501); #expect(entries.last?.kind == .symlink)
      #expect(try await client.stat(machine: "disk", path: link.path, owner: owner()).kind == .symlink)
      await #expect(throws: OperationError.self) { try await client.list(machine: "disk", path: link.path + "/", owner: owner()) }
      await #expect(throws: OperationError.self) { try await client.writeFile(machine: "disk", path: link.path, data: Data(), owner: owner()) }
      try await client.remove(machine: "disk", path: link.path, owner: owner())
      #expect(FileManager.default.fileExists(atPath: folder.url.path))
    }
  }

  @Test func repeatedOwnerNeverWritesTwiceAndChangedPayloadConflicts() async throws {
    let folder = try ScratchFolder("metadata-owner")
    let path = folder.url.appending(path: "file").path
    let key = owner()
    try await withClient { client in
      let token = try await client.writeFile(machine: "disk", path: path, data: Data([1]), owner: key)
      #expect(try await client.writeFile(machine: "disk", path: path, data: Data([1]), owner: key) == token)
      await #expect(throws: OperationError.self) { try await client.writeFile(machine: "disk", path: path, data: Data([2]), owner: key) }
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([1]))
    }
  }

  @Test func lostInputReceiptRetriesIdenticalOffsetWithoutDuplicateBytes() async throws {
    let folder = try ScratchFolder("metadata-input-retry")
    let path = folder.url.appending(path: "file").path
    let dropped = Mutex(false); let starts = Mutex(0)
    let bytes = Data(repeating: 42, count: 200_000)
    try await withClient(fetch: { request, handler in
      if request.method == .post { starts.withLock { $0 += 1 } }
      let response = try await handler(request)
      if request.url.path.contains("/inputs/"), dropped.withLock({ if $0 { return false }; $0 = true; return true }) { throw OperationError(.transport) }
      return response
    }) { client in
      _ = try await client.writeFile(machine: "disk", path: path, data: bytes, owner: owner())
    }
    #expect(starts.withLock { $0 } == 1); #expect(dropped.withLock { $0 }); #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
  }
}

extension MetadataOperationTests {
  @Test func injectedFilesystemReplaysExactEffectsThroughProductionHandlers() async throws {
    let events = Mutex<[String]>([])
    let cursor = Mutex(0)
    let entry = MachineEntry(name: "file", kind: .file, size: 3, token: "recorded-token", mtime: 123)
    let operations = ComputerFileOperations(stat: { path in events.withLock { $0.append("stat \(path)") }; return entry }, list: { path in
      events.withLock { $0.append("list \(path)") }
      return .init(next: { cursor.withLock { count in defer { count += 1 }; return count == 0 ? entry : nil } }, close: { events.withLock { $0.append("list close") } })
    }, write: { path, token in
      events.withLock { $0.append("write \(path) \(token ?? "nil")") }
      return .init(append: { data in events.withLock { $0.append("append \(data.base64EncodedString())") } }, commit: { events.withLock { $0.append("commit") }; return "new-token" }, close: { events.withLock { $0.append("write close") } })
    }, mkdir: { path in events.withLock { $0.append("mkdir \(path)") } }, remove: { path, token in events.withLock { $0.append("remove \(path) \(token ?? "nil")") } }, move: { from, to in events.withLock { $0.append("move \(from) \(to)") } })
    let files = ComputerFileSystem(status: { _ in throw OperationError(.fileUnavailable) }, read: { _, _, _ in throw OperationError(.fileUnavailable) }, walk: { _, _ in throw OperationError(.fileUnavailable) }, operations: operations)
    try await withClient(files: files) { client in
      #expect(try await client.stat(machine: "disk", path: "/file", owner: owner()) == entry)
      #expect(try await client.list(machine: "disk", path: "/", owner: owner()) == [entry])
      #expect(try await client.writeFile(machine: "disk", path: "/file", data: Data([1, 2, 3]), ifMatch: "recorded-token", owner: owner()) == "new-token")
      try await client.mkdir(machine: "disk", path: "/dir", owner: owner())
      try await client.remove(machine: "disk", path: "/file", ifMatch: "new-token", owner: owner())
      try await client.move(machine: "disk", from: "/a", to: "/b", owner: owner())
    }
    #expect(events.withLock { $0 } == ["stat /file", "list /", "list close", "write /file recorded-token", "append AQID", "commit", "write close", "mkdir /dir", "remove /file new-token", "move /a /b"])
  }

  @Test(arguments: ["stop", "lease", "digest"])
  func incompleteOrInvalidWriteNeverReplacesTargetAndCleansStage(_ action: String) async throws {
    let folder = try ScratchFolder("metadata-abort")
    let path = folder.url.appending(path: "file").path
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))
    let time = MetadataTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(), clock: time.clock, authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init(fetch: agent.handler), store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let id = try await client.start("disk", request: .init(kind: "write.v1", input: ["path": .string(path), "bytes": "4", "digest": .string(String(repeating: "0", count: 64))]), owner: owner())
      _ = try await client.write(id, channel: "data", payload: .init(data: Data([1, 2, 3, 4])), end: action == "digest")
      if action == "stop" { _ = try await client.stop(id, reason: "testStop") }
      if action == "lease" { time.advance(.seconds(61)) }
      var end = try await client.reconcile(id)
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      while end.verdict == nil && ContinuousClock().now < deadline { await Task.yield(); end = try await client.reconcile(id) }
      #expect(end.verdict?.tag == (action == "digest" ? .failed : .stopped))
      #expect(end.verdict?.error?.code == (action == "digest" ? .invalidInput : nil))
      await client.shutdown(); await agent.shutdown()
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["file"])
  }

  @Test func writerRechecksTokenAtCommitAndEmptyWriteWorks() async throws {
    let folder = try ScratchFolder("metadata-write-check")
    let path = folder.url.appending(path: "file").path
    try Data([1]).write(to: URL(fileURLWithPath: path))
    let token = try await ComputerFileSystem.local.status(path).version
    let writer = try await ComputerFileSystem.local.operations.write(path, token)
    try await writer.append(Data([2]))
    try Data([3, 4]).write(to: URL(fileURLWithPath: path))
    await #expect(throws: OperationError.self) { try await writer.prepare(); _ = try await writer.commit() }
    await writer.close()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([3, 4]))
    try await withClient { client in
      _ = try await client.writeFile(machine: "disk", path: path, data: Data(), owner: owner())
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
    }
  }
}

private final class MetadataTime: Sendable {
  private let value = Mutex<Duration>(.zero)
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { try await OperationClock.continuous.sleep($0) }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

extension MetadataOperationTests {
  @Test(arguments: ["sync-stop", "sync-lease", "rename-stop", "rename-lease"])
  func renameCommitPointDeterminesVerdictWhenStoppedDuringCommit(_ action: String) async throws {
    let folder = try ScratchFolder("metadata-commit-stop")
    let path = folder.url.appending(path: "file").path
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))
    let reached = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal(); reached.continuation.finish() }
    var operations = ComputerFileOperations.local(synchronize: { _ in
      if action.hasPrefix("sync") { reached.continuation.yield(); release.wait() }
    })
    if action.hasPrefix("rename") {
      let local = operations
      operations = .init(stat: local.stat, list: local.list, write: { path, token in
        let writer = try await local.write(path, token)
        return .init(append: writer.append, prepare: writer.prepare, commit: {
          let version = try await writer.commit()
          reached.continuation.yield()
          await diskIO { release.wait() }
          return version
        }, close: writer.close)
      }, mkdir: local.mkdir, remove: local.remove, move: local.move)
    }
    let files = ComputerFileSystem(status: ComputerFileSystem.local.status, read: ComputerFileSystem.local.read, walk: ComputerFileSystem.local.walk, operations: operations)
    let time = MetadataTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), clock: time.clock, authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init(fetch: agent.handler), store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let bytes = Data("replacement".utf8)
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let id = try await client.start("disk", request: .init(kind: "write.v1", input: ["path": .string(path), "bytes": .string(String(bytes.count)), "digest": .string(digest)]), owner: owner())
      _ = try await client.write(id, channel: "data", payload: .init(data: bytes), end: true)
      for await _ in reached.stream { break }
      if action.hasSuffix("stop") { _ = try await client.stop(id, reason: "commitStop") }
      else { time.advance(.seconds(61)); _ = try await client.reconcile(id) }
      release.signal()
      var snapshot = try await client.reconcile(id)
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      while snapshot.verdict == nil && ContinuousClock().now < deadline { await Task.yield(); snapshot = try await client.reconcile(id) }
      #expect(snapshot.verdict?.tag == (action.hasPrefix("sync") ? .stopped : .completed))
      if action.hasPrefix("rename") {
        #expect(snapshot.verdict?.reason == nil)
        #expect(snapshot.verdict?.result != nil)
      }
      await client.shutdown(); await agent.shutdown()
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data((action.hasPrefix("sync") ? "original" : "replacement").utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["file"])
  }

  @Test func readOnlyTargetFailsWithoutReplacementAndWritableModeIsPreserved() async throws {
    let folder = try ScratchFolder("metadata-permissions")
    let path = folder.url.appending(path: "file")
    try Data([1]).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
    try await withClient { client in
      let result = try await client.vfs(machine: "disk", op: .write(path: path.path, data: .init([2]), ifMatch: nil), owner: owner())
      guard case let .error(error) = result else { Issue.record("read-only target was replaced"); return }
      #expect(error.code == .io)
      #expect(try Data(contentsOf: path) == Data([1]))
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["file"])
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
      _ = try await client.vfs(machine: "disk", op: .write(path: path.path, data: .init([3]), ifMatch: nil), owner: owner())
      #expect(try Data(contentsOf: path) == Data([3]))
      #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) == 0o640)
    }
  }

  @Test func sourceLookupFailuresMatchV1WithoutMisclassifyingMutationPermissionErrors() async throws {
    let folder = try ScratchFolder("metadata-lookup-errors")
    let file = folder.url.appending(path: "file")
    let denied = folder.url.appending(path: "denied")
    try Data([1]).write(to: file)
    try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
    try Data([2]).write(to: denied.appending(path: "child"))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
    try await withClient { client in
      for source in [file.path + "/child", denied.appending(path: "child").path] {
        for op in [VFSOp.stat(path: source), .ls(path: source), .read(path: source), .rm(path: source, ifMatch: nil), .mv(from: source, to: folder.url.appending(path: "moved").path)] {
          let result = try await client.vfs(machine: "disk", op: op, owner: owner())
          guard case let .error(error) = result else { Issue.record("lookup unexpectedly succeeded"); continue }
          #expect(error.code == .notFound)
        }
        let guarded = try await client.vfs(machine: "disk", op: .rm(path: source, ifMatch: "expected"), owner: owner())
        guard case let .error(error) = guarded else { Issue.record("guarded lookup unexpectedly succeeded"); continue }
        #expect(error.code == .conflict)
      }
      let result = try await client.vfs(machine: "disk", op: .mv(from: file.path, to: denied.appending(path: "destination").path), owner: owner())
      guard case let .error(error) = result else { Issue.record("mutation into denied directory succeeded"); return }
      #expect(error.code == .io)
    }
  }
}

extension MetadataOperationTests {
  @Test func missingDestinationParentsAreIOAndMissingReadListLookupsAreNotFound() async throws {
    let folder = try ScratchFolder("metadata-missing-parent")
    let source = folder.url.appending(path: "source")
    let destination = folder.url.appending(path: "missing/file")
    try Data([1]).write(to: source)
    try await withClient { client in
      for op in [VFSOp.write(path: destination.path, data: .init([2]), ifMatch: nil), .mv(from: source.path, to: destination.path), .mkdir(path: source.path + "/child")] {
        let result = try await client.vfs(machine: "disk", op: op, owner: owner())
        guard case let .error(error) = result else { Issue.record("mutation unexpectedly succeeded"); continue }
        #expect(error.code == .io)
      }
      for op in [VFSOp.stat(path: destination.path), .ls(path: destination.path), .read(path: destination.path), .rm(path: destination.path, ifMatch: nil), .mv(from: destination.path, to: source.path)] {
        let result = try await client.vfs(machine: "disk", op: op, owner: owner())
        guard case let .error(error) = result else { Issue.record("lookup unexpectedly succeeded"); continue }
        #expect(error.code == .notFound)
      }
    }
    #expect(try Data(contentsOf: source) == Data([1]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["source"])
  }

  @Test func existingUnreadableFileAndDirectoryAreIOAfterSuccessfulLookup() async throws {
    let folder = try ScratchFolder("metadata-denied-data")
    let file = folder.url.appending(path: "file")
    let directory = folder.url.appending(path: "directory")
    try Data([1]).write(to: file)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for path in [file, directory] { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path) }
    defer { for path in [file, directory] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) } }
    try await withClient { client in
      for op in [VFSOp.read(path: file.path), .ls(path: directory.path)] {
        let result = try await client.vfs(machine: "disk", op: op, owner: owner())
        guard case let .error(error) = result else { Issue.record("unreadable entry unexpectedly opened"); continue }
        #expect(error.code == .io)
      }
    }
  }
}
