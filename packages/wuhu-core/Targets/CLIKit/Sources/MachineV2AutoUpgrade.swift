#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
  import Security
#endif
import Dependencies
import Fetch
import struct MachineContract.MachineV2Artifact
import struct MachineContract.MachineV2Upgrade
import enum MachineContract.MachineV2UpgradeStatus
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.MachineUpgradeReport
import typealias Serve.Handler

/// `<machine>/upgrade.json`, shared by the agent, its detached apply helper and the agent the helper starts.
struct MachineV2UpgradeState: Codable, Equatable, Sendable {
  struct Trial: Codable, Equatable, Sendable {
    var version: String
    var from: String
    var startedAt: Double
    var healthyAt: Double?
    var owner: String?
  }

  /// Pending while an agent of the interrupted `version` still runs; retried on every check.
  struct Rollback: Codable, Equatable, Sendable {
    var version: String
    var to: String
  }

  var trial: Trial?
  var rollback: Rollback?
  var failed: MachineUpgradeReport.Failure?
}

enum MachineV2UpgradeDecision: Equatable, Sendable {
  case current
  case hold(MachineV2UpgradeStatus)
  case notRetrying(String)
  case noArtifact(String)
  case install(version: String, artifact: MachineV2Artifact)
}

/// A refusal of the target itself: recorded as a failure so the same version is not fetched again.
struct MachineV2UpgradeRefusal: Error, Equatable {
  var reason: String
}

extension MachineV2Home {
  var upgradeStateFile: URL { directory.appendingPathComponent("upgrade.json") }
  var upgradeLog: URL { directory.appendingPathComponent("upgrade.log") }
  var upgradeStaging: URL { directory.appendingPathComponent("upgrade", isDirectory: true) }

  func loadUpgradeState() -> MachineV2UpgradeState {
    var state = stat()
    guard lstat(upgradeStateFile.path, &state) == 0, state.st_mode & S_IFMT == S_IFREG, state.st_uid == getuid(), state.st_size <= 8192,
          let data = try? Data(contentsOf: upgradeStateFile), let decoded = try? JSONDecoder().decode(MachineV2UpgradeState.self, from: data) else { return .init() }
    return decoded
  }

  func saveUpgradeState(_ upgrade: MachineV2UpgradeState) throws {
    let pending = directory.appendingPathComponent(".upgrade-\(UUID().uuidString).json")
    try JSONEncoder().encode(upgrade).write(to: pending, options: .withoutOverwriting)
    guard chmod(pending.path, 0o600) == 0, rename(pending.path, upgradeStateFile.path) == 0 else {
      _ = unlink(pending.path)
      throw MachineV2RuntimeError(.invalidConfiguration, message: "Cannot write \(upgradeStateFile.path)")
    }
  }

  func logUpgrade(_ message: String) {
    let line = Array("\(Date().ISO8601Format()) [\(getpid())] upgrade: \(message)\n".utf8)
    let descriptor = open(upgradeLog.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    for target in [STDERR_FILENO, descriptor] where target >= 0 {
      _ = line.withUnsafeBytes { write(target, $0.baseAddress, $0.count) }
    }
    if descriptor >= 0 { close(descriptor) }
  }
}

enum MachineV2AutoUpgrade {
  static let checkInterval: Duration = .seconds(600)
  static let healthSeconds = 90
  static let wakeSlack: Duration = .milliseconds(250)
  static let staleTrialSeconds: Double = 600

  static func decide(running: String, announcement: MachineV2Upgrade, platform: String?, failed: MachineUpgradeReport.Failure?) -> MachineV2UpgradeDecision {
    if announcement.version == running { return .current }
    guard announcement.status == .ready, let target = announcement.version else { return .hold(announcement.status) }
    if failed?.version == target { return .notRetrying(target) }
    guard let platform, let artifact = announcement.artifacts.first(where: { $0.platform == platform }) else { return .noArtifact(target) }
    return .install(version: target, artifact: artifact)
  }

