#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import Fetch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import Testing

@Suite struct FileOperationTests {
  func run(_ input: JSONValue, kind: String, channel: String, files: ComputerFileSystem) async throws -> (Data, [JSONValue], OperationSnapshot) {
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), authorize: { _, _ in })
    let store = MemoryOperationStore()
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: { _ in })
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let id = try await client.start("disk", request: .init(kind: kind, input: input), owner: .init(scope: "test", key: UUID().uuidString))
      var data = Data(); var records: [JSONValue] = []
      var snapshot = try await client.poll(id)
      while true {
        snapshot = try await client.poll(id, channel: channel, holdMs: 10)
        for payload in try await client.takeOutput(id, channel: channel) { data.append(payload.data ?? Data()); records += payload.records ?? [] }
        if snapshot.channelEnd { break }
      }
      await agent.shutdown()
      return (data, records, snapshot)
    }
  }

  @Test func readStreamsRangeAndDetectsMutation() async throws {
    let files = FakeFiles(data: Data("0123456789".utf8))
    let (bytes, _, end) = try await run(["path": "/file", "offset": "2", "length": "4"], kind: "read.v1", channel: "data", files: files.system)
    #expect(bytes == Data("2345".utf8)); #expect(end.verdict?.tag == .completed)
    #expect(await files.largestRead <= 65536)
    await files.mutateAfterRead()
    let (_, _, changed) = try await run(["path": "/file"], kind: "read.v1", channel: "data", files: files.system)
    #expect(changed.verdict?.error?.code == .fileChanged)
  }

  @Test func grepIncrementalAndOversizeIsExplicit() async throws {
    let files = FakeFiles(data: Data("needle\nother\nneedle tail".utf8), chunk: 3)
    let (_, records, end) = try await run(["root": "/file", "pattern": "needle", "dialect": "literal", "maxLineBytes": 32], kind: "grep.v1", channel: "matches", files: files.system)
    #expect(records.count == 2); #expect(end.verdict?.tag == .completed)
    let (_, _, tooLarge) = try await run(["root": "/file", "pattern": "needle", "dialect": "literal", "maxLineBytes": 4], kind: "grep.v1", channel: "matches", files: files.system)
    #expect(tooLarge.verdict?.tag == .completed)
    guard case let .object(result)? = tooLarge.verdict?.result else { Issue.record("missing skipped count"); return }
    #expect(result["skipped"] == ["oversized": 1])
  }

  @Test func findLimitsStopRatherThanPage() async throws {
    let files = FakeFiles(data: Data(), entries: [.init(path: "/b.txt", kind: "file"), .init(path: "/a.txt", kind: "file")])
    let (_, records, end) = try await run(["root": "/", "glob": "**/*.txt", "includeSymlinks": false, "entryLimit": 1], kind: "find.v1", channel: "entries", files: files.system)
    #expect(records.count == 1); #expect(end.verdict?.tag == .stopped); #expect(end.verdict?.reason == "entryLimit")
    #expect(await files.walked == 1)
  }
}

actor FakeFiles {
  let data: Data; let chunk: Int; let entries: [ComputerEntry]
  var reads = 0; var largestRead = 0; var walked = 0; var changed = false; var mutate = false
  init(data: Data, chunk: Int = 65536, entries: [ComputerEntry] = [.init(path: "/file", kind: "file")]) { self.data = data; self.chunk = chunk; self.entries = entries }
  func mutateAfterRead() { mutate = true }
  func status() -> ComputerFileStatus { .init(version: changed ? "v2" : "v1", size: UInt64(data.count), kind: "file") }
  func read(offset: UInt64, count: Int) -> Data { reads += 1; largestRead = max(largestRead, count); if mutate { changed = true }; let start = min(Int(offset), data.count); return data.subdata(in: start ..< min(data.count, start + min(chunk, count))) }
  func next(_ index: Int) -> ComputerEntry? { guard index < entries.count else { return nil }; walked += 1; return entries[index] }
  nonisolated var system: ComputerFileSystem {
    .init(status: { _ in await self.status() }, read: { _, offset, count in await self.read(offset: offset, count: count) }, walk: { _, _ in
      let cursor = FakeCursor(files: self)
      return .init(next: { await cursor.next() }, close: {})
    })
  }
}

actor FakeCursor {
  let files: FakeFiles; var index = 0
  init(files: FakeFiles) { self.files = files }
  func next() async -> ComputerEntry? { let item = await files.next(index); if item != nil { index += 1 }; return item }
}

