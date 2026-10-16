#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Dependencies
import Synchronization
import Testing
import class WorkerProtocol.WorkerListener
import struct WorkerProtocol.WorkerProtocolError

@Suite(.enabled(if: !carrierFixtureRequested), .serialized, .timeLimit(.minutes(2))) struct ListenerExportTests {
  @Test func pausedExportServesQueuedConnectionInExecSuccessor() async throws {
    try await exerciseSourceExport(.commit)
  }

  @Test func pausedExportRollbackServesQueuedConnectionExactlyOnce() async throws {
    try await exerciseSourceExport(.refused)
  }

  @Test func sourceShutdownBeforeCommitPreservesLiveSuccessorPath() async throws {
    try await exerciseSourceExport(.sourceShutdown)
  }

  @Test func lostCommitLeaksUntilNextBindReclaimsStalePath() async throws {
    try await exerciseSourceExport(.lostCommit)
  }

  @Test func successorReadinessFailureResumesSourceWithNewConnections() async throws {
    let directory = "/tmp/rollback-" + UUID().uuidString
    try #require(mkdir(directory, 0o700) == 0)
    let path = directory + "/owner.sock"
    defer { _ = unlink(path); _ = rmdir(directory) }
    let source = try await WorkerListener.bind(socket: path) { _ in .text("resumed-source") }
    let result: Result<Void, any Error>
    do {
      try await source.pauseAccepting()
      let exported = try await source.exportListener()
      let metadata = exportMetadata(exported, path: path, scenario: .readinessFailure)
      try #require(try spawnCarrierTest(mode: "listener", descriptor: exported.descriptor, mapping: true, listenerEnvironment: metadata) == 0)
      try await source.resumeAccepting()
      try #require(try await Task.detached { try requestListener(path: path) }.value.hasSuffix("resumed-source"))
      result = .success(())
    } catch { result = .failure(error) }
    await source.shutdown()
    try result.get()
    var remaining = stat()
    try #require(lstat(path, &remaining) == -1 && errno == ENOENT)
  }

  @Test func exportPinsPathAndReleasesItsOwnDuplicate() async throws {
    let directory = "/tmp/export-" + UUID().uuidString
    try #require(mkdir(directory, 0o700) == 0)
    let path = directory + "/owner.sock"
    defer { _ = unlink(path); _ = rmdir(directory) }
    let source = try await WorkerListener.bind(socket: path) { _ in .text("source") }
    let result: Result<Void, any Error>
    var replacement: Int32 = -1
    do {
      await #expect(throws: WorkerProtocolError.self) { _ = try await source.finishHandoff() }
      try await source.pauseAccepting()
      let released = try await temporaryExport(source)
      var state = stat()
      if fstat(released.descriptor, &state) == 0 {
        try #require(UInt64(truncatingIfNeeded: state.st_dev) != released.identity.descriptorDevice || UInt64(truncatingIfNeeded: state.st_ino) != released.identity.descriptorInode)
      } else { try #require(errno == EBADF) }
      try #require(unlink(path) == 0)
      replacement = try rawListener(path: path)
      await #expect(throws: WorkerProtocolError.self) { try await source.exportListener() }
      result = .success(())
    } catch { result = .failure(error) }
    await source.shutdown()
    defer { if replacement >= 0 { _ = close(replacement) } }
    try result.get()
    var remaining = stat()
    try #require(lstat(path, &remaining) == 0)
    await #expect(throws: WorkerProtocolError.self) { try await source.pauseAccepting() }
    await #expect(throws: WorkerProtocolError.self) { _ = try await source.finishHandoff() }
  }
}

private func temporaryExport(_ source: WorkerListener) async throws -> (descriptor: Int32, identity: WorkerListener.InheritedIdentity) {
  let exported = try await source.exportListener()
  return (exported.descriptor, exported.identity)
}

private enum SourceExportScenario { case commit, refused, sourceShutdown, lostCommit }

private func exportMetadata(_ exported: WorkerListener.ListenerExport, path: String, scenario: ListenerScenario) -> [String: String] {
  [
    "PATH": path, "SCENARIO": scenario.rawValue,
    "FD_DEVICE": String(exported.identity.descriptorDevice), "FD_INODE": String(exported.identity.descriptorInode),
    "PATH_DEVICE": String(exported.identity.pathDevice), "PATH_INODE": String(exported.identity.pathInode),
  ]
}

private func exerciseSourceExport(_ scenario: SourceExportScenario) async throws {
  let directory = "/tmp/source-" + UUID().uuidString
  try #require(mkdir(directory, 0o700) == 0)
  let path = directory + "/owner.sock"
  defer { _ = unlink(path); _ = rmdir(directory) }
  let calls = Mutex(0)
  let accepted = AsyncStream<Void>.makeStream()
  let release = AsyncStream<Void>.makeStream()
  defer { accepted.continuation.finish(); release.continuation.finish() }
  let source = try await WorkerListener.bind(socket: path) { request in
    calls.withLock { $0 += 1 }
    if request.url.path == "/established" {
      accepted.continuation.yield(())
      for await _ in release.stream { break }
    }
    return .text("source-listener")
  }
  let result: Result<Void, any Error>
  do {
    await #expect(throws: WorkerProtocolError.self) { try await source.exportListener() }
    await #expect(throws: WorkerProtocolError.self) { try await source.resumeAccepting() }
    let established = try sendListenerRequest(path: path, route: "/established")
    defer { _ = close(established) }
    for await _ in accepted.stream { break }
    try await source.pauseAccepting()
    await #expect(throws: WorkerProtocolError.self) { try await source.pauseAccepting() }
    let exported = try await source.exportListener()
    try #require(fcntl(exported.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    try #require(try spawnCarrierTest(mode: "absent", descriptor: exported.descriptor) == 0)
    let queued = try sendListenerRequest(path: path)
    defer { _ = close(queued) }
    var event = pollfd(fd: queued, events: Int16(POLLIN), revents: 0)
    try #require(poll(&event, 1, 100) == 0)
    try #require(calls.withLock { $0 } == 1)
    release.continuation.yield(())
    try #require(try await Task.detached { try readListenerResponse(established) }.value.hasSuffix("source-listener"))
    var before = stat()
    try #require(lstat(path, &before) == 0)
    var metadata = exportMetadata(exported, path: path, scenario: .queuedExport)
    if scenario != .refused {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { [metadata] in try #require(try spawnCarrierTest(mode: "listener", descriptor: exported.descriptor, mapping: true, listenerEnvironment: metadata) == 0) }
        do {
          let response = try await Task.detached { try readListenerResponse(queued) }.value
          try #require(response.hasSuffix("adopted-listener"))
          try #require(response.components(separatedBy: "HTTP/1.1 200").count == 2)
          let route: String
          if scenario == .commit {
            let ownership = try await source.finishHandoff()
            try #require(ownership.socket == path)
            let numbers = ownership.identity
            route = "/commit/\(numbers.descriptorDevice)/\(numbers.descriptorInode)/\(numbers.pathDevice)/\(numbers.pathInode)"
          } else {
            if scenario == .lostCommit {
              _ = try await source.finishHandoff()
              await #expect(throws: WorkerProtocolError.self) {
                try await WorkerListener.bind(socket: path) { _ in .text("must-not-replace-live-successor") }
              }
            } else { await source.shutdown() }
            try #require(try await Task.detached { try requestListener(path: path) }.value.hasSuffix("adopted-listener"))
            route = "/abandon"
          }
          var after = stat()
          try #require(lstat(path, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino)
          let ack = try sendListenerRequest(path: path, route: route)
          defer { _ = close(ack) }
          try await group.waitForAll()
        } catch {
          group.cancelAll()
          throw error
        }
      }
      try #require(calls.withLock { $0 } == 1)
    } else {
      metadata["SCENARIO"] = ListenerScenario.descriptorIdentity.rawValue
      metadata["FD_INODE"] = String(exported.identity.descriptorInode + 1)
      try #require(try spawnCarrierTest(mode: "listener", descriptor: exported.descriptor, mapping: true, listenerEnvironment: metadata) == 0)
      try await source.resumeAccepting()
      await #expect(throws: WorkerProtocolError.self) { try await source.exportListener() }
      await #expect(throws: WorkerProtocolError.self) { try await source.resumeAccepting() }
      let response = try await Task.detached { try readListenerResponse(queued) }.value
      try #require(response.hasSuffix("source-listener"))
      try #require(response.components(separatedBy: "HTTP/1.1 200").count == 2)
      try #require(calls.withLock { $0 } == 2)
      var after = stat()
      try #require(lstat(path, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino)
    }
    try #require(fcntl(exported.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    result = .success(())
  } catch { result = .failure(error) }
  await source.shutdown()
  try result.get()
  var after = stat()
  if scenario == .sourceShutdown || scenario == .lostCommit {
    try #require(lstat(path, &after) == 0)
    let replacement = try await WorkerListener.bind(socket: path) { _ in .text("reclaimed-stale-path") }
    let proof: Result<String, any Error>
    do { proof = .success(try await Task.detached { try requestListener(path: path) }.value) }
    catch { proof = .failure(error) }
    await replacement.shutdown()
    try #require(try proof.get().hasSuffix("reclaimed-stale-path"))
  }
  try #require(lstat(path, &after) == -1 && errno == ENOENT)
  await #expect(throws: WorkerProtocolError.self) { try await source.exportListener() }
}

