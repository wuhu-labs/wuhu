import ClockTesting
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import ComputerFiles
import Dispatch
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import OperationRuntime
import Scratch
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(2))) struct FileOperationTests {
  /// Runs one operation of `kind` to its end and returns its output on its one output channel.
  func run(_ input: JSONValue, kind: String, channel _: String, files: ComputerFileSystem) async throws -> (Data, [JSONValue], Ending) {
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), authorize: { _, _ in })
    let operations = try machineOperations(agent.handler)
    return try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      defer { group.cancelAll() }
      let operation = try await operations.open(.init(scope: "test", key: UUID().uuidString), machine: "disk", start: .init(kind: kind, input: input))
      let result = try await operation.drain()
      await operations.shutdown(); await agent.shutdown()
      return result
    }
  }

  /// One `search.v1` to its verdict.
  func search(_ query: SearchQuery, files: ComputerFileSystem = .local) async throws -> Verdict {
    let (_, _, end) = try await run(json(query), kind: "search.v1", channel: "", files: files)
    return try #require(end.verdict)
  }

  func page(_ query: SearchQuery, files: ComputerFileSystem = .local) async throws -> SearchPage {
    let verdict = try await search(query, files: files)
    #expect(verdict.tag == .completed, "\(String(describing: verdict.error))")
    return try JSONDecoder().decode(SearchPage.self, from: Data(try #require(verdict.result).jsonString().utf8))
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

  @Test func fullReadWindowSuspendsEffectsAndControlStopStillAnswers() async throws {
    let files = FakeFiles(data: Data(repeating: 42, count: 1024 * 1024))
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files.system), authorize: { _, _ in })
    let operations = try machineOperations(agent.handler)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      // Nobody reads the output: the machine's window and the server's retained window fill, then reads stop.
      let operation = try await operations.open(.init(scope: "full", key: "one"), machine: "disk", start: .init(kind: "read.v1", input: ["path": "/file"]))
      let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(10))
      // The server's window is full once it has no room for another poll; the machine's then fills, and reads hold still.
      func serverFull() async -> Bool {
        let record = await operation.record
        guard let window = record.outputChannels.first?.windowBytes else { return false }
        return record.retainedBytes("data") + min(record.description.limits.pollBytes, window) > window
      }
      while await !serverFull(), clock.now < deadline { try await clock.sleep(for: .milliseconds(10)) }
      #expect(await serverFull())
      var reads = -1; var steady = 0
      while steady < 3, clock.now < deadline {
        let now = await files.reads
        steady = now == reads ? steady + 1 : 0
        reads = now
        try await clock.sleep(for: .milliseconds(50))
      }
      #expect(reads >= 5)
      try await clock.sleep(for: .milliseconds(25))
      #expect(await files.reads == reads)
      #expect(await operation.record.snapshot?.verdict == nil)
      try await operation.stop("testStop")
      #expect(try await operation.verdict().tag == .stopped)
      await operations.shutdown(); await agent.shutdown()
    }
  }

  @Test func readRejectsAFileSwappedForASymlink() async throws {
    let folder = try ScratchFolder("computer-files-race")
    let original = folder.url.appending(path: "original")
    let target = folder.url.appending(path: "target")
    try Data("ordinary".utf8).write(to: original); try Data("secret".utf8).write(to: target)
    let swapped = Mutex(false)
    let files = ComputerFileSystem.local(beforeOpen: { path in
      if path == original.path && swapped.withLock({ if $0 { return false }; $0 = true; return true }) {
        try FileManager.default.moveItem(at: original, to: folder.url.appending(path: "moved"))
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
      }
    })
    await #expect(throws: OperationError.self) { try await files.read(original.path, 0, 64) }
    #expect(swapped.withLock { $0 })
  }
}