  /// A failure stands only while it names the current target and this agent does not run it.
  static func settled(_ failed: MachineUpgradeReport.Failure?, running: String, target: String?) -> MachineUpgradeReport.Failure? {
    guard let failed, failed.version == target, failed.version != running else { return nil }
    return failed
  }

  static func failure(_ version: String, _ reason: String, at date: Date) -> MachineUpgradeReport.Failure {
    .init(version: version, reason: reason, at: date.ISO8601Format())
  }

  /// Adds the persisted failure to this machine's describe reply.
  static func reporting(_ handler: @escaping Handler, home: MachineV2Home) -> Handler {
    { request in
      let response = try await handler(request)
      guard request.method == .get, request.url.path == "/machine/v2/machines/" + home.machine, response.status.code == 200,
            let failed = home.loadUpgradeState().failed else { return response }
      let described = try await response.body.json(MachineDescription.self, upTo: 1 << 20)
      let reported = MachineDescription(instance: described.instance, acceptingStarts: described.acceptingStarts, limits: described.limits, kinds: described.kinds, availability: described.availability, upgrade: .init(failed: failed))
      return Response(status: response.status, headers: response.headers, body: .bytes(try JSONEncoder().encode(reported), contentType: "application/json"))
    }
  }

  #if os(macOS)
    /// Strictly valid signature; when the running agent carries a team identifier the candidate must carry the same one.
    static func verifySignature(_ candidate: URL, running: URL) throws {
      let expected = try? signingTeam(running)
      let actual = try signingTeam(candidate)
      if let expected = expected ?? nil, actual != expected { throw MachineV2UpgradeRefusal(reason: "badSignature") }
    }

