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
import OperationProtocol
import OperationRuntime
import Scratch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(2))) struct MetadataOperationTests {
  func withClient<T: Sendable>(files: ComputerFileSystem = .local, fetch: (@Sendable (Request, @escaping @Sendable (Request) async throws -> Response) async throws -> Response)? = nil, body: (AgentWire) async throws -> T) async throws -> T {
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), authorize: { _, _ in })
    let client = AgentWire { request in
      if let fetch { return try await fetch(request, agent.handler) }
      return try await agent.handler(request)
    }
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      do { _ = try await client.describe(); let result = try await body(client); await agent.shutdown(); return result }
      catch { await agent.shutdown(); throw error }
    }
  }

  @Test func allKindsRoundTripWithLargeStreamedWriteAndReadToken() async throws {
    let folder = try ScratchFolder("metadata-kinds")
    let directory = folder.url.appending(path: "nested/child").path
    let path = directory + "/file"
    let moved = directory + "/moved"
    let bytes = Data((0 ..< 400_000).map { UInt8($0 % 251) })
    try await withClient { client in
      _ = try await client.call(.init(kind: "mkdir.v1", input: ["path": .string(directory)]))
      let token = try await client.write(path: path, data: bytes)
      let entry = try decodeEntry(await client.call(.init(kind: "stat.v1", input: ["path": .string(path)])))
      #expect(entry.kind == .file); #expect(entry.size == bytes.count); #expect(entry.token == token); #expect(entry.mtime > 0)
      var entries: [MachineEntry] = []
      _ = try await client.call(.init(kind: "list.v1", input: ["path": .string(directory)])) { payload in
        try entries.append(contentsOf: payload.records!.map(decodeEntry))
      }
      #expect(entries == [entry])
      var collected = Data()
      let read = try await client.call(.init(kind: "read.v1", input: ["path": .string(path)])) { collected.append($0.data!) }
      #expect(read.object?["version"] == .string(token))
      #expect(collected == bytes)
      let next = try await client.write(path: path, data: Data("replaced".utf8), ifMatch: token)
      #expect(next != token)
      let conflict = await #expect(throws: OperationError.self) {
        try await client.write(path: path, data: Data([1]), ifMatch: token)
      }
      #expect(conflict?.code == .fileChanged)
      _ = try await client.call(.init(kind: "move.v1", input: ["from": .string(path), "to": .string(moved)]))
      _ = try await client.call(.init(kind: "remove.v1", input: ["path": .string(folder.url.appending(path: "nested").path)]))
      #expect(!FileManager.default.fileExists(atPath: moved))
    }
  }

  @Test func filesystemFailuresKeepTheirWireCodesAndLookupMarkers() async throws {
    let folder = try ScratchFolder("metadata-errors")
    let a = folder.url.appending(path: "a").path; let b = folder.url.appending(path: "b").path
    try Data([1]).write(to: URL(fileURLWithPath: a)); try Data([2]).write(to: URL(fileURLWithPath: b))
    try await withClient { client in
      let lookup = await #expect(throws: OperationError.self) {
        try await client.call(.init(kind: "stat.v1", input: ["path": .string(b + "-missing")]))
      }
      #expect(lookup?.code == .fileUnavailable)
      #expect(lookup?.details?.object?["lookup"] == .bool(true))
      let stale = await #expect(throws: OperationError.self) {
        try await client.call(.init(kind: "remove.v1", input: ["path": .string(b + "-missing"), "ifMatch": "stale"]))
      }
      #expect(stale?.code == .fileChanged)
      let exists = await #expect(throws: OperationError.self) {
        try await client.call(.init(kind: "move.v1", input: ["from": .string(a), "to": .string(b)]))
      }
      #expect(exists?.code == .fileUnavailable)
      #expect(exists?.details?.object?["errno"] == 17)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: a)) == Data([1]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: b)) == Data([2]))
  }

  @Test func listStreamsBeyondResultCapAndReportsSymlinkItself() async throws {
    let folder = try ScratchFolder("metadata-list")
    for index in 0 ..< 500 { try Data().write(to: folder.url.appending(path: String(format: "%04d", index))) }
    let link = folder.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url)
    try await withClient { client in
      var entries: [MachineEntry] = []
      _ = try await client.call(.init(kind: "list.v1", input: ["path": .string(folder.url.path)])) { payload in
        try entries.append(contentsOf: payload.records!.map(decodeEntry))
      }
      entries.sort { $0.name < $1.name }
      #expect(entries.count == 501); #expect(entries.last?.kind == .symlink)
      #expect(try decodeEntry(await client.call(.init(kind: "stat.v1", input: ["path": .string(link.path)]))).kind == .symlink)
      await #expect(throws: OperationError.self) { try await client.call(.init(kind: "list.v1", input: ["path": .string(link.path + "/")])) }
      await #expect(throws: OperationError.self) { try await client.write(path: link.path, data: Data()) }
      _ = try await client.call(.init(kind: "remove.v1", input: ["path": .string(link.path)]))
      #expect(FileManager.default.fileExists(atPath: folder.url.path))
    }
  }

  @Test func duplicateOperationIDRefusesAnotherWrite() async throws {
    let folder = try ScratchFolder("metadata-duplicate-id")
    let path = folder.url.appending(path: "file").path
    try await withClient { client in
      let id = UUID()
      let bytes = Data([1])
      let request = StartRequest(kind: "write.v1", input: ["path": .string(path), "bytes": "1", "digest": .string(sha256(bytes))])
      let operation = try await client.start(request, id: id)
      try await operation.write("data", .init(data: bytes), end: true)
      #expect(try await operation.verdict().tag == .completed)
      let duplicate = await #expect(throws: OperationError.self) { try await client.start(request, id: id) }
      #expect(duplicate?.code == .operationExists)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    }
  }

  @Test func lostInputReceiptRetriesIdenticalOffsetWithoutDuplicateBytes() async throws {
    let folder = try ScratchFolder("metadata-input-retry")
    let path = folder.url.appending(path: "file").path
    let dropped = Mutex(false), starts = Mutex(0)
    let bytes = Data(repeating: 42, count: 200_000)
    try await withClient(fetch: { request, handler in
      if request.method == .post { starts.withLock { $0 += 1 } }
      let response = try await handler(request)
      if request.url.path.contains("/inputs/"), dropped.withLock({ if $0 { return false }; $0 = true; return true }) { throw OperationError(.transport) }
      return response
    }) { client in
      let operation = try await client.start(.init(kind: "write.v1", input: ["path": .string(path), "bytes": .string(String(bytes.count)), "digest": .string(sha256(bytes))]))
      let first = Data(bytes.prefix(64 * 1024))
      let request = WriteRequest(offset: .zero, payload: .init(data: first))
      let error = await #expect(throws: OperationError.self) { try await operation.input("data", request) }
      #expect(error?.code == .transport)
      let receipt = try await operation.input("data", request)
      #expect(receipt.acceptedThrough.rawValue == UInt64(first.count))
      #expect(!receipt.end)
      var offset = first.count
      while offset < bytes.count {
        let end = min(bytes.count, offset + 64 * 1024)
        try await operation.write("data", .init(data: bytes.subdata(in: offset ..< end)), end: end == bytes.count)
        offset = end
      }
      #expect(try await operation.verdict().tag == .completed)
    }
    #expect(starts.withLock { $0 } == 1)
    #expect(dropped.withLock { $0 })
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
  }
}

