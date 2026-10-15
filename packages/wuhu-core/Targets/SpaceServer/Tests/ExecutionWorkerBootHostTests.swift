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
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing

private struct BootHostFixture {
  let base: URL
  var folder: URL { base.appendingPathComponent("space") }
  var config: URL { base.appendingPathComponent("config") }
  let space: Space
  let id: String
  let generation = UUID()
  var root: URL { config.appendingPathComponent("workers").appendingPathComponent(id) }
  var directory: URL { root.appendingPathComponent(generation.uuidString) }

  init() async throws {
    let resolved = try #require(realpath("/tmp", nil))
    defer { free(resolved) }
    base = URL(fileURLWithPath: String(cString: resolved) + "/bh-" + String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: base.appendingPathComponent("space"), withIntermediateDirectories: true)
    space = try Space.open(file: base.appendingPathComponent("space/space.sqlite"))
    id = try await space.identity().rawValue
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func clean() { try? FileManager.default.removeItem(at: base) }

  func put(_ name: String, _ text: String, mode: mode_t = 0o600) throws {
    let file = open(directory.appendingPathComponent(name).path, O_WRONLY | O_CREAT | O_EXCL, mode)
    #expect(file >= 0)
    defer { _ = close(file) }
    let data = Data(text.utf8)
    #expect(data.withUnsafeBytes { write(file, $0.baseAddress, $0.count) } == data.count)
  }

  func openHost(worker: Bool) async throws -> SpaceHost {
    try await SpaceHost.open(folder: folder, deployment: DeploymentRecord(origin: "https://boot-fence.test", tlsFingerprint: "test", certificate: .provided), configDirectory: config, allowEnvironmentCredentials: false, executionPlacement: worker ? .worker(executable: URL(fileURLWithPath: "/not-a-worker")) : .inProcess, webApp: nil)
  }

  func openHost(worker: Bool, reconcileWorkers: @escaping @Sendable () async -> ExecutionWorkerBootFence.Result) async throws -> SpaceHost {
    try await SpaceHost.open(folder: folder, deployment: DeploymentRecord(origin: "https://boot-fence.test", tlsFingerprint: "test", certificate: .provided), configDirectory: config, allowEnvironmentCredentials: false, executionPlacement: worker ? .worker(executable: URL(fileURLWithPath: "/not-a-worker")) : .inProcess, webApp: nil, reconcileWorkers: reconcileWorkers)
  }
}

@Suite(.timeLimit(.minutes(1))) struct ExecutionWorkerBootHostTests {
  @Test(arguments: [false, true])
  func markedWorkerBlocksOnlyItsSessionsAndRetainsTheirScriptOwners(worker: Bool) async throws {
    try await withSessionDeps {
      let fixture = try await BootHostFixture()
      defer { fixture.clean() }
      let store = fixture.space.sessions
      let blocked = try await store.createSession(group: .shared, title: "unfenced", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let safe = try await store.createSession(group: .shared, title: "safe script owner", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      _ = try await store.archive(safe, grace: .seconds(3600))
      let incarnation = UUID()
      try await store.beginWorkerOwnership(incarnation: incarnation)
      try await store.assignWorker(blocked, incarnation: incarnation)
      try await store.registerWorkerScript("detached", session: blocked, incarnation: incarnation)
      try await store.setWorkerActivity(blocked, incarnation: incarnation, active: true)
      let machine = try await fixture.space.addMachine(name: "fixture").id
      _ = try await fixture.space.mintScriptExec(machine: machine, session: safe.rawValue, script: "safe-script")
      let manifest = ExecutionWorkerManifest(version: 1, space: fixture.id, generation: fixture.generation, incarnation: incarnation, processID: getpid(), birth: try processBirthIdentity(getpid()), credentials: .init(current: String(repeating: "a", count: 72)))
      try fixture.put("manifest.json", String(decoding: JSONEncoder().encode(manifest), as: UTF8.self))
      let host = try await fixture.openHost(worker: worker, reconcileWorkers: {
        .init(unresolved: [incarnation], unresolvedWorkers: [.init(manifest: manifest, directory: fixture.directory.path, reason: .unconfirmed)], credentials: .init())
      })
      let running = Task { await host.run() }
      do {
        try await until("safe startup script is announced") { try await store.undrainedInputs(safe).count == 1 }
        #expect(try await store.undrainedInputs(blocked).isEmpty)
        #expect(try await store.record(blocked).work != .errored)
        #expect(try await store.recordWorkerLoss(excluding: [incarnation]).isEmpty)
        #expect(try await store.sessionsOwnedByWorkers([incarnation]) == [blocked])
        #expect(try await fixture.space.takeScriptExecOwners(excluding: [blocked]).isEmpty)
        try await host.shutdown()
        await running.value
      } catch {
        try? await host.shutdown()
        await running.value
        throw error
      }
      _ = try await store.archive(blocked, grace: .seconds(3600))
      try FileManager.default.removeItem(at: fixture.directory)
      let resolved = try await fixture.openHost(worker: worker)
      let restarted = Task { await resolved.run() }
      do {
        try await until("resolved host consumes the detached script owner") { try await store.undrainedInputs(blocked).count == 1 }
        try await resolved.shutdown()
        await restarted.value
      } catch {
        try? await resolved.shutdown()
        await restarted.value
        throw error
      }
      #expect(try await fixture.space.takeScriptExecOwners().isEmpty)
    }
  }

  @Test(arguments: [false, true], ["future", "corrupt", "foreign", "unsafe-root", "unsafe-entry", "missing-with-runtime"])
  func spaceHostRefusesUninspectableWorkerEvidenceBeforeOwnerAssembly(worker: Bool, evidence: String) async throws {
    try await withSessionDeps {
      let fixture = try await BootHostFixture()
      defer { fixture.clean() }
      switch evidence {
      case "future": try fixture.put("manifest.json", "{\"version\":999}")
      case "corrupt": try fixture.put("manifest.json", "manifest-credential-must-not-leak")
      case "foreign":
        let manifest = ExecutionWorkerManifest(version: 1, space: "foreign-space", generation: fixture.generation, incarnation: UUID(), processID: 123, birth: "fixture-process-birth", credentials: .init(current: String(repeating: "a", count: 72)))
        try fixture.put("manifest.json", String(decoding: JSONEncoder().encode(manifest), as: UTF8.self))
      case "unsafe-root": #expect(chmod(fixture.root.path, 0o755) == 0)
      case "unsafe-entry": #expect(chmod(fixture.directory.path, 0o755) == 0)
      default: try fixture.put("worker.sock", "runtime-evidence")
      }
      do {
        let host = try await fixture.openHost(worker: worker)
        try await host.shutdown()
        Issue.record("SpaceHost.open bypassed the worker fence")
      } catch let error as ExecutionWorkerBootRefusal {
        let path = evidence == "unsafe-root" ? fixture.root.path : fixture.directory.path
        #expect(error.description.contains("verify no worker, then remove " + path))
        #expect(error.description.contains("runtime=" + path))
        #expect(!error.description.contains("SQL(elements:"))
        #expect(!error.description.contains("manifest-credential-must-not-leak"))
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("identity").path))
      #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("web-push").path))
    }
  }

  @Test(arguments: [false, true])
  func refusedHostPreservesScriptOwnersAndAResolvedHostConsumesThemExactlyOnce(worker: Bool) async throws {
    try await withSessionDeps {
      let fixture = try await BootHostFixture()
      defer { fixture.clean() }
      let session = try await fixture.space.sessions.createSession(group: .shared, title: "surviving script", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
      let machine = try await fixture.space.addMachine(name: "fixture").id
      _ = try await fixture.space.mintScriptExec(machine: machine, session: session.rawValue, script: "retained-script")
      _ = try await fixture.space.sessions.archive(session, grace: .seconds(3600))
      try fixture.put("manifest.json", "{\"version\":999}")
      await #expect(throws: ExecutionWorkerBootRefusal.self) { try await fixture.openHost(worker: worker) }
      #expect(try await fixture.space.sessions.undrainedInputs(session).isEmpty)
      try FileManager.default.removeItem(at: fixture.directory)
      for index in 0 ..< 2 {
        if index == 1 { _ = try await fixture.space.mintScriptExec(machine: machine, session: session.rawValue, script: "second-startup-marker") }
        let host = try await fixture.openHost(worker: worker)
        let running = Task { await host.run() }
        do {
          try await until("resolved host announces the retained script") { try await fixture.space.sessions.undrainedInputs(session).count == index + 1 }
          try await host.shutdown()
          await running.value
        } catch {
          try? await host.shutdown()
          await running.value
          throw error
        }
        let inputs = try await fixture.space.sessions.undrainedInputs(session)
        #expect(inputs.count == index + 1)
        let retained = inputs.filter { if case let .notification(notice) = $0.input { notice.content.text.contains("script retained-script ") } else { false } }
        #expect(retained.count == 1)
        #expect(try await fixture.space.takeScriptExecOwners().isEmpty)
      }
    }
  }
}
