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
@testable import SpaceServer
import Testing
import WorkerProtocol

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerCleanupTests {
  @Test(arguments: ["normal", "endpoints", "canonical", "binding-unlinked", "claim"])
  func cleanupAndReopenPreserveSiblingAndOperatorSentinels(phase: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let target = try await fixture.persistence.allocate(incarnation: UUID())
    let sibling = try await fixture.persistence.allocate(incarnation: UUID())
    let generation = try #require(UUID(uuidString: URL(fileURLWithPath: target.directory).lastPathComponent))
    let siblingGeneration = try #require(UUID(uuidString: URL(fileURLWithPath: sibling.directory).lastPathComponent))
    let store = try await ExecutionWorkerManifestStore.open(directory: target.directory, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    let siblingStore = try await ExecutionWorkerManifestStore.open(directory: sibling.directory, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    let manifest = ExecutionWorkerManifest(version: 2, space: fixture.space, generation: generation, incarnation: UUID(), processID: Int32.max, birth: "fixture-dead-process-birth", credentials: .init(current: String(repeating: "a", count: 72)), sockets: target.location)
    let siblingManifest = ExecutionWorkerManifest(version: 2, space: fixture.space, generation: siblingGeneration, incarnation: UUID(), processID: getpid(), birth: try processBirthIdentity(getpid()), credentials: .init(current: String(repeating: "b", count: 72)), sockets: sibling.location)
    try await store.save(manifest)
    try await siblingStore.save(siblingManifest)
    let preserved = [sibling.directory + "/manifest.json", sibling.location.directory + "/identity.json", fixture.root + "/operator-sentinel", fixture.persistence.runtimeRoot + "/operator-sentinel"]
    for path in preserved.suffix(2) {
      #expect(FileManager.default.createFile(atPath: path, contents: Data("operator".utf8), attributes: [.posixPermissions: 0o600]))
    }
    let snapshots = try preserved.map { path -> (Data, stat) in
      var state = stat()
      #expect(lstat(path, &state) == 0)
      return (try Data(contentsOf: URL(fileURLWithPath: path)), state)
    }
    let listener = try await WorkerListener.bind(socket: target.location.worker, handler: { _ in .text("target") })
    let initial = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    if case .manifest = await initial.read(target.directory) {} else { Issue.record("Could not inspect target") }
    if phase == "normal" {
      try await initial.cleanup(target.directory)
    } else {
      let sockets = try #require(await ExecutionWorkerSocketDirectory.openIfPresent(target.location, space: fixture.space, generation: generation, runtimeRoot: fixture.persistence.runtimeRoot))
      try await sockets.removeEndpoints()
      if phase != "endpoints" {
        let record = try await ExecutionWorkerCleanup.stage(store: store, space: fixture.space, generation: generation, location: target.location, sockets: sockets, manifest: manifest)
        try await store.retireCleanupManifest(record)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: target.directory + "/cleanup.json"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(manifest.credentials.current))
        if phase == "binding-unlinked" { #expect(unlink(target.location.directory + "/identity.json") == 0) }
        if phase == "claim" { try await sockets.cleanup() }
      }
      let reopened = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
      let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { await reopened.inventory() }, read: { await reopened.read($0) }, process: { $0.generation == generation ? .absent : .unverified }, terminate: { _, _ in Issue.record("Cleanup must never signal a fixture sibling"); return .unconfirmed }, cleanup: { try await reopened.cleanup($0) }, report: { _ in }))
      #expect(result.counts[.cleanupFailed] == nil)
      #expect(result.counts[.unsafeStorage] == 1)
    }
    await listener.shutdown()
    #expect(!FileManager.default.fileExists(atPath: target.directory))
    #expect(!FileManager.default.fileExists(atPath: target.location.directory))
    for (path, snapshot) in zip(preserved, snapshots) {
      var state = stat()
      #expect(lstat(path, &state) == 0)
      #expect(state.st_dev == snapshot.1.st_dev && state.st_ino == snapshot.1.st_ino && state.st_mode == snapshot.1.st_mode)
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == snapshot.0)
    }
  }

  @Test(arguments: ["generation", "empty-root", "missing-root"])
  func cleanupTombstoneNeverDeletesAReplacementRuntimeClaim(kind: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let target = try await fixture.persistence.allocate(incarnation: UUID())
    let generation = try #require(UUID(uuidString: URL(fileURLWithPath: target.directory).lastPathComponent))
    let store = try await ExecutionWorkerManifestStore.open(directory: target.directory, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    let sockets = try #require(await ExecutionWorkerSocketDirectory.openIfPresent(target.location, space: fixture.space, generation: generation, runtimeRoot: fixture.persistence.runtimeRoot))
    let record = try await ExecutionWorkerCleanup.stage(store: store, space: fixture.space, generation: generation, location: target.location, sockets: sockets, manifest: nil)
    try await store.retireCleanupManifest(record)
    let markerPath = target.directory + "/cleanup.json"
    let marker = try Data(contentsOf: URL(fileURLWithPath: markerPath))
    let originalBinding: String
    if kind == "generation" {
      #expect(rename(target.location.directory, target.location.directory + "-old") == 0)
      originalBinding = target.location.directory + "-old/identity.json"
      _ = try await ExecutionWorkerSocketDirectory.create(space: fixture.space, generation: generation, runtimeRoot: fixture.persistence.runtimeRoot)
    } else {
      #expect(rename(fixture.persistence.runtimeRoot, fixture.persistence.runtimeRoot + "-old") == 0)
      originalBinding = fixture.persistence.runtimeRoot + "-old/" + target.location.key + "/identity.json"
      if kind == "empty-root" { #expect(mkdir(fixture.persistence.runtimeRoot, 0o700) == 0) }
    }
    let binding = try Data(contentsOf: URL(fileURLWithPath: originalBinding))
    let reopened = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    if case .unsafeStorage = await reopened.read(target.directory) {} else { Issue.record("Substituted cleanup claim must refuse") }
    await #expect(throws: WorkerProtocolError.self) { try await reopened.cleanup(target.directory) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: markerPath)) == marker)
    #expect(try Data(contentsOf: URL(fileURLWithPath: originalBinding)) == binding)
    if kind == "generation" { #expect(FileManager.default.fileExists(atPath: target.location.directory + "/identity.json")) }
  }

  @Test(arguments: ["version", "space", "generation", "claim", "mode", "symlink"])
  func malformedOrUnsafeCleanupRecordsRefuseRecovery(kind: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let target = try await fixture.persistence.allocate(incarnation: UUID())
    let generation = try #require(UUID(uuidString: URL(fileURLWithPath: target.directory).lastPathComponent))
    let store = try await ExecutionWorkerManifestStore.open(directory: target.directory, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    let sockets = try #require(await ExecutionWorkerSocketDirectory.openIfPresent(target.location, space: fixture.space, generation: generation, runtimeRoot: fixture.persistence.runtimeRoot))
    let record = try await ExecutionWorkerCleanup.stage(store: store, space: fixture.space, generation: generation, location: target.location, sockets: sockets, manifest: nil)
    let changed = ExecutionWorkerCleanup(version: kind == "version" ? 2 : 1, space: kind == "space" ? "other" : fixture.space, generation: kind == "generation" ? UUID() : generation, location: record.location, claim: kind == "claim" ? .init(root: "", directory: "", binding: "") : record.claim)
    let path = target.directory + "/cleanup.json"
    try JSONEncoder().encode(changed).write(to: URL(fileURLWithPath: path))
    if kind == "mode" { #expect(chmod(path, 0o644) == 0) }
    if kind == "symlink" {
      #expect(rename(path, fixture.base + "/old-cleanup") == 0)
      #expect(symlink(fixture.base + "/old-cleanup", path) == 0)
    }
    let reopened = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    if case .unsafeStorage = await reopened.read(target.directory) {} else { Issue.record("Unsafe cleanup record bypassed inventory gate") }
    #expect(FileManager.default.fileExists(atPath: target.location.directory + "/identity.json"))
  }
}
