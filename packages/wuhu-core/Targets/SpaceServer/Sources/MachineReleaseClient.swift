#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import Logging
import MachineContract

struct MachineReleaseClient: Sendable {
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

  let base: URL
  let fetch: FetchClient
  let clock: any Clock<Duration>
  var timeout: Duration = .seconds(5)

  private enum Sidecar { case found(MachineV2Artifact), absent, unreachable }

  func lookup(_ version: String) async throws -> Resolution {
    let sidecars = try await withThrowingTaskGroup(of: Sidecar.self) { group in
      for platform in Self.platforms {
        group.addTask { try await Self.sidecar(version, platform: platform, base: base, fetch: fetch, clock: clock, timeout: timeout) }
      }
      return try await group.reduce(into: [Sidecar]()) { $0.append($1) }
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

  private static func sidecar(_ version: String, platform: Platform, base: URL, fetch: FetchClient, clock: any Clock<Duration>, timeout: Duration) async throws -> Sidecar {
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
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
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