import Scratch

extension FileOperationTests {
  @Test func liveRegularFilesUseTheSameHandlersOnDesktop() async throws {
    let folder = try ScratchFolder("computer-files")
    let path = folder.url.appending(path: "a.txt")
    try Data("first\nneedle\nlast".utf8).write(to: path)
    let version = try await ComputerFileSystem.local.status(path.path).version
    let (data, _, end) = try await run(["path": .string(path.path), "offset": "6", "length": "6", "ifMatch": .string(version)], kind: "read.v1", channel: "data", files: .local)
    #expect(data == Data("needle".utf8)); #expect(end.verdict?.tag == .completed)
    let (_, entries, found) = try await run(["root": .string(folder.url.path), "glob": "**/*.txt", "includeSymlinks": false], kind: "find.v1", channel: "entries", files: .local)
    #expect(entries.count == 1); #expect(found.verdict?.tag == .completed)
    let (_, matches, grepped) = try await run(["root": .string(folder.url.path), "pattern": "needle", "dialect": "literal", "maxLineBytes": 32], kind: "grep.v1", channel: "matches", files: .local)
    #expect(matches == [["path": .string(path.path), "line": "2", "text": "needle"]]); #expect(grepped.verdict?.tag == .completed)
  }

  @Test func unsupportedDialectRefusesBeforeAnyFilesystemEffect() async throws {
    let files = FakeFiles(data: Data())
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files.system), authorize: { _, _ in })
    let id = UUID()
    let url = URL(string: "https://test.invalid/machine/v2/machines/disk/operations/\(id)")!
    let response = try await agent.handler(Request(url: url, method: .post, body: .json(StartRequest(kind: "grep.v1", input: ["root": "/", "pattern": "(a+)+$", "dialect": "regex", "maxLineBytes": 65536]))))
    #expect(response.status.code == 400)
    #expect(try await response.body.json(ErrorEnvelope.self).error.code == .unsupportedDialect)
    #expect(await files.walked == 0)
  }

  @Test func fullReadWindowSuspendsEffectsAndControlStopStillAnswers() async throws {
    let files = FakeFiles(data: Data(repeating: 42, count: 1024 * 1024))
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files.system), authorize: { _, _ in })
    let store = MemoryOperationStore()
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: FetchClient { try await agent.handler($0) }, store: store, abort: { _ in }, trace: { _ in })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let id = try await client.start("disk", request: .init(kind: "read.v1", input: ["path": "/file"]), owner: .init(scope: "full", key: "one"))
      let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(2))
      while await files.reads < 5 && clock.now < deadline { try await clock.sleep(for: .milliseconds(1)) }
      #expect(await files.reads == 5)
      try await clock.sleep(for: .milliseconds(25))
      #expect(await files.reads == 5)
      #expect(try await client.poll(id).verdict == nil)
      _ = try await client.stop(id, reason: "testStop")
      var snapshot = try await client.reconcile(id)
      while snapshot.verdict == nil && clock.now < deadline { snapshot = try await client.reconcile(id) }
      #expect(snapshot.verdict?.tag == .stopped)
      await agent.shutdown()
    }
  }

  @Test func globHasBoundedNonRegexSemantics() {
    #expect(globMatches("**/*.txt", "a.txt")); #expect(globMatches("**/*.txt", "a/b/c.txt"))
    #expect(!globMatches("*.txt", "a/b.txt")); #expect(globMatches("a/?.txt", "a/b.txt"))
  }
}

import Dispatch
import Synchronization

extension FileOperationTests {
  @Test func grepRejectsAFileReplacedBySymlinkBeforeRead() async throws {
    let reads = Mutex(0)
    let files = ComputerFileSystem(status: { _ in .init(version: "link", size: 5, kind: "symlink") }, read: { _, _, _ in reads.withLock { $0 += 1 }; return Data() }, walk: { _, _ in
      let remaining = Mutex(true)
      return .init(next: { remaining.withLock { if !$0 { return nil }; $0 = false; return .init(path: "/file", kind: "file") } }, close: {})
    })
    let (_, records, end) = try await run(["root": "/file", "pattern": "x", "dialect": "literal", "maxLineBytes": 20], kind: "grep.v1", channel: "matches", files: files)
    #expect(records.isEmpty); #expect(end.verdict?.tag == .completed); #expect(reads.withLock { $0 } == 0)
  }