extension MetadataOperationTests {
  @Test func injectedFilesystemReplaysExactEffectsThroughProductionHandlers() async throws {
    let events = Mutex<[String]>([])
    // An operation's verdict is out before its handle closes, so a close may land after the next operation's first effect.
    let (closes, closed) = AsyncStream<Void>.makeStream()
    let cursor = Mutex(0)
    let entry = MachineEntry(name: "file", kind: .file, size: 3, token: "recorded-token", mtime: 123)
    let operations = ComputerFileOperations(stat: { path in events.withLock { $0.append("stat \(path)") }; return entry }, list: { path in
      events.withLock { $0.append("list \(path)") }
      return .init(next: { cursor.withLock { count in defer { count += 1 }; return count == 0 ? entry : nil } }, close: { events.withLock { $0.append("list close") }; closed.yield() })
    }, write: { path, condition in
      events.withLock { $0.append("write \(path) \(condition)") }
      return .init(append: { data in events.withLock { $0.append("append \(data.base64EncodedString())") } }, commit: { events.withLock { $0.append("commit") }; return "new-token" }, close: { events.withLock { $0.append("write close") }; closed.yield() })
    }, mkdir: { path in events.withLock { $0.append("mkdir \(path)") } }, remove: { path, token in events.withLock { $0.append("remove \(path) \(token ?? "nil")") } }, move: { from, to in events.withLock { $0.append("move \(from) \(to)") } })
    let files = ComputerFileSystem(status: { _ in throw OperationError(.fileUnavailable) }, read: { _, _, _ in throw OperationError(.fileUnavailable) }, search: { _ in NoFiles() }, operations: operations)
    try await withClient(files: files) { client in
      #expect(try decodeEntry(await client.call(.init(kind: "stat.v1", input: ["path": "/file"]))) == entry)
      var entries: [MachineEntry] = []
      _ = try await client.call(.init(kind: "list.v1", input: ["path": "/"])) { payload in
        try entries.append(contentsOf: payload.records!.map(decodeEntry))
      }
      #expect(entries == [entry])
      #expect(try await client.write(path: "/file", data: Data([1, 2, 3]), ifMatch: "recorded-token") == "new-token")
      _ = try await client.call(.init(kind: "mkdir.v1", input: ["path": "/dir"]))
      _ = try await client.call(.init(kind: "remove.v1", input: ["path": "/file", "ifMatch": "new-token"]))
      _ = try await client.call(.init(kind: "move.v1", input: ["from": "/a", "to": "/b"]))
    }
    var count = 0
    for await _ in closes { count += 1; if count == 2 { break } }
    let recorded = events.withLock { $0 }
    #expect(recorded.filter { !$0.hasSuffix(" close") } == ["stat /file", "list /", #"write /file version("recorded-token")"#, "append AQID", "commit", "mkdir /dir", "remove /file new-token", "move /a /b"])
    #expect(try #require(recorded.firstIndex(of: "list close")) > #require(recorded.firstIndex(of: "list /")))
    #expect(try #require(recorded.firstIndex(of: "write close")) > #require(recorded.firstIndex(of: "commit")))
  }