func runQueuedExportFixture(descriptor: Int32, path: String, identity: WorkerListener.InheritedIdentity) async throws {
  let acknowledged = AsyncStream<WorkerListener.InheritedIdentity?>.makeStream()
  let queuedCalls = Mutex(0)
  let listener = try await WorkerListener.adopt(descriptor, socket: path, expecting: identity) { request in
    if request.url.path == "/abandon" { acknowledged.continuation.yield(nil) }
    else if request.url.path.hasPrefix("/commit/") {
      let fields = request.url.path.split(separator: "/").dropFirst().compactMap { UInt64($0) }
      guard fields.count == 4 else { throw WorkerProtocolError(.invalidConfiguration, message: "Invalid fixture commit") }
      acknowledged.continuation.yield(.init(descriptorDevice: fields[0], descriptorInode: fields[1], pathDevice: fields[2], pathInode: fields[3]))
    } else { queuedCalls.withLock { $0 += 1 } }
    return .text("adopted-listener")
  }
  let result: Result<Void, any Error>
  do {
    try #require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    try #require(try spawnCarrierTest(mode: "absent", descriptor: descriptor) == 0)
    let committed = try await withThrowingTaskGroup(of: WorkerListener.InheritedIdentity?.self) { group in
      group.addTask {
        for await identity in acknowledged.stream { return identity }
        throw WorkerProtocolError(.unavailable, message: "Acknowledgement ended")
      }
      group.addTask {
        @Dependency(\.continuousClock) var clock
        try await clock.sleep(for: .seconds(15))
        throw WorkerProtocolError(.unavailable, message: "Queued export fixture timed out")
      }
      defer { group.cancelAll() }
      return try #require(try await group.next())
    }
    if let committed { try await listener.commitHandoff(.init(socket: path, identity: committed)) }
    try #require(queuedCalls.withLock { $0 } == (committed == nil ? 2 : 1))
    result = .success(())
  } catch { result = .failure(error) }
  acknowledged.continuation.finish()
  await listener.shutdown()
  try result.get()
}
