#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Logging
import MachineContract
import OrderedCollections
import SpaceCore
import Synchronization
import Wuwei

/// The admin's hold on machine agent upgrades: `/machine-v2-upgrade.json` in
/// the settings group. A per-machine field overrides the global one.
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

/// What a machine is told to run. Read on every hello, so a pin or pause
/// takes effect at the next one without a restart.
final class MachineV2Upgrades: Sendable {
  let space: Space
  let serverVersion: String
  private let lastIgnored = Mutex<String?>(nil)

  init(space: Space, serverVersion: String) {
    self.space = space
    self.serverVersion = serverVersion
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
    let resolution = space.worker.job(MachineReleaseJob.singleton).resolution(for: target)
    if resolution?.isFinal != true { space.worker.send(.resolve(target), to: MachineReleaseJob.singleton) }
    switch resolution ?? .unreachable {
    case let .published(artifacts): return MachineV2Upgrade(version: target, pinned: pinned, status: .ready, artifacts: artifacts)
    case .unpublished: return MachineV2Upgrade(version: target, pinned: pinned, status: .unpublished, artifacts: [])
    case .unreachable: return MachineV2Upgrade(version: target, pinned: pinned, status: .unreachable, artifacts: [])
    }
  }

  /// A missing or unparseable file means "follow the server"; a bad file is
  /// logged once per distinct content rather than on every hello.
  private func setting() async -> MachineV2UpgradeSetting? {
    let data: Data
    do { data = try await space.fs(.settings).read(MachineV2UpgradeSetting.path).1 }
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