  @Test(arguments: ["stop", "lease", "digest"])
  func incompleteOrInvalidWriteNeverReplacesTargetAndCleansStage(_ action: String) async throws {
    let folder = try ScratchFolder("metadata-abort")
    let path = folder.url.appending(path: "file").path
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))
    let time = MetadataTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(), clock: time.clock, receiptRetention: leaseJumpRetention, authorize: { _, _ in })
    let client = AgentWire(agent.handler)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      let operation = try await client.start(.init(kind: "write.v1", input: ["path": .string(path), "bytes": "4", "digest": .string(String(repeating: "0", count: 64))]))
      try await operation.write("data", .init(data: Data([1, 2, 3, 4])), end: action == "digest")
      if action == "stop" { try await operation.stop("testStop") }
      if action == "lease" { time.advance(.seconds(61)) }
      let end = try await operation.verdict()
      #expect(end.tag == (action == "digest" ? .failed : .stopped))
      #expect(end.error?.code == (action == "digest" ? .invalidInput : nil))
      await agent.shutdown()
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["file"])
  }

  @Test(arguments: ["same", "parent", "case", "unicode"])
  func concurrentLocalWritersCompareAndCommitOnceThroughAliases(_ alias: String) async throws {
    #if !os(macOS)
      if alias == "case" || alias == "unicode" { return }
    #endif
    let folder = try ScratchFolder("metadata-concurrent-commit")
    let name = alias == "case" ? "File" : alias == "unicode" ? "Café" : "file"
    let otherName = alias == "case" ? "file" : alias == "unicode" ? "Cafe\u{301}" : name
    let path = folder.url.appending(path: name).path
    let link = folder.url.appending(path: "alias")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.url.path)
    let other = alias == "parent" ? link.appendingPathComponent(name).path : folder.url.appending(path: otherName).path
    try Data("original".utf8).write(to: URL(fileURLWithPath: path))
    let token = try await ComputerFileSystem.local.status(path).version
    #expect(try await ComputerFileSystem.local.status(other).version == token)
    let compared = DispatchGroup()
    compared.enter(); compared.enter()
    let beforeRename: @Sendable () -> Void = {
      compared.leave()
      _ = compared.wait(timeout: .now() + .seconds(1))
    }
    let first = try await ComputerFileOperations.local(synchronize: { _ in }, beforeRename: beforeRename).write(path, .version(token))
    let second = try await ComputerFileOperations.local(synchronize: { _ in }, beforeRename: beforeRename).write(other, .version(token))
    try await first.append(Data("first".utf8)); try await second.append(Data("second".utf8))
    try await first.prepare(); try await second.prepare()
    let results = await withTaskGroup(of: Result<String, OperationError>.self, returning: [Result<String, OperationError>].self) { group in
      for writer in [first, second] {
        group.addTask {
          do { return .success(try await writer.commit()) }
          catch { return .failure(error as? OperationError ?? .init(.invalidResponse)) }
        }
      }
      var results: [Result<String, OperationError>] = []
      for await result in group { results.append(result) }
      return results
    }
    await first.close(); await second.close()
    let receipts = results.compactMap { try? $0.get() }
    let errors = results.compactMap { if case let .failure(error) = $0 { error.code } else { nil } }
    #expect(receipts.count == 1)
    #expect(errors == [.fileChanged])
    #expect(receipts.first == (try await ComputerFileSystem.local.status(path).version))
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(data == Data("first".utf8) || data == Data("second".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).count == 2)
  }

  @Test func localCommitsInDifferentDirectoriesRemainConcurrent() async throws {
    let firstFolder = try ScratchFolder("metadata-directory-first")
    let secondFolder = try ScratchFolder("metadata-directory-second")
    let compared = DispatchGroup(); compared.enter(); compared.enter()
    let waits = Mutex<[Bool]>([])
    let operations = ComputerFileOperations.local(synchronize: { _ in }, beforeRename: {
      compared.leave()
      let concurrent = compared.wait(timeout: .now() + .seconds(2)) == .success
      waits.withLock { $0.append(concurrent) }
    })
    let first = try await operations.write(firstFolder.url.appending(path: "file").path, .any)
    let second = try await operations.write(secondFolder.url.appending(path: "file").path, .any)
    try await first.append(Data("first".utf8)); try await second.append(Data("second".utf8))
    try await first.prepare(); try await second.prepare()
    try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await first.commit() }
      group.addTask { try await second.commit() }
      for try await _ in group {}
    }
    await first.close(); await second.close()
    #expect(waits.withLock { $0 } == [true, true])
  }

  @Test func writerRechecksTokenAtCommitAndEmptyWriteWorks() async throws {
    let folder = try ScratchFolder("metadata-write-check")
    let path = folder.url.appending(path: "file").path
    try Data([1]).write(to: URL(fileURLWithPath: path))
    let token = try await ComputerFileSystem.local.status(path).version
    let writer = try await ComputerFileSystem.local.operations.write(path, .version(token))
    try await writer.append(Data([2]))
    try Data([3, 4]).write(to: URL(fileURLWithPath: path))
    await #expect(throws: OperationError.self) { try await writer.prepare(); _ = try await writer.commit() }
    await writer.close()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([3, 4]))
    try await withClient { client in
      _ = try await client.write(path: path, data: Data())
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)).isEmpty)
    }
  }

  @Test func stageLedgerHoldsOpenStagesAndSweepRemovesThoseLeftBehind() async throws {
    let folder = try ScratchFolder("metadata-stage-ledger")
    let ledger = try StageLedger(directory: folder.url.appending(path: "stages").path)
    let files = ComputerFileSystem.local(stages: ledger)
    let target = folder.url.appending(path: "target").path
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
    func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: ledger.directory) }
    func stages() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: target).filter { $0.hasPrefix(stagePrefix) } }
    let committed = try await files.operations.write(target + "/kept", .absent)
    try await committed.append(Data([1]))
    #expect(try entries().count == 1 && stages().count == 1)
    try await committed.prepare(); _ = try await committed.commit(); await committed.close()
    #expect(try entries().isEmpty && stages().isEmpty)
    let crashed = try await files.operations.write(target + "/lost", .any)
    try await crashed.append(Data([2]))
    #expect(ledger.sweep() == 1)
    #expect(try entries().isEmpty && stages().isEmpty)
    await crashed.close()
    #expect(try FileManager.default.contentsOfDirectory(atPath: target) == ["kept"])
  }

  @Test func aSweepRemovesOnlyTheRegularStageAnEntryOwns() async throws {
    let folder = try ScratchFolder("metadata-stage-forged")
    let ledger = try StageLedger(directory: folder.url.appending(path: "stages").path)
    let target = folder.url.appending(path: "target").path
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
    let backup = target + "/" + stagePrefix + "backup", kept = target + "/kept"
    #expect(FileManager.default.createFile(atPath: backup, contents: Data([1])))
    #expect(FileManager.default.createFile(atPath: kept, contents: Data([2])))
    let pathEntry = UUID().uuidString, linked = UUID()
    #expect(FileManager.default.createFile(atPath: ledger.directory + "/backup", contents: Data(target.utf8)))
    #expect(FileManager.default.createFile(atPath: ledger.directory + "/" + pathEntry, contents: Data(backup.utf8)))
    let link = target + "/" + stagePrefix + linked.uuidString
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: kept)
    try ledger.record(linked, in: target)
    #expect(ledger.sweep() == 0)
    #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == Data([1]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == Data([2]))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == kept)
    #expect(try Set(FileManager.default.contentsOfDirectory(atPath: ledger.directory)) == ["backup", pathEntry, linked.uuidString])
  }

  @Test func anEntryStaysWhileItsStageMayStillBeThere() async throws {
    let folder = try ScratchFolder("metadata-stage-kept")
    let ledger = try StageLedger(directory: folder.url.appending(path: "stages").path)
    let target = folder.url.appending(path: "target").path
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
    func entries() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: ledger.directory).count }
    let writer = try await ComputerFileSystem.local(stages: ledger).operations.write(target + "/file", .any)
    let stage = target + "/" + (try #require(try FileManager.default.contentsOfDirectory(atPath: target).first))
    try FileManager.default.removeItem(atPath: stage)
    try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: false)
    await writer.close()
    #expect(try entries() == 1, "close could not remove the stage")
    #expect(ledger.sweep() == 0)
    #expect(try entries() == 1, "nor could the sweep")
    try FileManager.default.removeItem(atPath: stage)
    #expect(ledger.sweep() == 0)
    #expect(try entries() == 0, "a stage confirmed absent frees its entry")
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
    let files = ComputerFileSystem(status: ComputerFileSystem.local.status, read: ComputerFileSystem.local.read, search: ComputerFileSystem.local.search, operations: operations)
    let time = MetadataTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), clock: time.clock, receiptRetention: leaseJumpRetention, authorize: { _, _ in })
    // A stop is durable intent; the commit is released only once the machine holds it.
    let (stopped, stopAnswered) = AsyncStream<Void>.makeStream()
    let client = AgentWire { request in
      let response = try await agent.handler(request)
      if request.method == .put, request.url.lastPathComponent == "stop" { stopAnswered.yield() }
      return response
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      let bytes = Data("replacement".utf8)
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let operation = try await client.start(.init(kind: "write.v1", input: ["path": .string(path), "bytes": .string(String(bytes.count)), "digest": .string(digest)]))
      try await operation.write("data", .init(data: bytes), end: true)
      for await _ in reached.stream { break }
      if action.hasSuffix("stop") {
        try await operation.stop("commitStop")
        for await _ in stopped { break }
      } else {
        time.advance(.seconds(61))
        _ = try await operation.poll()
      }
      release.signal()
      let verdict = try await operation.verdict()
      #expect(verdict.tag == (action.hasPrefix("sync") ? .stopped : .completed))
      if action.hasPrefix("rename") {
        #expect(verdict.reason == nil)
        #expect(verdict.result != nil)
      }
      await agent.shutdown()
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
      let error = await #expect(throws: OperationError.self) { try await client.write(path: path.path, data: Data([2])) }
      #expect(error?.code == .fileUnavailable)
      #expect(error?.details?.object?["lookup"] != .bool(true))
      #expect(try Data(contentsOf: path) == Data([1]))
      #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["file"])
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
      _ = try await client.write(path: path.path, data: Data([3]))
      #expect(try Data(contentsOf: path) == Data([3]))
      #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) == 0o640)
    }
  }

  @Test func sourceLookupFailuresAreMarkedButMutationPermissionErrorsAreNot() async throws {
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
        for start in [
          StartRequest(kind: "stat.v1", input: ["path": .string(source)]),
          .init(kind: "list.v1", input: ["path": .string(source)]),
          .init(kind: "read.v1", input: ["path": .string(source)]),
          .init(kind: "remove.v1", input: ["path": .string(source)]),
          .init(kind: "move.v1", input: ["from": .string(source), "to": .string(folder.url.appending(path: "moved").path)]),
        ] {
          let error = await #expect(throws: OperationError.self) { try await client.call(start) }
          #expect(error?.code == .fileUnavailable)
          #expect(error?.details?.object?["lookup"] == .bool(true))
        }
        let guarded = await #expect(throws: OperationError.self) {
          try await client.call(.init(kind: "remove.v1", input: ["path": .string(source), "ifMatch": "expected"]))
        }
        #expect(guarded?.code == .fileChanged)
      }
      let error = await #expect(throws: OperationError.self) {
        try await client.call(.init(kind: "move.v1", input: ["from": .string(file.path), "to": .string(denied.appending(path: "destination").path)]))
      }
      #expect(error?.code == .fileUnavailable)
      #expect(error?.details?.object?["lookup"] != .bool(true))
    }
  }
}

