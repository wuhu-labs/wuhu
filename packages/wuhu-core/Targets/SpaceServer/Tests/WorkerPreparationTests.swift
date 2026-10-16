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
import ExecutionOwner
import ImageRetention
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct WorkerPreparationTests {
  @Test func dedicatedLeaseSurvivesParentCloseAndStderrRedirectionWithNoOtherInheritedDescriptors() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let root = fixture.config + "/execution-images"
    var preparation: ImagePreparation? = try ImageRetention.transaction(root: root) { try $0.prepare(source: URL(fileURLWithPath: "/bin/sh").resolvingSymlinksInPath().path, id: UUID(), owner: "fixture") }
    let reference = try #require(preparation?.reference)
    let path = try ImageRetention.transaction(root: root) { try $0.imagePath(reference) }
    let stray = open("/dev/null", O_RDONLY)
    try #require(stray >= 0)
    defer { _ = close(stray) }
    try #require(fcntl(stray, F_SETFD, 0) == 0)
    let report = fixture.base + "/descriptors"
    let script = "actual=''; n=0; while [ $n -lt 1024 ]; do if [ -e /dev/fd/$n ]; then actual=\"$actual$n \"; fi; n=$((n+1)); done; printf '%s' \"$actual\" > '\(report)'; exec 2>/dev/null; read answer; exit 0"
    let child = try WorkerChildProcess.spawn(executable: "/bin/sh", arguments: ["-c", script], lease: #require(preparation?.descriptor))
    let birth = try processBirthIdentity(child.processID)
    preparation = nil
    let result: Result<Void, any Error>
    do {
      try await until("child descriptor report") { (try? String(contentsOfFile: report, encoding: .utf8).isEmpty) == false }
      #expect(try String(contentsOfFile: report, encoding: .utf8) == "0 1 2 3 ")
      try ImageRetention.transaction(root: root) { store throws -> Void in
        #expect(try store.references() == [reference])
        #expect(throws: ImageRetentionError.processStillLive) { try store.release(reference) }
      }
      #expect(kill(child.processID, 0) == 0)
      result = .success(())
    } catch { result = .failure(error) }
    _ = close(child.input)
    await WorkerConnection.waitForExecChild(processID: child.processID, birth: birth)
    try result.get()
    #expect(try ImageRetention.transaction(root: root) { try $0.references().isEmpty })
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func invalidExecutableBeforeSpawnCallbackRetiresPreparation() async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let path = fixture.base + "/invalid-worker"
      try Data("not an executable format".utf8).write(to: URL(fileURLWithPath: path))
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
      let space = try Space.inMemory()
      await #expect(throws: (any Error).self) {
        _ = try await WorkerConnection.start(executable: path, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, persistence: fixture.persistence, activity: { _ in }, exited: {})
      }
      #expect(try ImageRetention.transaction(root: fixture.config + "/execution-images") { try $0.references().isEmpty })
      #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root).isEmpty)
    }
  }

  @Test func bootReconcilesInterruptedPreparationWithoutManifest() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    var storage: ExecutionWorkerRuntimeStorage? = try await fixture.persistence.allocate(incarnation: UUID())
    _ = try await storage?.prepareImage(executable: "/bin/sh")
    let directory = try #require(storage?.directory)
    storage = nil
    let boot = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    _ = await boot.inventory()
    guard case .cleanup(nil) = await boot.read(directory) else { Issue.record("Prepared image was not recoverable at boot"); return }
    try await boot.cleanup(directory)
    #expect(!FileManager.default.fileExists(atPath: directory))
    #expect(try ImageRetention.transaction(root: fixture.config + "/execution-images") { try $0.references().isEmpty })
  }

  @Test func bootRetainsTheBindBeforeManifestWindowUntilTheActualChildExits() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let root = fixture.config + "/execution-images"
    var storage: ExecutionWorkerRuntimeStorage? = try await fixture.persistence.allocate(incarnation: UUID())
    _ = try #require(try await storage?.prepareImage(executable: "/bin/sh"))
    let directory = try #require(storage?.directory)
    let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    let prepared = try #require(try await store.loadPreparation())
    let child = try WorkerChildProcess.spawn(executable: "/bin/sh", arguments: ["-c", "read ignored; exit 0"], lease: #require(await storage?.preparationDescriptor))
    let birth = try processBirthIdentity(child.processID)
    let bound = try ImageRetention.transaction(root: root) { try $0.bind(prepared.image, processID: child.processID, birth: birth) }
    storage = nil
    let boot = ExecutionWorkerBootStorage(root: fixture.root, space: fixture.space, runtimeRoot: fixture.persistence.runtimeRoot)
    _ = await boot.inventory()
    guard case .missingManifest = await boot.read(directory) else {
      _ = close(child.input)
      await WorkerConnection.waitForExecChild(processID: child.processID, birth: birth, terminate: true)
      Issue.record("Live pre-manifest child was not retained")
      return
    }
    #expect(try ImageRetention.transaction(root: root) { try $0.references() == [bound] })
    _ = close(child.input)
    await WorkerConnection.waitForExecChild(processID: child.processID, birth: birth)
    _ = await boot.inventory()
    guard case .cleanup(nil) = await boot.read(directory) else { Issue.record("Retired pre-manifest child was not recoverable"); return }
    try await boot.cleanup(directory)
    #expect(!FileManager.default.fileExists(atPath: directory))
    #expect(try ImageRetention.transaction(root: root) { try $0.references().isEmpty })
  }
}
