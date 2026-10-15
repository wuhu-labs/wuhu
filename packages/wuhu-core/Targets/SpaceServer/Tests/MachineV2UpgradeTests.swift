import Crypto
import Fetch
import Foundation
import MachineContract
import OperationProtocol
import Serve
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

private let linuxDigest = String(repeating: "a", count: 64)
private let macDigest = String(repeating: "b", count: 64)

/// A wuhu.ai stand-in: serves the `.sha256` sidecars of `published` versions and counts every lookup.
private final class ReleaseHost: Sendable {
  enum Mode { case serve, fail, hang }
  let published: Mutex<[String: Set<String>]>
  let mode: Mutex<Mode>
  let lookups = Mutex<[String]>([])

  init(_ published: [String: Set<String>] = [:], mode: Mode = .serve) {
    self.published = Mutex(published)
    self.mode = Mutex(mode)
  }

  var fetch: FetchClient {
    FetchClient { request in
      let name = request.url.lastPathComponent
      self.lookups.withLock { $0.append(name) }
      switch self.mode.withLock({ $0 }) {
      case .fail: throw URLError(.cannotConnectToHost)
      case .hang:
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
      case .serve: break
      }
      #expect(request.url.host == "wuhu.ai")
      #expect(request.url.path.hasPrefix("/releases/"))
      for (version, platforms) in self.published.withLock({ $0 }) {
        for platform in platforms {
          let archive = "wuhu-\(version)-\(platform).\(platform == "linux-amd64" ? "tar.gz" : "zip")"
          if name == archive + ".sha256" {
            return .text("\(platform == "linux-amd64" ? linuxDigest : macDigest)  \(archive)\n")
          }
        }
      }
      return Response(status: .notFound)
    }
  }

  var count: Int { lookups.withLock { $0.count } }
}

private struct Fixture {
  let space: Space
  let handler: UpgradingHandler
  let machine: MachineRecord
  let other: MachineRecord
  let key: Curve25519.Signing.PrivateKey

  init(version: String = "0.1.0-dev.122", host: ReleaseHost, dev: Bool = true, timeout: Duration = .seconds(5)) async throws {
    space = try Space.inMemory()
    let hub = MachineV2Hub(space: space)
    let releases = MachineV2Releases(base: URL(string: "https://wuhu.ai")!, fetch: host.fetch, clock: ContinuousClock(), timeout: timeout)
    let enrolling = SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), dev: true, version: version, webApp: nil, machineV2Hub: hub, machineV2Releases: releases)
    let key = Curve25519.Signing.PrivateKey()
    self.key = key
    machine = try await Self.enroll(space, enrolling, "laptop", key)
    other = try await Self.enroll(space, enrolling, "desktop", .init())
    handler = dev ? enrolling : SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), dev: false, version: version, webApp: nil, machineV2Hub: hub, machineV2Releases: releases)
  }

  static func enroll(_ space: Space, _ handler: UpgradingHandler, _ name: String, _ key: Curve25519.Signing.PrivateKey) async throws -> MachineRecord {
    let request = Request(url: URL(string: "https://space.test/v1/machine-v2")!, method: .post, body: try .json(MachineAddInput(name: name, pubkey: key.pubkeyLabel)))
    guard case let .response(response) = try await handler(request) else { throw OperationError(.invalidResponse) }
    let output = try await response.body.json(EnrollConsumeOutput.self)
    let id = try #require(output.machine)
    return try #require(try await space.machine(MachineID(rawValue: id)))
  }

  func setting(_ text: String?) async throws {
    let fs = await space.fs(.shared)
    if let text {
      let current = try? await fs.read(MachineV2UpgradeSetting.path).0
      _ = try await fs.write(MachineV2UpgradeSetting.path, Data(text.utf8), ifMatch: current)
    } else {
      try await fs.delete(MachineV2UpgradeSetting.path, ifMatch: nil)
    }
  }

  func signed(_ path: String, as machines: [MachineID]? = nil) async throws -> Request {
    guard case let .response(minted) = try await handler(Request(url: URL(string: "https://space.test/v1/machine-v2/challenge")!)) else { throw OperationError(.invalidResponse) }
    let challenge = try await minted.body.json(MachineChallengeOutput.self).challenge
    let names = (machines ?? [machine.id]).map(\.rawValue)
    var headers = RequestHeaders()
    headers[MachineV2Connect.pubkeyHeader] = key.pubkeyLabel
    headers[MachineV2Connect.challengeHeader] = challenge
    headers[MachineV2Connect.machinesHeader] = names.joined(separator: ",")
    headers[MachineV2Connect.signatureHeader] = try key.signature(for: MachineV2Connect.signingPayload(challenge: challenge, machines: names)).base64EncodedString()
    return Request(url: URL(string: "https://space.test" + path)!, headers: headers)
  }

  func response(_ request: Request) async throws -> Response {
    guard case let .response(response) = try await handler(request) else { throw OperationError(.invalidResponse) }
    return response
  }

  /// What the machine's own key-signed hello announces.
  func hello() async throws -> MachineV2Upgrade {
    let response = try await response(try await signed("/v1/machine-v2/" + machine.id.rawValue))
    #expect(response.status == .ok)
    return try #require(try await response.body.json(Hello.self).upgrade)
  }

  func announcement() async throws -> MachineV2Upgrade {
    let response = try await response(try await signed("/v1/machine-v2/\(machine.id.rawValue)/upgrade"))
    #expect(response.status == .ok)
    return try await response.body.json(MachineV2Upgrade.self)
  }
}