extension MetadataOperationTests {
  @Test func missingDestinationParentsHaveNoLookupMarkerButMissingSourcesDo() async throws {
    let folder = try ScratchFolder("metadata-missing-parent")
    let source = folder.url.appending(path: "source")
    let destination = folder.url.appending(path: "missing/file")
    try Data([1]).write(to: source)
    try await withClient { client in
      let write = await #expect(throws: OperationError.self) { try await client.write(path: destination.path, data: Data([2])) }
      #expect(write?.code == .fileUnavailable)
      #expect(write?.details?.object?["lookup"] != .bool(true))
      for start in [
        StartRequest(kind: "move.v1", input: ["from": .string(source.path), "to": .string(destination.path)]),
        .init(kind: "mkdir.v1", input: ["path": .string(source.path + "/child")]),
      ] {
        let error = await #expect(throws: OperationError.self) { try await client.call(start) }
        #expect(error?.code == .fileUnavailable)
        #expect(error?.details?.object?["lookup"] != .bool(true))
      }
      for start in [
        StartRequest(kind: "stat.v1", input: ["path": .string(destination.path)]),
        .init(kind: "list.v1", input: ["path": .string(destination.path)]),
        .init(kind: "read.v1", input: ["path": .string(destination.path)]),
        .init(kind: "remove.v1", input: ["path": .string(destination.path)]),
        .init(kind: "move.v1", input: ["from": .string(destination.path), "to": .string(source.path)]),
      ] {
        let error = await #expect(throws: OperationError.self) { try await client.call(start) }
        #expect(error?.code == .fileUnavailable)
        #expect(error?.details?.object?["lookup"] == .bool(true))
      }
    }
    #expect(try Data(contentsOf: source) == Data([1]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["source"])
  }

  @Test func existingUnreadableFileAndDirectoryHaveNoLookupMarker() async throws {
    let folder = try ScratchFolder("metadata-denied-data")
    let file = folder.url.appending(path: "file")
    let directory = folder.url.appending(path: "directory")
    try Data([1]).write(to: file)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for path in [file, directory] { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path.path) }
    defer { for path in [file, directory] { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) } }
    try await withClient { client in
      for start in [StartRequest(kind: "read.v1", input: ["path": .string(file.path)]), .init(kind: "list.v1", input: ["path": .string(directory.path)])] {
        let error = await #expect(throws: OperationError.self) { try await client.call(start) }
        #expect(error?.code == .fileUnavailable)
        #expect(error?.details?.object?["lookup"] != .bool(true))
      }
    }
  }
}
