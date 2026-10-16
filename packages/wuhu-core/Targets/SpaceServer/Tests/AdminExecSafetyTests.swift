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
import AsyncHTTPClient
import ExecutionOwner
import Fetch
import ServeNIO
import ServeTLS
import SpaceCore
@testable import SpaceServer
import Subprocess
import Synchronization
import Testing

@Suite(.enabled(if: !adminExecFixtureRequested), .sessionFixtures(timeLimit: .minutes(1))) struct AdminExecSafetyTests {
  @Test func stagingRefusesSymlinksHardlinksWrongModesAndPinsTheDirectory() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let files = try AdminExecFiles(folder: URL(fileURLWithPath: fixture.base), create: true)
    let path = fixture.base + "/source"
    try Data("executable fixture".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o500) == 0)
    let source = try AdminExecImage(path: path)
    let name = "last-good-" + source.digest
    #expect(symlink(path, files.path + "/" + name) == 0)
    #expect(throws: (any Error).self) { try files.stageImage(source) }
    #expect(unlink(files.path + "/" + name) == 0)
    #expect(link(path, files.path + "/" + name) == 0)
    #expect(throws: (any Error).self) { try files.stageImage(source) }
    #expect(unlink(files.path + "/" + name) == 0)
    let image = try files.stageImage(source)
    #expect(chmod(image.path, 0o700) == 0)
    #expect(throws: (any Error).self) { try files.stageImage(source) }
    #expect(chmod(image.path, 0o500) == 0)
    let moved = fixture.base + "/pinned"
    #expect(rename(files.path, moved) == 0)
    try FileManager.default.createDirectory(atPath: files.path, withIntermediateDirectories: false)
    #expect(symlink("/bin/false", files.path + "/" + name) == 0)
    let pinned = try files.stageImage(source)
    #expect(try adminExecDigest(pinned.descriptor) == source.digest)
    #expect(fcntl(pinned.descriptor, F_GETFD) & FD_CLOEXEC != 0)
  }

  @Test(.enabled(if: adminExecPlatformSupported), arguments: ["image-pin", "stray-fd"])
  func execUsesPinnedImageAndExcludesStrayDescriptors(_ mode: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let executable = try #require(try ExecutionPlacement.worker().executable)
    var environment: [Environment.Key: String] = ["PATH": "/usr/bin:/bin", "HOME": fixture.base, "WUHU_ADMIN_EXEC_TEST_FIXTURE": "v1", "TESTBRIDGE_TEST_ONLY": "^AdminExecProcessFixture/run"]
    for key in ["SDKROOT", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[Environment.Key(stringLiteral: key)] = value }
    }
    let result = try await Subprocess.run(.path(.init(executable)), arguments: ["--wuhu-admin-exec-fixture", "v1", fixture.base, "/unused", mode], environment: .custom(environment), input: .none, output: .discarded, error: .string(limit: 4096))
    #expect(result.terminationStatus == .exited(0), "\(result.standardError)")
  }

  @Test(.enabled(if: adminExecPlatformSupported)) func failedExecLeavesTheSourceDescriptorTableUntouched() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let path = fixture.base + "/not-an-executable"
    try Data("invalid image".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o500) == 0)
    let image = try AdminExecImage(path: path)
    let stray = open(fixture.base + "/stray", O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
    #expect(stray >= 0)
    defer { _ = close(stray) }
    let flags = fcntl(stray, F_GETFD)
    #expect(flags & FD_CLOEXEC == 0)
    #expect(throws: AdminExecError.refused("execSystemCall")) { try image.execute(metadata: nil) }
    #expect(fcntl(stray, F_GETFD) == flags)
    #expect(write(stray, "ok", 2) == 2)
  }

  @Test func authenticatedBusyRefusalReturnsWithoutWaitingForAReplyThatCannotArrive() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let socket = try await AdminExecSocket(path: fixture.base + "/admin.sock")
    let serving = Task { await socket.run(allowedUIDs: [UInt32(geteuid())]) { uid, _ in
      #expect(uid == UInt32(geteuid()))
      throw AdminExecError.refused("requestBusy")
    } }
    let message = AdminExecSocket.Message(id: UUID())
    let reply = try await AdminExecSocket.exchange(path: socket.path, message: message)
    #expect(reply.id == message.id && reply.code == "requestBusy")
    await socket.shutdown(); serving.cancel(); await serving.value
  }

  @Test func realPeerCredentialsRefuseForgedRequestWithNoEnvironmentIdentity() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let socket = try await AdminExecSocket(path: fixture.base + "/admin.sock")
    #expect(fcntl(socket.listenerDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    let called = Mutex(false)
    let serving = Task { await socket.run(allowedUIDs: [UInt32(geteuid()) &+ 1]) { _, message in
      called.withLock { $0 = true }
      return .init(id: message.id, code: "accepted", processID: getpid())
    } }
    // The refusal answers the request it read, so the caller's write never races the server closing the connection.
    let message = AdminExecSocket.Message(id: UUID())
    let reply = try await AdminExecSocket.exchange(path: socket.path, message: message)
    #expect(reply.id == message.id && reply.code == "deploymentAdminOnly")
    #expect(!called.withLock { $0 })
    await socket.shutdown(); serving.cancel(); await serving.value
  }
}