    private static func signingTeam(_ path: URL) throws -> String? {
      var code: SecStaticCode?
      guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess
      else { throw MachineV2UpgradeRefusal(reason: "badSignature") }
      var information: CFDictionary?
      guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { throw MachineV2UpgradeRefusal(reason: "badSignature") }
      return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
  #else
    static func verifySignature(_: URL, running _: URL) throws {}
  #endif

  /// The detached helper: swap, wait for the new agent's first connection, roll back and record the failure otherwise.
  static func apply(home: MachineV2Home, candidate: URL, target: String, running: String, token: String, installer: MachineV2Installer, now: @Sendable () -> Date = { Date() }) async {
    @Dependency(\.continuousClock) var clock
    guard let trial = home.loadUpgradeState().trial, trial.owner == token, trial.version == target else {
      return home.logUpgrade("the trial of \(target) is not this helper's; leaving it")
    }
    defer { removeStaging(of: candidate, home: home) }
    func finish(_ outcome: (inout MachineV2UpgradeState) -> Void) {
      var state = home.loadUpgradeState()
      if state.trial?.owner == token { state.trial = nil }
      outcome(&state)
      do { try home.saveUpgradeState(state) } catch { home.logUpgrade("cannot record the outcome of \(target): \(error)") }
    }
    do { try await installer.install(candidate: candidate) }
    catch let error as MachineV2InstallError where error.code == .busy {
      home.logUpgrade("installation busy; \(target) waits for the next check")
      finish { _ in }
      return
    } catch {
      home.logUpgrade("install of \(target) failed: \(error)")
      finish { $0.failed = failure(target, "installFailed", at: now()) }
      if FileManager.default.contentsEqual(atPath: installer.binary.path, andPath: candidate.path) {
        do { try await installer.rollback() } catch { home.logUpgrade("rollback to \(running) failed: \(error)") }
      }
      return
    }
    home.logUpgrade("installed \(target); waiting for its first connection")
    guard await connected(on: clock, marked: { home.loadUpgradeState().trial.map { $0.owner == token && $0.healthyAt != nil } == true }) else {
      home.logUpgrade("\(target) did not connect within \(healthSeconds) s; rolling back to \(running)")
      finish { $0.failed = failure(target, "healthCheckFailed", at: now()) }
      do { try await installer.rollback() } catch { home.logUpgrade("rollback to \(running) failed: \(error)") }
      return
    }
    finish { $0.failed = nil }
    home.logUpgrade("upgraded \(running) -> \(target)")
  }

  /// A mark counts only when read by one monotonic deadline, allowing `wakeSlack` for the read that sleeps until it. The mark's wall time is never compared.
  static func connected(on clock: some Clock<Duration>, marked: () -> Bool) async -> Bool {
    let deadline = clock.now.advanced(by: .seconds(healthSeconds))
    while true {
      let seen = marked()
      let at = clock.now
      guard at <= deadline.advanced(by: wakeSlack) else { return false }
      if seen { return true }
      guard at < deadline, (try? await clock.sleep(until: min(at.advanced(by: .seconds(1)), deadline), tolerance: nil)) != nil else { return false }
    }
  }

  static func removeStaging(of candidate: URL, home: MachineV2Home) {
    let staging = candidate.deletingLastPathComponent().deletingLastPathComponent()
    guard staging.deletingLastPathComponent().standardizedFileURL == home.upgradeStaging.standardizedFileURL else { return }
    try? FileManager.default.removeItem(at: staging)
  }
}

/// The running agent's half: checks the announcement, prepares a verified candidate and hands it to the detached helper.
actor MachineV2AutoUpgrader {
  struct Environment: Sendable {
    var announce: @Sendable () async throws -> MachineV2Upgrade
    var download: @Sendable (URL) async throws -> Data
    var extract: @Sendable (_ archive: URL, _ into: URL) async throws -> Void
    var command: @Sendable ([String]) async throws -> String
    var verifySignature: @Sendable (_ candidate: URL, _ running: URL) async throws -> Void
    var launch: @Sendable ([String]) throws -> Int32
    var reaped: @Sendable (Int32) -> Bool
    var now: @Sendable () -> Date = { Date() }
  }

  let home: MachineV2Home
  let version: String
  let platform: String?
  let environment: Environment
  private var helper: Int32?
  private var lastNote: String?

  init(home: MachineV2Home, version: String, platform: String?, environment: Environment) {
    self.home = home; self.version = version; self.platform = platform; self.environment = environment
  }

  /// The agent after a swap proves itself by connecting; the helper waits for this mark.
  func connected() {
    var state = home.loadUpgradeState()
    guard var trial = state.trial, trial.version == version, trial.healthyAt == nil else { return }
    trial.healthyAt = environment.now().timeIntervalSince1970
    state.trial = trial
    do { try home.saveUpgradeState(state) } catch { note("cannot mark \(version) healthy: \(error)") }
  }

  func check() async {
    if let pid = helper {
      guard environment.reaped(pid) else { return }
      helper = nil
    }
    var state = home.loadUpgradeState()
    if let trial = state.trial {
      guard environment.now().timeIntervalSince1970 - trial.startedAt >= MachineV2AutoUpgrade.staleTrialSeconds else { return note("upgrade to \(trial.version) in progress") }
      state.trial = nil
      if trial.healthyAt == nil {
        state.failed = MachineV2AutoUpgrade.failure(trial.version, "interrupted", at: environment.now())
        if trial.version == version { state.rollback = .init(version: trial.version, to: trial.from) }
      }
      save(state)
    }
    if let rollback = state.rollback {
      guard rollback.version != version else {
        do {
          helper = try environment.launch([home.binary.path, "machine-v2", "rollback", home.machine])
          return note("upgrade to \(version) interrupted; rolling back to \(rollback.to)")
        } catch { return note("cannot start the rollback of interrupted \(version): \(error)") }
      }
      state.rollback = nil
      save(state)
    }
    try? FileManager.default.removeItem(at: home.upgradeStaging)
    let announcement: MachineV2Upgrade
    do { announcement = try await environment.announce() } catch { return note("upgrade check failed: \(error)") }
    let settled = MachineV2AutoUpgrade.settled(state.failed, running: version, target: announcement.version)
    if settled != state.failed { state.failed = settled; save(state) }
    switch MachineV2AutoUpgrade.decide(running: version, announcement: announcement, platform: platform, failed: state.failed) {
    case .current: lastNote = nil
    case let .hold(status): note("holding at \(version): target \(announcement.version ?? "none") is \(status.rawValue)")
    case let .notRetrying(target): note("not retrying \(target) after \(state.failed?.reason ?? "failure")")
    case let .noArtifact(target): note("no \(platform ?? "unsupported-platform") artifact for \(target)")
    case let .install(target, artifact):
      let candidate: URL
      do { candidate = try await prepare(target: target, artifact: artifact) }
      catch let refusal as MachineV2UpgradeRefusal {
        try? FileManager.default.removeItem(at: home.upgradeStaging)
        state.failed = MachineV2AutoUpgrade.failure(target, refusal.reason, at: environment.now())
        save(state)
        return note("refused \(target): \(refusal.reason)")
      } catch {
        try? FileManager.default.removeItem(at: home.upgradeStaging)
        return note("download of \(target) failed: \(error)")
      }
      let token = UUID().uuidString
      state.trial = .init(version: target, from: version, startedAt: environment.now().timeIntervalSince1970, owner: token)
      do { try home.saveUpgradeState(state) } catch {
        try? FileManager.default.removeItem(at: home.upgradeStaging)
        return note("cannot reserve the upgrade to \(target): \(error)")
      }
      do {
        helper = try environment.launch([home.binary.path, "machine-v2", "apply-upgrade", home.machine, candidate.path, target, token])
        note("upgrading \(version) -> \(target)")
      } catch {
        var current = home.loadUpgradeState()
        if current.trial?.owner == token { current.trial = nil; save(current) }
        try? FileManager.default.removeItem(at: home.upgradeStaging)
        note("cannot start the upgrade helper: \(error)")
      }
    }
  }

  func prepare(target: String, artifact: MachineV2Artifact) async throws -> URL {
    let expected = artifact.sha256.lowercased()
    guard let url = URL(string: artifact.url), url.scheme == "https", url.host != nil,
          expected.utf8.count == 64, expected.allSatisfy(\.isHexDigit) else { throw MachineV2UpgradeRefusal(reason: "badArtifact") }
    let archive = try await environment.download(url)
    guard SHA256.hex(archive) == expected else { throw MachineV2UpgradeRefusal(reason: "sha256Mismatch") }
    let staging = home.upgradeStaging.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let payload = staging.appendingPathComponent("payload", isDirectory: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let archiveFile = staging.appendingPathComponent("artifact")
    try archive.write(to: archiveFile, options: .withoutOverwriting)
    do { try await environment.extract(archiveFile, payload) } catch { throw MachineV2UpgradeRefusal(reason: "badArchive") }
    let candidate = payload.appendingPathComponent("wuhu")
    var state = stat()
    guard (try? FileManager.default.contentsOfDirectory(atPath: payload.path)) == ["wuhu"], lstat(candidate.path, &state) == 0, state.st_mode & S_IFMT == S_IFREG,
          FileManager.default.isExecutableFile(atPath: candidate.path) else { throw MachineV2UpgradeRefusal(reason: "badArchive") }
    do { try await environment.verifySignature(candidate, home.binary) } catch { throw MachineV2UpgradeRefusal(reason: "badSignature") }
    let stamp: String
    do { stamp = try await environment.command([candidate.path, "--version"]) } catch { throw MachineV2UpgradeRefusal(reason: "notRunnable") }
    guard stamp.hasPrefix("wuhu \(target) (") else { throw MachineV2UpgradeRefusal(reason: "versionMismatch") }
    return candidate
  }

  private func save(_ state: MachineV2UpgradeState) {
    do { try home.saveUpgradeState(state) } catch { note("\(error)") }
  }

  private func note(_ message: String) {
    guard message != lastNote else { return }
    lastNote = message
    home.logUpgrade(message)
  }
}