  @Test(arguments: [false, true])
  func noFollowOpenRejectsSwappedFileOrDirectory(_ directory: Bool) async throws {
    let folder = try ScratchFolder("computer-files-race")
    let original = folder.url.appending(path: "original")
    let moved = folder.url.appending(path: "moved")
    let target = folder.url.appending(path: "target")
    if directory {
      try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      try Data("secret".utf8).write(to: target.appending(path: "secret"))
    } else {
      try Data("ordinary".utf8).write(to: original); try Data("secret".utf8).write(to: target)
    }
    let swapped = Mutex(false)
    let files = ComputerFileSystem.local(beforeOpen: { path in
      if path == original.path && swapped.withLock({ if $0 { return false }; $0 = true; return true }) {
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
      }
    })
    if directory {
      let walk = try await files.walk(original.path, false)
      await #expect(throws: OperationError.self) { try await walk.next() }
      await walk.close()
    } else { await #expect(throws: OperationError.self) { try await files.read(original.path, 0, 64) } }
    #expect(swapped.withLock { $0 })
  }

  @Test func cancellationInterruptsExcludedEntryScanningWithinOneNext() async throws {
    let folder = try ScratchFolder("computer-files-cancel")
    for index in 0 ..< 500 { try FileManager.default.createSymbolicLink(atPath: folder.url.appending(path: String(index)).path, withDestinationPath: "/missing") }
    let inspected = Mutex(0)
    let blocked = DispatchSemaphore(value: 0)
    let (entered, writer) = AsyncStream<Void>.makeStream()
    let files = ComputerFileSystem.local(didInspect: { _ in
      let first = inspected.withLock { $0 += 1; return $0 == 1 }
      if first { writer.yield(()); writer.finish(); blocked.wait() }
    })
    let walk = try await files.walk(folder.url.path, false)
    let call = Task { try await walk.next() }
    for await _ in entered {}
    call.cancel(); blocked.signal()
    await #expect(throws: CancellationError.self) { try await call.value }
    #expect(inspected.withLock { $0 } == 1)
    await walk.close()
  }
}

extension FileOperationTests {
  @Test func grepSkipsBinaryOversizedChangedAndUnreadableFilesAndKeepsMatches() async throws {
    let paths = ["binary", "oversized", "changed", "unreadable", "good"]
    let versions = Mutex(0)
    let cursor = Mutex(0)
    let files = ComputerFileSystem(status: { path in
      if path.hasSuffix("unreadable") { throw OperationError(.fileUnavailable) }
      let changed = path.hasSuffix("changed") ? versions.withLock { $0 += 1; return $0 } : 0
      return .init(version: String(changed), size: 20, kind: "file")
    }, read: { path, offset, _ in
      if offset > 0 { return Data() }
      if path.hasSuffix("binary") { return Data([255, 10]) }
      if path.hasSuffix("oversized") { return Data(repeating: 65, count: 30) }
      return Data("needle\n".utf8)
    }, walk: { _, _ in .init(next: {
      cursor.withLock { index in guard index < paths.count else { return nil }; defer { index += 1 }; return .init(path: "/" + paths[index], kind: "file") }
    }, close: {}) })
    let (_, records, end) = try await run(["root": "/", "pattern": "needle", "dialect": "literal", "maxLineBytes": 20], kind: "grep.v1", channel: "matches", files: files)
    #expect(records == [["path": "/good", "line": "1", "text": "needle"]])
    #expect(end.verdict?.tag == .completed)
    guard case let .object(result)? = end.verdict?.result else { Issue.record("missing result"); return }
    #expect(result["skipped"] == ["binary": 1, "oversized": 1, "changed": 1, "unreadable": 1])
  }

  @Test func unreadableNestedDirectoryIsSkippedButNeighborStillFound() async throws {
    let folder = try ScratchFolder("computer-files-skip")
    let bad = folder.url.appending(path: "bad")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
    try Data("needle\n".utf8).write(to: folder.url.appending(path: "good.txt"))
    let files = ComputerFileSystem.local(beforeOpen: { if $0 == bad.path { throw OperationError(.fileUnavailable) } })
    let (_, entries, end) = try await run(["root": .string(folder.url.path), "glob": "**/*.txt", "includeSymlinks": false], kind: "find.v1", channel: "entries", files: files)
    #expect(entries.count == 1); #expect(end.verdict?.tag == .completed)
    guard case let .object(result)? = end.verdict?.result else { Issue.record("missing result"); return }
    #expect(result["skipped"] == ["unreadable": 1])
  }

