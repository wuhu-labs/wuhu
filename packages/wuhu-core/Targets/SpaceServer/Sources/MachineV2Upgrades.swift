#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import JSONValue
import Logging
import MachineContract
import OrderedCollections
import SpaceCore
import Synchronization

/// The admin's hold on machine agent upgrades: `/machine-v2-upgrade.json` in
/// the space-wide layer. A per-machine field overrides the global one.
struct MachineV2UpgradeSetting: Equatable, Sendable {
  struct Rule: Equatable, Sendable {
    var pause: Bool?
    var pin: String?
  }

  var global = Rule()
  var machines: [String: Rule] = [:]

  static let path = "/machine-v2-upgrade.json"

  /// Strict: an unknown key, a wrong type or a malformed version makes the
  /// whole file unparseable, so a typo never half-applies.
  static func parse(_ data: Data) -> MachineV2UpgradeSetting? {
    guard case let .object(root)? = JSONValue.parse(utf8: data) else { return nil }
    guard let global = rule(root, allowing: ["pause", "pin", "machines"]) else { return nil }
    var setting = MachineV2UpgradeSetting(global: global)
    switch root["machines"] {
    case nil, .null?: break
    case let .object(machines)?:
      for (id, value) in machines {
        guard MachineID.isValid(id), case let .object(fields) = value, let rule = rule(fields, allowing: ["pause", "pin"]) else { return nil }
        setting.machines[id] = rule
      }
    default: return nil
    }
    return setting
  }

  private static func rule(_ fields: OrderedDictionary<String, JSONValue>, allowing keys: Set<String>) -> Rule? {
    guard fields.keys.allSatisfy(keys.contains) else { return nil }
    var rule = Rule()
    switch fields["pause"] {
    case nil, .null?: break
    case let .bool(value)?: rule.pause = value
    default: return nil
    }
    switch fields["pin"] {
    case nil, .null?: break
    case let .string(value)? where MachineV2ReleaseVersion.isValid(value): rule.pin = value
    default: return nil
    }
    return rule
  }

  func effective(for machine: String) -> Rule {
    let own = machines[machine]
    return Rule(pause: own?.pause ?? global.pause, pin: own?.pin ?? global.pin)
  }
}

enum MachineV2ReleaseVersion {
  /// `N.N.N`, optionally `-dev.N` or `-beta.N`: the shapes the release pipeline publishes.
  static func isValid(_ version: String) -> Bool {
    let parts = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard core.count == 3, core.allSatisfy(isNumber) else { return false }
    guard parts.count == 2 else { return true }
    let suffix = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    return suffix.count == 2 && (suffix[0] == "dev" || suffix[0] == "beta") && isNumber(suffix[1])
  }

  private static func isNumber(_ part: Substring) -> Bool {
    !part.isEmpty && part.utf8.count <= 9 && part.utf8.allSatisfy { (0x30 ... 0x39).contains($0) }
  }
}

