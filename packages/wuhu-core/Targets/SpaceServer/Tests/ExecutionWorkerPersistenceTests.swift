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
import ExecutionOwner
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Subprocess
import Testing
import struct WorkerOwner.ExecutionWorkerBootstrap
import WorkerProtocol

struct PersistenceFixture {
  let base: String
  let space = UUID().uuidString.lowercased()
  var config: String { base + "/deliberately-long-canonical-worker-configuration-directory" }
  var root: String { config + "/workers/" + space }
  var persistence: ExecutionWorkerPersistence { .init(configDirectory: config, space: space, runtimeRoot: base + "/r") }

  init(root: String = "/tmp") throws {
    let resolved = try #require(realpath(root, nil))
    defer { free(resolved) }
    base = String(cString: resolved) + "/wp-" + String(UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func clean() { try? FileManager.default.removeItem(atPath: base) }
  func manifest() async throws -> (String, ExecutionWorkerManifest) {
    let entries = try FileManager.default.contentsOfDirectory(atPath: root)
    let directory = root + "/" + (try #require(entries.count == 1 ? entries.first : nil))
    let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: space, runtimeRoot: persistence.runtimeRoot)
    return (directory, try #require(await store.load()))
  }
}

@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct ExecutionWorkerPersistenceTests {
  private func binary() throws -> String {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
  }

  @Test func realChildIsDurablyIdentifiedBeforeAdmissionAndCleanExitRemovesBothLayouts() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let space = try Space.inMemory()
      let incarnation = UUID()
      let connection = try await WorkerConnection.start(executable: binary(), owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, persistence: fixture.persistence, incarnation: incarnation, activity: { _ in }, exited: {})
      let result: Result<Void, any Error>
      do {
        let (directory, manifest) = try await fixture.manifest()
        #expect(manifest.incarnation == incarnation)
        #expect(manifest.processID == connection.processID)
        #expect(manifest.birth == (try processBirthIdentity(connection.processID)))
        #expect((directory + "/worker.sock").utf8.count >= 104)
        let location = try #require(manifest.sockets)
        #expect(FileManager.default.fileExists(atPath: location.worker))
        #expect(FileManager.default.fileExists(atPath: location.parent))
        _ = try await connection.client.negotiate(ExecutionWorkerBootstrap.hello(release: "persistence-fixture"))
        result = .success(())
      } catch { result = .failure(error) }
      await connection.stop()
      try result.get()
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.persistence.runtimeRoot).isEmpty)
    }
  }

  @Test func configuredPublicHostWritesWorkerEvidenceBeforeWork() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let folder = URL(fileURLWithPath: fixture.base + "/space")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
      let id = try await space.identity().rawValue
      let session = try await space.sessions.createSession(group: .shared, title: "fixture", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      _ = try await space.sessions.enqueue(session, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "fixture work"))))
      let host = try await SpaceHost.open(folder: folder, deployment: DeploymentRecord(origin: "https://persistence.test", tlsFingerprint: "fixture", certificate: .provided), configDirectory: URL(fileURLWithPath: fixture.config), allowEnvironmentCredentials: false, executionPlacement: .worker(executable: URL(fileURLWithPath: binary())), webApp: nil)
      let running = Task { await host.run() }
      let root = fixture.config + "/workers/" + id
      let result: Result<Void, any Error>
      do {
        try await until("configured host persists its real child") {
          guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root), let entry = entries.first else { return false }
          return FileManager.default.fileExists(atPath: root + "/" + entry + "/manifest.json")
        }
        let entry = try #require(FileManager.default.contentsOfDirectory(atPath: root).first)
        let store = try await ExecutionWorkerManifestStore.open(directory: root + "/" + entry, space: id)
        let record = try #require(await store.load())
        #expect(record.space == id && record.processID != getpid())
        #expect(try processBirthIdentity(record.processID) == record.birth)
        result = .success(())
      } catch { result = .failure(error) }
      try await host.shutdown()
      await running.value
      try result.get()
      #expect(try FileManager.default.contentsOfDirectory(atPath: root).isEmpty)
    }
  }

  @Test func childExitsOnEOFBeforeReceivingAnyBootstrap() async throws {
    let result = try await Subprocess.run(.path(.init(binary())), arguments: ["_execution-worker"], environment: .custom([:]), input: .inputWriter, output: .discarded, error: .discarded) { execution in
      #expect(execution.processIdentifier.value > 0)
      // Returning closes the parent's only pipe writer, as a pre-persistence parent crash does.
    }
    #expect(result.terminationStatus == .exited(1))
  }

  @Test func startupFailureDoesNotLeaveCredentialsOrReuseStorageGeneration() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let space = try Space.inMemory()
      await #expect(throws: WorkerProtocolError.self) {
        try await WorkerConnection.start(executable: "/nonexistent-worker-fixture", owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, persistence: fixture.persistence, activity: { _ in }, exited: {})
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root).isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.persistence.runtimeRoot).isEmpty)
      let incarnation = UUID()
      let first = try await fixture.persistence.allocate(incarnation: incarnation)
      let second = try await fixture.persistence.allocate(incarnation: incarnation)
      #expect(first.directory != second.directory && first.location != second.location)
      try await first.cleanup()
      try await second.cleanup()
    }
  }

  @Test func liveOrChangedEvidenceIsNeverRemovedByCleanExitCleanup() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let storage = try await fixture.persistence.allocate(incarnation: UUID())
    let token = String(repeating: "a", count: 72)
    try await storage.persist(processID: getpid(), token: token)
    try await storage.admit(processID: getpid())
    await #expect(throws: WorkerProtocolError.self) { try await storage.admit(processID: Int32.max) }
    await #expect(throws: WorkerProtocolError.self) { try await storage.cleanup() }
    #expect(FileManager.default.fileExists(atPath: storage.directory + "/manifest.json"))
    let (_, manifest) = try await fixture.manifest()
    #expect(manifest.credentials.current == token)
    #expect(!String(describing: manifest).contains(token))
  }

  @Test func pinTransitionRejectsReplacementOfAnAlreadyPinnedSocket() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let storage = try await fixture.persistence.allocate(incarnation: UUID())
    let original = try await WorkerListener.bind(socket: storage.location.parent, handler: { _ in .text("original") })
    try await storage.pinEndpoints()
    #expect(rename(storage.location.parent, fixture.base + "/old-parent.sock") == 0)
    let replacement = try await WorkerListener.bind(socket: storage.location.parent, handler: { _ in .text("replacement") })
    await #expect(throws: WorkerProtocolError.self) { try await storage.pinEndpoints() }
    await #expect(throws: WorkerProtocolError.self) { try await storage.cleanup() }
    #expect(FileManager.default.fileExists(atPath: storage.location.parent))
    await original.shutdown()
    await replacement.shutdown()
  }

  @Test func failedManifestPersistenceCannotAdmitOrSendBootstrap() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let storage = try await fixture.persistence.allocate(incarnation: UUID())
    #expect(chmod(storage.directory, 0o755) == 0)
    await #expect(throws: WorkerProtocolError.self) { try await storage.persist(processID: getpid(), token: String(repeating: "a", count: 72)) }
    #expect(chmod(storage.directory, 0o700) == 0)
    await #expect(throws: WorkerProtocolError.self) { try await storage.admit(processID: getpid()) }
    #expect(!FileManager.default.fileExists(atPath: storage.directory + "/manifest.json"))
    #expect(FileManager.default.fileExists(atPath: storage.location.directory + "/identity.json"))
  }

  @Test(arguments: ["workers-mode", "workers-symlink", "config-mode", "canonical-replaced", "generation-replaced", "binding-replaced"])
  func unsafeStorageNeverGetsRepairedOrRepinned(kind: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    if kind == "workers-mode" { #expect(mkdir(fixture.config + "/workers", 0o755) == 0) }
    if kind == "workers-symlink" { #expect(symlink(fixture.base, fixture.config + "/workers") == 0) }
    if kind == "config-mode" { #expect(chmod(fixture.config, 0o777) == 0) }
    if kind.hasSuffix("replaced") {
      let storage = try await fixture.persistence.allocate(incarnation: UUID())
      if kind == "canonical-replaced" {
        #expect(rename(storage.directory, storage.directory + "-old") == 0)
        #expect(mkdir(storage.directory, 0o700) == 0)
        await #expect(throws: WorkerProtocolError.self) { try await storage.persist(processID: getpid(), token: String(repeating: "a", count: 72)) }
      } else if kind == "generation-replaced" {
        #expect(rename(storage.location.directory, storage.location.directory + "-old") == 0)
        _ = try await ExecutionWorkerSocketDirectory.create(space: fixture.space, generation: UUID(uuidString: URL(fileURLWithPath: storage.directory).lastPathComponent)!, runtimeRoot: fixture.persistence.runtimeRoot)
      } else {
        let path = storage.location.directory + "/identity.json"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(rename(path, fixture.base + "/old-binding") == 0)
        #expect(FileManager.default.createFile(atPath: path, contents: bytes, attributes: [.posixPermissions: 0o600]))
      }
      if kind != "canonical-replaced" {
        await #expect(throws: WorkerProtocolError.self) { try await storage.pinEndpoints() }
      }
      await #expect(throws: WorkerProtocolError.self) { try await storage.cleanup() }
      #expect(FileManager.default.fileExists(atPath: storage.location.directory + "/identity.json"))
    } else {
      await #expect(throws: WorkerProtocolError.self) { try await fixture.persistence.allocate(incarnation: UUID()) }
    }
  }
}