  @Test func excludedSymlinkRootIsTypedRatherThanEmptySuccess() async throws {
    let folder = try ScratchFolder("computer-files-root")
    let link = folder.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.url.path)
    let walk = try await ComputerFileSystem.local.walk(link.path, false)
    await #expect(throws: OperationError.self) { try await walk.next() }
    await walk.close()
  }
}

private final class FileLocalTime: Sendable {
  let value = Mutex<Duration>(.zero)
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { _ in throw CancellationError() }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}

extension FileOperationTests {
  @Test(arguments: ["stop", "lease"])
  func protocolStopOrLeaseInterruptsOneExcludedEntryNext(_ action: String) async throws {
    let folder = try ScratchFolder("computer-files-protocol-stop")
    for index in 0 ..< 500 { try FileManager.default.createSymbolicLink(atPath: folder.url.appending(path: String(index)).path, withDestinationPath: "/missing") }
    let inspected = Mutex(0); let blocked = DispatchSemaphore(value: 0)
    let (entered, writer) = AsyncStream<Void>.makeStream()
    let files = ComputerFileSystem.local(didInspect: { _ in
      let first = inspected.withLock { $0 += 1; return $0 == 1 }
      if first { writer.yield(()); writer.finish(); blocked.wait() }
    })
    let time = FileLocalTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), clock: time.clock, authorize: { _, _ in })
    let client = try OperationClient(origin: URL(string: "https://test.invalid")!, fetch: .init(fetch: agent.handler), store: MemoryOperationStore(), abort: { _ in }, trace: { _ in })
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      _ = try await client.describe("disk")
      let id = try await client.start("disk", request: .init(kind: "find.v1", input: ["root": .string(folder.url.path), "glob": "**/*", "includeSymlinks": false]), owner: .init(scope: "protocol-stop", key: action))
      for await _ in entered {}
      if action == "stop" { _ = try await client.stop(id, reason: "testStop") }
      else { time.advance(.seconds(61)) }
      blocked.signal()
      let deadline = ContinuousClock().now.advanced(by: .seconds(2))
      var end = try await client.reconcile(id)
      while end.verdict == nil && ContinuousClock().now < deadline { await Task.yield(); end = try await client.reconcile(id) }
      #expect(end.verdict?.tag == .stopped)
      #expect(end.verdict?.reason == (action == "stop" ? "testStop" : "leaseExpired"))
      #expect(inspected.withLock { $0 } == 1)
      await agent.shutdown(); await client.shutdown()
    }
  }

  @Test(arguments: ["inspect", "yield"])
  func grepNeverReadsOutsideWhenAYieldedFilesParentBecomesASymlink(_ phase: String) async throws {
    let folder = try ScratchFolder("computer-files-parent-race")
    let root = folder.url.appending(path: "root")
    let child = root.appending(path: "dir")
    let moved = root.appending(path: "moved")
    let outside = folder.url.appending(path: "outside")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let path = child.appending(path: "file.txt")
    try Data("inside needle\n".utf8).write(to: path)
    try Data("outside needle\n".utf8).write(to: outside.appending(path: "file.txt"))
    let swapped = Mutex(false)
    let swap: @Sendable (String) throws -> Void = { addressed in
      if addressed == path.path && swapped.withLock({ if $0 { return false }; $0 = true; return true }) {
        try FileManager.default.moveItem(at: child, to: moved)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
      }
    }
    let files = ComputerFileSystem.local(didInspect: { if phase == "inspect" { try! swap($0) } }, didYield: { if phase == "yield" { try swap($0) } })
    let (_, matches, end) = try await run(["root": .string(root.path), "pattern": "needle", "dialect": "literal", "maxLineBytes": 64], kind: "grep.v1", channel: "matches", files: files)
    #expect(swapped.withLock { $0 }); #expect(end.verdict?.tag == .completed)
    #expect(!matches.contains { $0.jsonString().contains("outside needle") })
    #expect(matches.contains(["path": .string(path.path), "line": "1", "text": "inside needle"]))
  }

  @Test func trailingSlashDoesNotHideASymlinkRoot() async throws {
    let folder = try ScratchFolder("computer-files-trailing-symlink")
    let link = folder.url.appending(path: "link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: folder.url.path)
    let (_, entries, end) = try await run(["root": .string(link.path + "/"), "glob": "**/*", "includeSymlinks": false], kind: "find.v1", channel: "entries", files: .local)
    #expect(entries.isEmpty); #expect(end.verdict?.tag == .failed); #expect(end.verdict?.error?.code == .invalidInput)
  }
}