private struct Hello: Decodable {
  let id: MachineID
  let attached: Bool
  let upgrade: MachineV2Upgrade?
}

private func ready(_ version: String, pinned: Bool = false) -> MachineV2Upgrade {
  MachineV2Upgrade(version: version, pinned: pinned, status: .ready, artifacts: [
    .init(platform: "linux-amd64", url: "https://wuhu.ai/releases/wuhu-\(version)-linux-amd64.tar.gz", sha256: linuxDigest),
    .init(platform: "macos-arm64", url: "https://wuhu.ai/releases/wuhu-\(version)-macos-arm64.zip", sha256: macDigest),
  ])
}

private let both: Set<String> = ["linux-amd64", "macos-arm64"]

@Suite struct MachineV2UpgradeTests {
  @Test func helloAnnouncesTheServerVersionAndCachesAPublishedRelease() async throws {
    let host = ReleaseHost(["0.1.0-dev.122": both])
    let f = try await Fixture(host: host)
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
    #expect(try await f.announcement() == ready("0.1.0-dev.122"))
    #expect(host.count == 2)
    #expect(Set(host.lookups.withLock { $0 }) == ["wuhu-0.1.0-dev.122-linux-amd64.tar.gz.sha256", "wuhu-0.1.0-dev.122-macos-arm64.zip.sha256"])
  }

