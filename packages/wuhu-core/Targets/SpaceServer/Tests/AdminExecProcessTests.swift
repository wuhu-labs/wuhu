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
import Dependencies
import FetchAsyncHTTPClient
import ImageRetention
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Subprocess
import Testing
import WorkerOwner
import WorkerProtocol

let adminExecPlatformSupported: Bool = {
  #if os(Linux)
    true
  #else
    false
  #endif
}()

let adminExecFixtureRequested: Bool = {
  let args = Array(CommandLine.arguments.dropFirst())
  let env = ProcessInfo.processInfo.environment
  let requested = args.contains("--wuhu-admin-exec-fixture") || env["WUHU_ADMIN_EXEC_TEST_FIXTURE"] != nil
  if requested {
    guard env["WUHU_ADMIN_EXEC_TEST_FIXTURE"] == "v1", env["TESTBRIDGE_TEST_ONLY"] == "^AdminExecProcessFixture/run",
          args.count == 5, args[0] == "--wuhu-admin-exec-fixture", args[1] == "v1",
          args[2].hasPrefix("/"), args[3].hasPrefix("/"), ["normal", "failure", "identity-failure", "image-pin", "stray-fd"].contains(args[4]) else { _exit(90) }
  }
  return requested
}()

@Suite struct AdminExecProcessFixture {
  @Test func run() async throws {
    guard adminExecFixtureRequested else { return }
    let args = Array(CommandLine.arguments.dropFirst())
    _ = signal(SIGTERM, { _ in _exit(0) })
    if args[4] == "stray-fd" {
      if ProcessInfo.processInfo.environment["WUHU_ADMIN_EXEC_TEST_STRAY_STAGE"] == "v1" {
        guard fcntl(198, F_GETFD) == -1, errno == EBADF else { _exit(94) }
        _exit(0)
      }
      guard ProcessInfo.processInfo.environment["WUHU_ADMIN_EXEC_TEST_STRAY_STAGE"] == nil else { _exit(90) }
      let stray = open(args[2] + "/stray", O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
      guard stray >= 0, dup2(stray, 198) == 198, fcntl(198, F_SETFD, 0) == 0,
            setenv("WUHU_ADMIN_EXEC_TEST_STRAY_STAGE", "v1", 1) == 0 else { _exit(95) }
      let image = try AdminExecImage(path: #require(try ExecutionPlacement.worker().executable))
      try image.execute(metadata: nil)
      _exit(93)
    }
    if args[4] == "image-pin" {
      let path = args[2] + "/pinned-image"
      try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: path)
      guard chmod(path, 0o500) == 0 else { _exit(91) }
      let image = try AdminExecImage(path: path)
      let replacement = args[2] + "/replacement"
      try FileManager.default.copyItem(atPath: "/usr/bin/false", toPath: replacement)
      guard rename(replacement, path) == 0 else { _exit(92) }
      try image.execute(metadata: nil)
      _exit(93)
    }
    let testing = AdminExecTesting(allowedUIDs: [UInt32(geteuid())], workerExecutable: args[3], beforeSuccessorValidation: { rollback in
      if args[4] == "identity-failure", rollback == false { throw AdminExecError.refused("sameImageRequired") }
    })
    try await AdminExecTesting.$current.withValue(testing) {
      try await SpaceServer.serve(folder: URL(fileURLWithPath: args[2]), port: 0, dev: false, publicRead: true, executionPlacement: .worker(executable: URL(fileURLWithPath: args[3])), adminExec: true)
    }
  }
}

@Suite(.enabled(if: !adminExecFixtureRequested), .serialized, .timeLimit(.minutes(2))) struct AdminExecProcessTests {
  @Test(.enabled(if: adminExecPlatformSupported)) func sameImageExecPreservesRealServerWorkerAndChild() async throws { try await rehearse(readinessFailure: false) }
  @Test(.enabled(if: adminExecPlatformSupported)) func readinessFailureRestoresOldImageBeforeBoot() async throws { try await rehearse(readinessFailure: true) }
  @Test(.enabled(if: adminExecPlatformSupported)) func successorIdentityRefusalRestoresPinnedOldImageBeforeBoot() async throws { try await rehearse(readinessFailure: true, identityFailure: true) }

  @Test(.enabled(if: !adminExecPlatformSupported)) func unsupportedPlatformRefusesServeTriggerAndRollbackBeforeCreatingAnyState() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let folder = URL(fileURLWithPath: fixture.base + "/must-not-exist")
    await #expect(throws: AdminExecError.refused("unsupportedPlatform")) {
      try await SpaceServer.serve(folder: folder, port: 0, dev: false, executionPlacement: .worker(), adminExec: true)
    }
    for rollback in [false, true] {
      await #expect(throws: AdminExecError.refused("unsupportedPlatform")) { try await SpaceServer.requestAdminExec(folder: folder, rollback: rollback) }
    }
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let binary = try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])
    for arguments in [["serve", folder.path, "--port", "0", "--execution-placement", "worker", "--admin-exec"], ["admin-exec", folder.path], ["admin-exec", folder.path, "--rollback"]] {
      let result = try await Subprocess.run(.path(.init(binary)), arguments: .init(arguments), environment: .custom(["PATH": "/usr/bin:/bin", "HOME": fixture.base, "WUHU_CONFIG_DIR": fixture.config]), input: .none, output: .discarded, error: .string(limit: 4096))
      #expect(result.terminationStatus == .exited(1))
      #expect(result.standardError?.contains("unsupportedPlatform") == true)
      #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
  }

  @Test func productionBinaryCannotSelectTheInternalFixturePolicy() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.clean() }
    let binary = try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])
    let result = try await Subprocess.run(.path(.init(binary)), arguments: ["--wuhu-admin-exec-fixture", "v1", fixture.base, binary, "normal"], environment: .custom(["PATH": "/usr/bin:/bin", "HOME": fixture.base, "WUHU_CONFIG_DIR": fixture.config, "WUHU_ADMIN_EXEC_TEST_FIXTURE": "v1", "TESTBRIDGE_TEST_ONLY": "^AdminExecProcessFixture/run"]), input: .none, output: .discarded, error: .string(limit: 4096))
    #expect(result.terminationStatus == .exited(64))
    #expect(!FileManager.default.fileExists(atPath: fixture.base + "/.admin-exec"))
  }

  @Test func disabledRealServerRefusesTriggerAndRollback() async throws {
    let fixture = try PersistenceFixture(root: #require(ProcessInfo.processInfo.environment["TEST_TMPDIR"]))
    defer { fixture.clean() }
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
    let folder = URL(fileURLWithPath: fixture.base + "/disabled")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    let id = try await space.identity().rawValue
    let session = try await space.sessions.createSession(group: .shared, title: "disabled exec", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "missing", effort: "none"))
    _ = try await space.sessions.enqueue(session, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: "Start real worker"))))
    let environment: [Environment.Key: String] = ["PATH": "/usr/bin:/bin", "HOME": fixture.base, "WUHU_CONFIG_DIR": fixture.config]
    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(2)), .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
    let result = try await Subprocess.run(.path(.init(binary)), arguments: ["serve", folder.path, "--port", "0", "--execution-placement", "worker"], environment: .custom(environment), platformOptions: options, input: .none, output: .discarded, error: .discarded) { process in
      let birth = try processBirthIdentity(process.processIdentifier.value)
      let root = fixture.config + "/workers/" + id
      try await until("disabled real server started execution worker", timeout: .seconds(30)) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root), let entry = entries.first else { return false }
        return FileManager.default.fileExists(atPath: root + "/" + entry + "/manifest.json")
      }
      for rollback in [false, true] {
        let arguments = ["admin-exec", folder.path] + (rollback ? ["--rollback"] : [])
        let cli = try await Subprocess.run(.path(.init(binary)), arguments: .init(arguments), environment: .custom(environment), input: .none, output: .discarded, error: .string(limit: 4096))
        #expect(cli.terminationStatus == .exited(1), "\(cli.standardError)")
        #expect(try processBirthIdentity(process.processIdentifier.value) == birth)
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/.admin-exec"))
      }
      _ = kill(process.processIdentifier.value, SIGTERM)
    }
    #expect(result.terminationStatus == .exited(0))
  }

  private func rehearse(readinessFailure: Bool, identityFailure: Bool = false) async throws {
    let fixture = try PersistenceFixture(root: #require(ProcessInfo.processInfo.environment["TEST_TMPDIR"]))
    defer { fixture.clean() }
    let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
    let folder = URL(fileURLWithPath: fixture.base + "/space")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    let id = try await space.identity().rawValue
    let session = try await space.sessions.createSession(group: .shared, title: "exec rehearsal", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "missing", effort: "none"))
    _ = try await space.fs(.shared).write("/start-worker.js", Data("export default async () => ({ready:true})".utf8), ifMatch: nil)
    let fire = Date().addingTimeInterval(-1)
    _ = try await space.sessions.armSubscription(session, slot: .init(id: .init("start-worker"), kind: .timer(.oneShot(fire), message: ""), handler: "/start-worker.js"), nextFireAt: fire)
    var environment: [Environment.Key: String] = ["PATH": "/usr/bin:/bin", "HOME": fixture.base, "WUHU_CONFIG_DIR": fixture.config]
    for key in ["SDKROOT", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[Environment.Key(stringLiteral: key)] = value }
    }
    if readinessFailure { environment["WUHU_ADMIN_EXEC_TEST_READY_FAILURE"] = "1" }
    environment["WUHU_ADMIN_EXEC_TEST_FIXTURE"] = "v1"
    environment["TESTBRIDGE_TEST_ONLY"] = "^AdminExecProcessFixture/run"
    let fixtureBinary = try #require(try ExecutionPlacement.worker().executable)
    let helperFile = fixture.base + "/helper.pid"
    let log = fixture.base + "/server.log"
    let script = "umask 077; /bin/sleep 120 & c=$!; printf '%s' \"$c\" > '\(helperFile)'; exec '\(fixtureBinary)' --wuhu-admin-exec-fixture v1 '\(folder.path)' '\(binary)' \(identityFailure ? "identity-failure" : readinessFailure ? "failure" : "normal") 2> '\(log)'"
    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(2)), .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
    let result = try await Subprocess.run(.path("/bin/sh"), arguments: ["-c", script], environment: .custom(environment), platformOptions: options, input: .none, output: .discarded, error: .discarded) { process in
      do {
        let files = try await waitForFiles(folder: folder)
        let initial = try #require(try files.read("status.json", as: AdminExecController.Status.self))
        #expect(initial.processID == process.processIdentifier.value)
        #expect(initial.executable == URL(fileURLWithPath: fixtureBinary).resolvingSymlinksInPath().path)
        let helper = try #require(Int32(try String(contentsOfFile: helperFile, encoding: .utf8)))
        let helperBirth = try processBirthIdentity(helper)
        defer { if (try? processBirthIdentity(helper)) == helperBirth { _ = kill(helper, SIGTERM) } }
        let root = fixture.config + "/workers/" + id
        try await until("real standalone worker manifest", timeout: .seconds(30)) {
          guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root), let entry = entries.first else { return false }
          return FileManager.default.fileExists(atPath: root + "/" + entry + "/manifest.json")
        }
        let entry = try #require(try FileManager.default.contentsOfDirectory(atPath: root).first)
        let store = try await ExecutionWorkerManifestStore.open(directory: root + "/" + entry, space: id)
        let manifest = try #require(try await store.load())
        let image = try #require(manifest.image)
        let imageRoot = fixture.config + "/execution-images"
        try ImageRetention.transaction(root: imageRoot) { try $0.verify(image) }
        let parentPath = try #require(manifest.sockets?.parent)
        var beforePath = stat()
        #expect(lstat(parentPath, &beforePath) == 0)
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        let worker = try WorkerClient(socket: manifest.workerSocket(directory: root + "/" + entry), token: manifest.credentials.current, control: .asyncHTTPClient(client, timeout: .seconds(3)), bytes: .asyncHTTPClient(client, timeout: .seconds(3)))
        let outcome: Result<Void, any Error>
        do {
          try await until("real worker settles before controlled exec", timeout: .seconds(30)) {
            do {
              _ = try await worker.negotiate(ExecutionWorkerBootstrap.hello(release: "exec-rehearsal"))
              try await WorkerConnection.requireExecIdle(worker)
              return try await space.sessions.armedSubscriptions(session).isEmpty
            } catch { return false }
          }
          try await ContinuousClock().sleep(for: .milliseconds(200))
          let cli = try await Subprocess.run(.path(.init(binary)), arguments: ["admin-exec", folder.path], environment: .custom(environment), input: .none, output: .string(limit: 65536), error: .string(limit: 65536))
          #expect(cli.terminationStatus == .exited(readinessFailure ? 1 : 0), "\(cli.standardError)")
          let before = try #require(try files.read("previous.json", as: AdminExecController.Status.self))
          let after = try #require(try files.read("status.json", as: AdminExecController.Status.self))
          #expect(before.processID == initial.processID && after.processID == initial.processID)
          #expect(before.birth == initial.birth && after.birth == initial.birth)
          #expect(after.listenerDevice == before.listenerDevice && after.listenerInode == before.listenerInode)
          #expect(after.port == before.port && after.port == initial.port)
          #expect(after.workerProcessID == manifest.processID && after.workerBirth == manifest.birth)
          try ImageRetention.transaction(root: imageRoot) { try $0.verify(image) }
          #expect(after.workerListenerDevice == before.workerListenerDevice && after.workerListenerInode == before.workerListenerInode)
          var afterPath = stat()
          #expect(lstat(parentPath, &afterPath) == 0)
          #expect(afterPath.st_dev == beforePath.st_dev && afterPath.st_ino == beforePath.st_ino)
          #expect(try processBirthIdentity(manifest.processID) == manifest.birth)
          #expect(try processBirthIdentity(helper) == helperBirth)
          #expect(after.phase == (readinessFailure ? "rolled-back" : "ready"))
          #expect(after.executable == files.path + "/last-good-" + (try adminExecDigest(fixtureBinary)))
          _ = try await worker.negotiate(ExecutionWorkerBootstrap.hello(release: "after-exec"))
          try await WorkerConnection.requireExecIdle(worker)
          try await provePublicTLS(port: after.port)
          if !readinessFailure {
            let retry = try await Subprocess.run(.path(.init(binary)), arguments: ["admin-exec", folder.path, "--rollback"], environment: .custom(environment), input: .none, output: .string(limit: 65536), error: .string(limit: 65536))
            #expect(retry.terminationStatus == .exited(0), "\(retry.standardError)")
            let retried = try #require(try files.read("status.json", as: AdminExecController.Status.self))
            #expect(retried.processID == initial.processID && retried.birth == initial.birth)
            #expect(retried.phase == "rolled-back")
            #expect(retried.listenerInode == before.listenerInode && retried.port == before.port)
            #expect(retried.workerProcessID == manifest.processID && retried.workerBirth == manifest.birth)
            try ImageRetention.transaction(root: imageRoot) { try $0.verify(image) }
            #expect(try processBirthIdentity(helper) == helperBirth)
            _ = try await worker.negotiate(ExecutionWorkerBootstrap.hello(release: "after-explicit-rollback"))
            try await WorkerConnection.requireExecIdle(worker)
            try await provePublicTLS(port: retried.port)
          }
          outcome = .success(())
        } catch {
          outcome = .failure(error)
        }
        await worker.close()
        try await client.shutdown()
        _ = kill(process.processIdentifier.value, SIGTERM)
        try outcome.get()
      } catch {
        if let text = try? String(contentsOfFile: log, encoding: .utf8) { Issue.record("Standalone rehearsal log: \(text)") }
        throw error
      }
    }
    #expect(result.terminationStatus == .exited(0))
  }

  private func waitForFiles(folder: URL) async throws -> AdminExecFiles {
    try await until("standalone admin readiness", timeout: .seconds(30)) {
      guard let files = try? AdminExecFiles(folder: folder, create: false) else { return false }
      return (try? files.read("lease.json", as: AdminExecController.Lease.self)) != nil
    }
    return try AdminExecFiles(folder: folder, create: false)
  }

  private func provePublicTLS(port: Int) async throws {
    var configuration = HTTPClient.Configuration()
    configuration.tlsConfiguration = .makeClientConfiguration()
    configuration.tlsConfiguration?.certificateVerification = .none
    let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    let outcome: Result<Void, any Error>
    do {
      let response = try await client.execute(HTTPClientRequest(url: "https://127.0.0.1:\(port)/v1/server"), timeout: .seconds(5))
      #expect(response.status.code == 200)
      _ = try await response.body.collect(upTo: 65536)
      outcome = .success(())
    } catch { outcome = .failure(error) }
    try await client.shutdown()
    try outcome.get()
  }
}