extension FileOperationTests {
  @Test func searchFindsAndGrepsTheDiskAndPages() async throws {
    let folder = try ScratchFolder("computer-files-search")
    let root = folder.url.path
    try FileManager.default.createDirectory(at: folder.url.appending(path: "sub"), withIntermediateDirectories: false)
    try Data("first\nneedle\n".utf8).write(to: folder.url.appending(path: "a.txt"))
    try Data("needle\n".utf8).write(to: folder.url.appending(path: "sub/b.txt"))
    try Data("x".utf8).write(to: folder.url.appending(path: "c.md"))
    let found = try await page(.init(mode: .find, pattern: "**/*.txt", root: root, scope: "test"))
    #expect(found.hits.map(\.path) == [root + "/a.txt", root + "/sub/b.txt"])
    #expect(found.cursor == nil)
    let grepped = try await page(.init(mode: .grep, pattern: "needle", root: root, scope: "test", limit: 1))
    #expect(grepped.hits == [.init(path: root + "/a.txt", line: 2, text: "needle")])
    let rest = try await page(.init(mode: .grep, pattern: "needle", root: root, scope: "test", limit: 1, step: try #require(grepped.cursor)))
    #expect(rest.hits == [.init(path: root + "/sub/b.txt", line: 1, text: "needle")])
    #expect(rest.cursor == nil)
  }

  @Test func searchHonorsGitignoreAndHiddenNames() async throws {
    let folder = try ScratchFolder("computer-files-ignore")
    let root = folder.url.path
    try FileManager.default.createDirectory(at: folder.url.appending(path: ".git"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: folder.url.appending(path: "build"), withIntermediateDirectories: false)
    try Data("build/\n".utf8).write(to: folder.url.appending(path: ".gitignore"))
    try Data("x".utf8).write(to: folder.url.appending(path: "build/out.txt"))
    try Data("x".utf8).write(to: folder.url.appending(path: "kept.txt"))
    let found = try await page(.init(mode: .find, pattern: "**/*.txt", root: root, scope: "test"))
    #expect(found.hits.map(\.path) == [root + "/kept.txt"])
    #expect(found.skipped.map(\.reason) == [.hidden, .ignored])
    let everything = try await page(.init(mode: .find, pattern: "**/*.txt", root: root, scope: "test", hidden: true, noIgnore: true))
    #expect(everything.hits.map(\.path) == [root + "/build/out.txt", root + "/kept.txt"])
  }

  @Test func symlinkRootIsFollowedAndSymlinksBelowItAreNot() async throws {
    let folder = try ScratchFolder("computer-files-root")
    let tree = folder.url.appending(path: "tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
    try Data("needle\n".utf8).write(to: tree.appending(path: "a.txt"))
    try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "loop").path, withDestinationPath: tree.path)
    let link = folder.url.appending(path: "link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tree.path)
    for root in [link, link + "/"] {
      let found = try await page(.init(mode: .find, pattern: "**", root: root, scope: "test"))
      #expect(found.hits.map(\.path) == [link + "/a.txt", link + "/loop"])
      let grepped = try await page(.init(mode: .grep, pattern: "needle", root: root, scope: "test"))
      #expect(grepped.hits.map(\.path) == [link + "/a.txt"])
    }
  }

  @Test(arguments: ["list", "open"])
  func searchNeverLeavesTheRootThroughADirectorySwappedForASymlink(_ phase: String) async throws {
    let folder = try ScratchFolder("computer-files-parent-race")
    let root = folder.url.appending(path: "root")
    let child = root.appending(path: "dir")
    let outside = folder.url.appending(path: "outside")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let file = child.appending(path: "file.txt")
    try Data("inside needle\n".utf8).write(to: file)
    try Data("outside needle\n".utf8).write(to: outside.appending(path: "file.txt"))
    let swapped = Mutex(false)
    let trigger = phase == "list" ? child.path : file.path
    let files = ComputerFileSystem.local(beforeOpen: { path in
      if path == trigger && swapped.withLock({ if $0 { return false }; $0 = true; return true }) {
        try FileManager.default.moveItem(at: child, to: root.appending(path: "moved"))
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
      }
    })
    let grepped = try await page(.init(mode: .grep, pattern: "needle", root: root.path, scope: "test"), files: files)
    #expect(swapped.withLock { $0 })
    #expect(!grepped.hits.contains { $0.text?.contains("outside") ?? false })
    #expect(grepped.skipped.map(\.reason) == [.unreadable])
  }

  @Test func unreadableNestedDirectoryIsSkippedButNeighborStillFound() async throws {
    let folder = try ScratchFolder("computer-files-skip")
    let bad = folder.url.appending(path: "bad")
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: false)
    try Data("needle\n".utf8).write(to: folder.url.appending(path: "good.txt"))
    let files = ComputerFileSystem.local(beforeOpen: { if $0 == bad.path { throw OperationError(.fileUnavailable) } })
    let found = try await page(.init(mode: .find, pattern: "**/*.txt", root: folder.url.path, scope: "test"), files: files)
    #expect(found.hits.map(\.path) == [folder.url.path + "/good.txt"])
    #expect(found.skipped == [.init(reason: .unreadable, count: 1, example: bad.path)])
  }

  @Test func regexUsesICUSyntaxAndUnicode() async throws {
    let folder = try ScratchFolder("computer-files-regex")
    let path = folder.url.appending(path: "file").path
    try Data("abc12\n你好42\nabc\nABC99\n".utf8).write(to: URL(filePath: path))
    let grepped = try await page(.init(mode: .grep, pattern: "^\\p{L}+[0-9]{2}$", root: path, scope: "test"))
    #expect(grepped.hits.map(\.line) == [1, 2, 4])
    #expect(grepped.hits[1] == .init(path: path, line: 2, text: "你好42"))
    #expect(try await page(.init(mode: .grep, pattern: "(?i)^abc[0-9]+$", root: path, scope: "test")).hits.count == 2)
  }

  @Test func queryErrorsRefuseAtAdmissionWithTheirCode() async throws {
    let touched = Mutex(0)
    let files = ComputerFileSystem.local(beforeOpen: { _ in touched.withLock { $0 += 1 } })
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), authorize: { _, _ in })
    for (query, code) in [(SearchQuery(mode: .grep, pattern: "[", root: "/", scope: "test"), "invalidPattern"), (.init(mode: .find, pattern: "[", root: "/", scope: "test"), "invalidGlob"), (.init(mode: .find, pattern: "*", root: "/", scope: "test", limit: 0), "invalidLimit"), (.init(mode: .find, pattern: "*", root: "/", scope: "test", step: "nope"), "invalidStep")] {
      let url = URL(string: "https://test.invalid/machine/v2/machines/disk/operations/\(UUID())")!
      let response = try await agent.handler(Request(url: url, method: .post, body: .json(StartRequest(kind: "search.v1", input: json(query)))))
      #expect(response.status.code == 400)
      let error = try await response.body.json(ErrorEnvelope.self).error
      #expect(error.code == .invalidInput); #expect(error.details?.object?["search"] == .string(code))
    }
    let unknown = try await agent.handler(Request(url: URL(string: "https://test.invalid/machine/v2/machines/disk/operations/\(UUID())")!, method: .post, body: .json(StartRequest(kind: "search.v1", input: ["mode": "find", "pattern": "*", "root": "/", "scope": "disk", "entryLimit": 5]))))
    #expect(unknown.status.code == 400)
    #expect(touched.withLock { $0 } == 0)
  }