@Suite(.enabled(if: !adminExecFixtureRequested), .serialized, .sessionFixtures(timeLimit: .minutes(1))) struct AdminExecReadinessSafetyTests {
  @Test(arguments: ["lease.json", "request.json", "reply.json", "intent.json", "post-commit-intent", "worker-commit", "resume-repair", "listener-reopen", "none"])
  func readinessFailuresRespectRollbackAndForwardRepairBoundary(_ failure: String) async throws {
    try await withSessionDeps {
      let fixture = try PersistenceFixture()
      defer { fixture.clean() }
      let space = try Space.inMemory()
      let id = try await space.identity().rawValue
      let files = try AdminExecFiles(folder: URL(fileURLWithPath: fixture.base), create: true)
      let image = try AdminExecImage(path: #require(try ExecutionPlacement.worker().executable))
      let requests = HostRequests(execPaused: true)
      let resumed = Mutex(false), acceptedBeforeResume = Mutex(false)
      let identity = try TLSIdentity.selfSigned(hosts: ["127.0.0.1"])
      let hooks = ServeNIOHooks(onDidAcceptConnection: { _ in
        if !resumed.withLock({ $0 }) { acceptedBeforeResume.withLock { $0 = true } }
      })
      let bound = try await ServeNIOServer.bindExportable(port: 0, tls: identity, hooks: hooks, initiallyAccepting: false, upgrading: { request in
        try await requests.run({ _ in .response(.text("ready")) }, request: request)
      })
      let frame = AdminExecFrame(version: 1, processID: getpid(), birth: try processBirthIdentity(getpid()), request: UUID(), digest: image.digest, lastGood: image.path, rollback: false, image: image.descriptor, listener: bound.listener.descriptor, listenerDevice: 0, listenerInode: 0, space: id, execution: .init(worker: nil, assignments: []))
      let controller = try AdminExecController.forTesting(files: files, image: image, incoming: frame)
      let worker = LazyExecutionWorker(executable: "unused", sessions: space.sessions, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() })
      await controller.register(worker)
      _ = try await controller.validateSpace(id, configDirectory: URL(fileURLWithPath: fixture.config), sessions: space.sessions)
      await controller.installRequests(pause: { try await requests.pauseExec() }, resume: { await requests.resumeExec(); resumed.withLock { $0 = true } })
      try await controller.installPublic(bound.server, descriptor: bound.listener.descriptor)
      let written = Mutex<[String]>([]), repairAttempts = Mutex(0), reopenAttempts = Mutex(0)
      let policy = AdminExecTesting(allowedUIDs: [UInt32(geteuid())], workerExecutable: nil, beforeWorkerCommit: {
        if failure == "worker-commit" { throw AdminExecError.refused("injectedWorkerCommitFailure") }
      }, afterWorkerResume: {
        guard failure == "resume-repair" else { return }
        let attempt = repairAttempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
          #expect(!resumed.withLock { $0 })
          await #expect(throws: (any Error).self) { try await controller.rollbackPublicDescriptor() }
          #expect((try? files.read("reply.json", as: AdminExecController.Reply.self)) == nil)
          #expect(try files.read("intent.json", as: AdminExecController.Intent.self)?.phase == "repairing-forward")
          throw AdminExecError.refused("injectedResumeReplyFailure")
        }
      }, beforeAcceptingConnections: {
        guard failure == "listener-reopen" else { return }
        let attempt = reopenAttempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
          #expect(resumed.withLock { $0 })
          await #expect(throws: (any Error).self) { try await controller.rollbackPublicDescriptor() }
          #expect(try files.read("reply.json", as: AdminExecController.Reply.self) == nil)
          #expect(try files.read("status.json", as: AdminExecController.Status.self)?.phase == "preparing")
          #expect(try files.read("intent.json", as: AdminExecController.Intent.self)?.phase == "repairing-forward")
          throw AdminExecError.refused("injectedListenerReopenFailure")
        }
      }, beforeCommittedWrite: { if failure == "post-commit-intent" { throw AdminExecError.refused("injectedStorageFailure") } }, beforeReadyWrite: { name in
        written.withLock { $0.append(name) }
        if name == failure {
          if name == "reply.json", written.withLock({ $0.filter { $0 == name }.count }) > 1 { return }
          throw AdminExecError.refused("injectedStorageFailure")
        }
      })
      let outcome: Result<Void, any Error>
      do { try await AdminExecTesting.$current.withValue(policy) { try await controller.ready() }; outcome = .success(()) }
      catch { outcome = .failure(error) }
      if failure == "none" || failure == "post-commit-intent" || failure == "resume-repair" || failure == "reply.json" || failure == "listener-reopen" {
        try outcome.get()
        if failure == "resume-repair" { #expect(repairAttempts.withLock { $0 } == 2) }
        if failure == "listener-reopen" { #expect(reopenAttempts.withLock { $0 } == 2) }
        #expect(try files.read("reply.json", as: AdminExecController.Reply.self)?.code == "ready")
        #expect(try files.read("status.json", as: AdminExecController.Status.self)?.phase == "ready")
        #expect(resumed.withLock { $0 })
        await #expect(throws: (any Error).self) { try await controller.rollbackPublicDescriptor() }
        #expect(written.withLock { $0 } == (
          failure == "reply.json"
            ? ["lease.json", "request.json", "intent.json", "reply.json", "reply.json"]
            : ["lease.json", "request.json", "intent.json", "reply.json"]
        ))
        var configuration = HTTPClient.Configuration()
        configuration.tlsConfiguration = .makeClientConfiguration()
        configuration.tlsConfiguration?.certificateVerification = .none
        let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        let response = try await http.execute(HTTPClientRequest(url: "https://127.0.0.1:\(try #require(bound.server.boundAddress.port))/"), timeout: .seconds(5))
        #expect(response.status.code == 200)
        _ = try await response.body.collect(upTo: 1024)
        try await http.shutdown()
        #expect(!acceptedBeforeResume.withLock { $0 })
      } else {
        #expect(throws: (any Error).self) { try outcome.get() }
        #expect(!resumed.withLock { $0 })
        let retained = try await controller.rollbackPublicDescriptor()
        #expect(fcntl(retained, F_GETFD) & FD_CLOEXEC != 0)
        #expect(written.withLock { $0.last } == (failure == "worker-commit" ? "intent.json" : failure))
      }
      try await controller.shutdown()
      await worker.shutdown(); await bound.server.shutdown()
    }
  }
}