  @Test func personReadsOfTheMachineCarryNoAnnouncement() async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": both]))
    let response = try await f.response(Request(url: URL(string: "https://space.test/v1/machine-v2/" + f.machine.id.rawValue)!))
    #expect(response.status == .ok)
    #expect(try await response.body.json(Hello.self).upgrade == nil)
    let unsigned = try await f.response(Request(url: URL(string: "https://space.test/v1/machine-v2/\(f.machine.id.rawValue)/upgrade")!))
    #expect(unsigned.status == .unauthorized)
  }

  @Test func pinAndPauseApplyGloballyAndPerMachineOverrides() async throws {
    let host = ReleaseHost(["0.1.0-dev.122": both, "0.1.0-dev.120": both, "0.1.0-dev.119": both])
    let f = try await Fixture(host: host)
    try await f.setting(#"{"pin":"0.1.0-dev.120"}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.120", pinned: true))
    try await f.setting(#"{"pin":"0.1.0-dev.120","machines":{"\#(f.machine.id.rawValue)":{"pin":"0.1.0-dev.119"}}}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.119", pinned: true))
    try await f.setting(#"{"pause":true}"#)
    #expect(try await f.hello() == MachineV2Upgrade(version: "0.1.0-dev.122", pinned: false, status: .paused, artifacts: []))
    try await f.setting(#"{"pause":true,"machines":{"\#(f.machine.id.rawValue)":{"pause":false}}}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
    try await f.setting(#"{"machines":{"\#(f.other.id.rawValue)":{"pause":true,"pin":"0.1.0-dev.119"}}}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
    try await f.setting(#"{"pin":"0.1.0-dev.120","machines":{"\#(f.machine.id.rawValue)":{"pause":true}}}"#)
    #expect(try await f.hello() == MachineV2Upgrade(version: "0.1.0-dev.120", pinned: true, status: .paused, artifacts: []))
  }

  @Test(arguments: [
    "not json", #"[]"#, #"{"pin":"latest"}"#, #"{"pin":"v0.1.0"}"#, #"{"pin":"0.1.0-rc.1"}"#, #"{"pause":"yes"}"#,
    #"{"paused":true}"#, #"{"machines":{"laptop":{"pause":true}}}"#, #"{"machines":{"mc_abcdefgh":{"pin":"0.1.0","extra":1}}}"#,
  ])
  func malformedSettingFollowsTheServer(_ text: String) async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": both]))
    try await f.setting(text)
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
  }

  @Test func missingSettingFollowsTheServerAndDeletionUnpins() async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": both, "0.1.0-dev.120": both]))
    try await f.setting(#"{"pin":"0.1.0-dev.120"}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.120", pinned: true))
    try await f.setting(nil)
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
  }

  @Test func settingParsesTheDocumentedShape() throws {
    let setting = try #require(MachineV2UpgradeSetting.parse(Data(#"{"pause":false,"pin":"1.2.3-beta.4","machines":{"mc_abcdefgh":{"pin":"0.1.0"},"mc_zzzzzzzz":{"pause":true,"pin":null}}}"#.utf8)))
    #expect(setting.global == .init(pause: false, pin: "1.2.3-beta.4"))
    #expect(setting.effective(for: "mc_abcdefgh") == .init(pause: false, pin: "0.1.0"))
    #expect(setting.effective(for: "mc_zzzzzzzz") == .init(pause: true, pin: "1.2.3-beta.4"))
    #expect(setting.effective(for: "mc_00000000") == .init(pause: false, pin: "1.2.3-beta.4"))
    #expect(MachineV2UpgradeSetting.parse(Data("{}".utf8)) == MachineV2UpgradeSetting())
    for valid in ["0.1.0", "10.20.30", "0.1.0-dev.121", "1.0.0-beta.1"] { #expect(MachineV2ReleaseVersion.isValid(valid)) }
    for invalid in ["0.1", "0.1.0.0", "0.1.0-dev", "0.1.0-dev.", "0.1.0-alpha.1", "0.1.0-dev.1.2", "0.0.0-unstamped", " 0.1.0", "0.1.x"] { #expect(!MachineV2ReleaseVersion.isValid(invalid)) }
  }

  @Test func sidecarDigestIsStrict() {
    let archive = "wuhu-0.1.0-linux-amd64.tar.gz"
    #expect(MachineV2Releases.digest("\(linuxDigest)  \(archive)\n", archive: archive) == linuxDigest)
    #expect(MachineV2Releases.digest("\(linuxDigest.uppercased()) *\(archive)", archive: archive) == linuxDigest)
    #expect(MachineV2Releases.digest("\(linuxDigest)  wuhu-0.1.0-macos-arm64.zip", archive: archive) == nil)
    #expect(MachineV2Releases.digest(String(linuxDigest.dropLast()) + "  " + archive, archive: archive) == nil)
    #expect(MachineV2Releases.digest(String(repeating: "g", count: 64) + "  " + archive, archive: archive) == nil)
    #expect(MachineV2Releases.digest(linuxDigest, archive: archive) == nil)
  }

  @Test func unstampedServerAnnouncesNothingUnlessPinned() async throws {
    let host = ReleaseHost(["0.1.0-dev.120": both])
    let f = try await Fixture(version: SpaceServer.unstampedVersion, host: host)
    #expect(try await f.hello() == MachineV2Upgrade(version: nil, pinned: false, status: .unstamped, artifacts: []))
    #expect(host.count == 0)
    try await f.setting(#"{"pin":"0.1.0-dev.120"}"#)
    #expect(try await f.hello() == ready("0.1.0-dev.120", pinned: true))
  }

  @Test func unpublishedPinIsTypedAndBackedOff() async throws {
    let host = ReleaseHost(["0.1.0-dev.122": both])
    let f = try await Fixture(host: host)
    try await f.setting(#"{"pin":"0.1.0-dev.999"}"#)
    let unpublished = MachineV2Upgrade(version: "0.1.0-dev.999", pinned: true, status: .unpublished, artifacts: [])
    #expect(try await f.hello() == unpublished)
    #expect(try await f.announcement() == unpublished)
    #expect(host.count == 2)
  }

  @Test func onePublishedPlatformIsReadyWithOnlyThatArtifact() async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": ["macos-arm64"]]))
    #expect(try await f.hello() == MachineV2Upgrade(version: "0.1.0-dev.122", pinned: false, status: .ready, artifacts: [
      .init(platform: "macos-arm64", url: "https://wuhu.ai/releases/wuhu-0.1.0-dev.122-macos-arm64.zip", sha256: macDigest),
    ]))
  }

  @Test func unreachableReleaseHostIsTypedAndRecovers() async throws {
    let host = ReleaseHost(["0.1.0-dev.122": both], mode: .fail)
    let f = try await Fixture(host: host)
    #expect(try await f.hello() == MachineV2Upgrade(version: "0.1.0-dev.122", pinned: false, status: .unreachable, artifacts: []))
    let releases = MachineV2Releases(base: URL(string: "https://wuhu.ai")!, fetch: host.fetch, clock: ContinuousClock(), retryAfter: .zero)
    #expect(await releases.resolve("0.1.0-dev.122") == .unreachable)
    host.mode.withLock { $0 = .serve }
    #expect(await releases.resolve("0.1.0-dev.122") == .published(ready("0.1.0-dev.122").artifacts))
  }

  @Test func hangingReleaseHostTimesOut() async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": both], mode: .hang), timeout: .milliseconds(50))
    #expect(try await f.hello() == MachineV2Upgrade(version: "0.1.0-dev.122", pinned: false, status: .unreachable, artifacts: []))
  }

  @Test func productionWallAdmitsTheSignedAnnouncementOnly() async throws {
    let f = try await Fixture(host: ReleaseHost(["0.1.0-dev.122": both]), dev: false)
    #expect(try await f.announcement() == ready("0.1.0-dev.122"))
    #expect(try await f.hello() == ready("0.1.0-dev.122"))
    let unsigned = try await f.response(Request(url: URL(string: "https://space.test/v1/machine-v2/\(f.machine.id.rawValue)/upgrade")!))
    #expect(unsigned.status == .unauthorized)
    let foreign = try await f.response(try await f.signed("/v1/machine-v2/\(f.other.id.rawValue)/upgrade", as: [f.other.id]))
    #expect(foreign.status == .unauthorized)
    let mismatched = try await f.response(try await f.signed("/v1/machine-v2/\(f.other.id.rawValue)/upgrade"))
    #expect(mismatched.status == .unauthorized)
  }
}