  @Test func missingRootFailsNotFound() async throws {
    let folder = try ScratchFolder("computer-files-missing")
    let verdict = try await search(.init(mode: .find, pattern: "*", root: folder.url.path + "/absent", scope: "test"))
    #expect(verdict.tag == .failed)
    #expect(verdict.error?.code == .fileUnavailable); #expect(verdict.error?.details?.object?["search"] == "notFound")
  }
}

/// Stalls on the real disk: a read that never returns must not hold a search
/// past its deadline, a stop, or a lease.
extension FileOperationTests {
  /// A disk whose first effect on `path` blocks until released, telling `entered` when it does.
  final class StalledDisk: Sendable {
    let path: String
    let (entered, writer) = AsyncStream<Void>.makeStream()
    private let gate = DispatchSemaphore(value: 0)
    private let first = Mutex(true)
    init(_ path: String) { self.path = path }
    var files: ComputerFileSystem { .local(beforeOpen: hook) }
    var hook: @Sendable (String) throws -> Void {
      { [self] addressed in
        guard addressed == path, first.withLock({ let was = $0; $0 = false; return was }) else { return }
        writer.yield(()); writer.finish(); gate.wait()
      }
    }

    func release() { gate.signal() }
  }

  func stalledFolder(_ name: String) throws -> (ScratchFolder, StalledDisk) {
    let folder = try ScratchFolder(name)
    let file = folder.url.appending(path: "stuck.txt")
    try Data("needle\n".utf8).write(to: file)
    return (folder, StalledDisk(file.path))
  }