/// Resolves a release version to its published archives by reading each
/// platform's immutable `.sha256` sidecar. A complete answer is cached for the
/// life of the process; anything short of it is retried after `retryAfter`.
actor MachineV2Releases {
  enum Resolution: Equatable, Sendable {
    case published([MachineV2Artifact])
    case unpublished
    case unreachable
  }

  struct Platform: Sendable {
    let key: String
    let archiveExtension: String
  }

  static let platforms = [
    Platform(key: "macos-arm64", archiveExtension: "zip"),
    Platform(key: "linux-amd64", archiveExtension: "tar.gz"),
  ]

  private let base: URL
  private let fetch: FetchClient
  private let clock: any Clock<Duration>
  private let timeout: Duration
  private let retryAfter: Duration
  private var settled: [String: [MachineV2Artifact]] = [:]
  private var recent: [String: (resolution: Resolution, at: ContinuousClock.Instant)] = [:]
  private var inFlight: [String: Task<Resolution, Never>] = [:]

  init(base: URL, fetch: FetchClient, clock: any Clock<Duration>, timeout: Duration = .seconds(5), retryAfter: Duration = .seconds(60)) {
    self.base = base
    self.fetch = fetch
    self.clock = clock
    self.timeout = timeout
    self.retryAfter = retryAfter
  }

  func resolve(_ version: String) async -> Resolution {
    if let artifacts = settled[version] { return .published(artifacts) }
    if let recent = recent[version], ContinuousClock.now - recent.at < retryAfter { return recent.resolution }
    if let task = inFlight[version] { return await task.value }
    let task = Task { [base, fetch, clock, timeout] in
      await Self.lookup(version, base: base, fetch: fetch, clock: clock, timeout: timeout)
    }
    inFlight[version] = task
    let resolution = await task.value
    inFlight[version] = nil
    if case let .published(artifacts) = resolution, artifacts.count == Self.platforms.count {
      settled[version] = artifacts
    } else {
      recent[version] = (resolution, ContinuousClock.now)
    }
    return resolution
  }

  private enum Sidecar { case found(MachineV2Artifact), absent, unreachable }

  private static func lookup(_ version: String, base: URL, fetch: FetchClient, clock: any Clock<Duration>, timeout: Duration) async -> Resolution {
    let sidecars = await withTaskGroup(of: Sidecar.self) { group in
      for platform in platforms {
        group.addTask { await sidecar(version, platform: platform, base: base, fetch: fetch, clock: clock, timeout: timeout) }
      }
      return await group.reduce(into: [Sidecar]()) { $0.append($1) }
    }
    var artifacts: [MachineV2Artifact] = []
    for sidecar in sidecars {
      switch sidecar {
      case .unreachable: return .unreachable
      case .absent: continue
      case let .found(artifact): artifacts.append(artifact)
      }
    }
    guard !artifacts.isEmpty else { return .unpublished }
    return .published(artifacts.sorted { $0.platform < $1.platform })
  }

  private static func sidecar(_ version: String, platform: Platform, base: URL, fetch: FetchClient, clock: any Clock<Duration>, timeout: Duration) async -> Sidecar {
    let name = "wuhu-\(version)-\(platform.key).\(platform.archiveExtension)"
    let archive = base.appendingPathComponent("releases").appendingPathComponent(name)
    let request = Request(url: archive.deletingLastPathComponent().appendingPathComponent(name + ".sha256"))
    do {
      let text: String? = try await withThrowingTaskGroup(of: String?.self) { group in
        group.addTask {
          let response = try await fetch(request)
          switch response.status.code {
          case 200: return try await response.body.text(upTo: 4096)
          case 403, 404: return nil
          default: throw MachineV2ReleaseLookupFailed()
          }
        }
        group.addTask {
          try await clock.sleep(for: timeout)
          throw MachineV2ReleaseLookupFailed()
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
      guard let text else { return .absent }
      guard let digest = digest(text, archive: name) else {
        Logger(label: "wuhu.machine-v2.upgrade").warning("malformed release sidecar", metadata: ["archive": "\(name)"])
        return .unreachable
      }
      return .found(MachineV2Artifact(platform: platform.key, url: archive.absoluteString, sha256: digest))
    } catch {
      return .unreachable
    }
  }

  /// `shasum -a 256` output: `<64 hex>  <archive name>`.
  static func digest(_ text: String, archive: String) -> String? {
    let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count == 2, fields[1] == archive || fields[1] == "*" + archive else { return nil }
    let hex = fields[0].lowercased()
    guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }) else { return nil }
    return hex
  }
}

private struct MachineV2ReleaseLookupFailed: Error {}

/// What a machine is told to run. Read on every hello, so a pin or pause
/// takes effect at the next one without a restart.
final class MachineV2Upgrades: Sendable {
  let space: Space
  let serverVersion: String
  let releases: MachineV2Releases
  private let lastIgnored = Mutex<String?>(nil)

  init(space: Space, serverVersion: String, releases: MachineV2Releases) {
    self.space = space
    self.serverVersion = serverVersion
    self.releases = releases
  }

  func announcement(for machine: MachineID) async -> MachineV2Upgrade {
    let rule = await setting()?.effective(for: machine.rawValue) ?? .init()
    let pinned = rule.pin != nil
    let target = rule.pin ?? (MachineV2ReleaseVersion.isValid(serverVersion) ? serverVersion : nil)
    guard let target else {
      return MachineV2Upgrade(version: nil, pinned: false, status: rule.pause == true ? .paused : .unstamped, artifacts: [])
    }
    if rule.pause == true {
      return MachineV2Upgrade(version: target, pinned: pinned, status: .paused, artifacts: [])
    }
    switch await releases.resolve(target) {
    case let .published(artifacts): return MachineV2Upgrade(version: target, pinned: pinned, status: .ready, artifacts: artifacts)
    case .unpublished: return MachineV2Upgrade(version: target, pinned: pinned, status: .unpublished, artifacts: [])
    case .unreachable: return MachineV2Upgrade(version: target, pinned: pinned, status: .unreachable, artifacts: [])
    }
  }

  /// A missing or unparseable file means "follow the server"; a bad file is
  /// logged once per distinct content rather than on every hello.
  private func setting() async -> MachineV2UpgradeSetting? {
    let data: Data
    do { data = try await space.fs(.shared).read(MachineV2UpgradeSetting.path).1 }
    catch SpaceError.notFound { return nil }
    catch {
      ignoring("unreadable: \(error)")
      return nil
    }
    guard let setting = MachineV2UpgradeSetting.parse(data) else {
      ignoring("unparseable: " + String(decoding: data.prefix(4096), as: UTF8.self))
      return nil
    }
    return setting
  }

  private func ignoring(_ reason: String) {
    let fresh = lastIgnored.withLock { last in
      defer { last = reason }
      return last != reason
    }
    guard fresh else { return }
    Logger(label: "wuhu.machine-v2.upgrade").warning("ignoring \(MachineV2UpgradeSetting.path); machines follow the server", metadata: ["reason": "\(reason)"])
  }
}