  @Test func stalledReadEndsAtTheDeadline() async throws {
    let (folder, disk) = try stalledFolder("computer-files-stall-deadline")
    defer { disk.release() }
    let clock = VirtualClock()
    let source = LocalSearchSource(root: folder.url.path, effects: DiskEffects(), beforeIO: disk.hook)
    let search = Task {
      try await SearchQuery(mode: .grep, pattern: "needle", root: folder.url.path, scope: "test").run(in: source, clock: clock)
    }
    for await _ in disk.entered {}
    // Time cannot pass the deadline, so a search that outlives it waits for good.
    let error = await #expect(throws: SearchError.self) {
      try await clock.run(through: VirtualClock.at(SearchLimits.deadline)) { try await search.value }
    }
    #expect(error?.code == .timeout)
    #expect(clock.now == VirtualClock.at(SearchLimits.deadline))
  }

  @Test(arguments: ["stop", "lease"])
  func stopOrLeaseEndsASearchStalledOnARead(_ action: String) async throws {
    let (folder, disk) = try stalledFolder("computer-files-stall-\(action)")
    defer { disk.release() }
    let time = FileLocalTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: disk.files), clock: time.clock, receiptRetention: leaseJumpRetention, authorize: { _, _ in })
    let operations = try machineOperations(agent.handler)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      let operation = try await operations.open(.init(scope: "stall", key: action), machine: "disk", start: .init(kind: "search.v1", input: json(SearchQuery(mode: .grep, pattern: "needle", root: folder.url.path, scope: "test"))))
      for await _ in disk.entered {}
      if action == "stop" { try await operation.stop("testStop") } else { time.advance(.seconds(61)) }
      let end = try await operation.verdict()
      #expect(end.tag == .stopped)
      #expect(end.reason == (action == "stop" ? "testStop" : "leaseExpired"))
      await agent.shutdown(); await operations.shutdown()
    }
  }

  /// The line reaches the matcher only once the stop has cancelled the search, so the stop is met inside ICU's backtracking:
  /// a matcher that did not abandon it would never end.
  @Test(arguments: ["stop", "lease"])
  func pathologicalRegexStopsDuringICUBacktracking(_ action: String) async throws {
    let source = PathologicalLine()
    let files = ComputerFileSystem(status: { _ in throw OperationError(.fileUnavailable) }, read: { _, _, _ in throw OperationError(.fileUnavailable) }, search: { _ in source })
    let time = FileLocalTime()
    let agent = try OperationAgent(machine: "disk", kinds: fileOperationKinds(files: files), clock: time.clock, receiptRetention: leaseJumpRetention, authorize: { _, _ in })
    let operations = try machineOperations(agent.handler)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }; defer { group.cancelAll() }
      let operation = try await operations.open(.init(scope: "regex-stop", key: action), machine: "disk", start: .init(kind: "search.v1", input: json(SearchQuery(mode: .grep, pattern: "(a+)+$", root: PathologicalLine.path, scope: "test"))))
      await source.reading.wait()
      if action == "stop" { try await operation.stop("callerDeadline") } else { time.advance(.seconds(61)) }
      let end = try await operation.verdict()
      #expect(end.tag == .stopped)
      #expect(end.reason == (action == "stop" ? "callerDeadline" : "leaseExpired"))
      await agent.shutdown(); await operations.shutdown()
    }
  }
}

/// One file holding a line ICU backtracks on for good, read only once the reading search is cancelled.
private struct PathologicalLine: SearchSource, SearchReader {
  static let path = "/regex/file"
  let reading = Signal(), cancelled = Signal()
  func kind(_ path: String) async throws -> SearchEntryKind? { path == Self.path ? .file : nil }
  func children(of _: String, from _: String, limit _: Int) async throws -> SearchListing { .init(children: [], next: nil) }
  func open(_: String) async throws -> any SearchReader { self }
  func isHidden(_: String) -> Bool { false }
  func read(at offset: Int, count _: Int) async throws -> Data {
    guard offset == 0 else { return Data() }
    await withTaskCancellationHandler {
      reading.fire()
      await cancelled.wait()
    } onCancel: { cancelled.fire() }
    return Data((String(repeating: "a", count: 32000) + "!\n").utf8)
  }

  func close() async {}
}

/// Opens once, for every waiter, now and later.
private final class Signal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream() }
  func fire() { continuation.finish() }
  func wait() async { for await _ in stream {} }
}

func json(_ query: SearchQuery) -> JSONValue {
  try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(query))
}

actor FakeFiles {
  let data: Data; let chunk: Int
  var reads = 0; var largestRead = 0; var changed = false; var mutate = false
  init(data: Data, chunk: Int = 65536) { self.data = data; self.chunk = chunk }
  func mutateAfterRead() { mutate = true }
  func status() -> ComputerFileStatus { .init(version: changed ? "v2" : "v1", size: UInt64(data.count), kind: "file") }
  func read(offset: UInt64, count: Int) -> Data { reads += 1; largestRead = max(largestRead, count); if mutate { changed = true }; let start = min(Int(offset), data.count); return data.subdata(in: start ..< min(data.count, start + min(chunk, count))) }
  nonisolated var system: ComputerFileSystem {
    .init(status: { _ in await self.status() }, read: { _, offset, count in await self.read(offset: offset, count: count) }, search: { _ in NoFiles() })
  }
}

/// A search source with nothing in it.
struct NoFiles: SearchSource {
  func kind(_: String) async throws -> SearchEntryKind? { nil }
  func children(of _: String, from _: String, limit _: Int) async throws -> SearchListing { .init(children: [], next: nil) }
  func open(_: String) async throws -> any SearchReader { throw SearchUnreadable("none") }
  func isHidden(_: String) -> Bool { false }
}

final class FileLocalTime: Sendable {
  let value = Mutex<Duration>(.zero)
  /// Agent time that jumps only when told; held polls still wait in real time.
  var clock: OperationClock { .init(now: { self.value.withLock { $0 } }, sleep: { try await OperationClock.continuous.sleep($0) }) }
  func advance(_ duration: Duration) { value.withLock { $0 += duration } }
}
