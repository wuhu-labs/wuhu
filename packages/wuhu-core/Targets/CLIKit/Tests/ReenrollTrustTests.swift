#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import enum PinnedTLS.PinnedTLS
import SpaceCore
import Testing

// Re-enrolling replaces the pin: a link with a fingerprint re-pins to it, one
// without (a server on --cert/--key) drops the pin for system trust. A link
// without one to a server system trust rejects enrolls through the pin.
@Suite(.serialized) struct ReenrollTrustTests {
  enum Verb: CaseIterable {
    case login
    case machineJoin
  }

  static let stalePin = "sha256:" + String(repeating: "a", count: 64)

  @Test(arguments: Verb.allCases)
  func anEnrollmentWithoutAFingerprintDropsAStalePinForSystemTrust(verb: Verb) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let key = "127.0.0.1:\(server.port)"
      try rig.trust.record(Self.stalePin, forHost: key)
      let (arguments, stdin) = try await Self.enrollment(verb, rig: rig, server: server, fingerprint: nil)
      let io = CLIIO(stdin: stdin)
      let system = RequestLog()
      let code = await withDependencies {
        $0[ServerTrustProbe.self] = Self.probe(systemTrusts: true)
      } operation: {
        await rig.run(arguments, io: io, plain: Self.systemTrusting(server.fingerprint, log: system))
      }
      #expect(code == 0)
      #expect(try rig.trust.pin(forHost: key) == nil)
      #expect(system.recorded.contains("/v1/enroll/consume"))
      #expect(await io.stderrText().contains("forgot the certificate pin for \(key); system trust applies\n"))
    }
  }

  @Test(arguments: Verb.allCases)
  func anEnrollmentWithAFingerprintRepinsToIt(verb: Verb) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let key = "127.0.0.1:\(server.port)"
      try rig.trust.record(Self.stalePin, forHost: key)
      let (arguments, stdin) = try await Self.enrollment(verb, rig: rig, server: server, fingerprint: server.fingerprint)
      let io = CLIIO(stdin: stdin)
      #expect(await rig.run(arguments, io: io) == 0)
      #expect(try rig.trust.pin(forHost: key) == server.fingerprint)
      #expect(await !io.stderrText().contains("forgot the certificate pin"))
    }
  }

  @Test(arguments: Verb.allCases)
  func anEnrollmentWithoutAFingerprintThatSystemTrustRejectsGoesThroughThePin(verb: Verb) async throws {
    let rig = try EnrollRig()
    defer { rig.cleanUp() }
    try await rig.serving { server in
      let key = "127.0.0.1:\(server.port)"
      try rig.trust.record(server.fingerprint, forHost: key)
      let (arguments, stdin) = try await Self.enrollment(verb, rig: rig, server: server, fingerprint: nil)
      let io = CLIIO(stdin: stdin)
      let code = await withDependencies {
        $0[ServerTrustProbe.self] = Self.probe(systemTrusts: false)
      } operation: {
        await rig.run(arguments, io: io)
      }
      #expect(code == 0)
      #expect(try rig.trust.pin(forHost: key) == server.fingerprint)
      #expect(await !io.stderrText().contains("forgot the certificate pin"))
    }
  }

  // Mints a one-time enrollment for `verb` and returns the argv and stdin that consume it.
  static func enrollment(
    _ verb: Verb, rig: EnrollRig, server: BoundServer, fingerprint: String?,
  ) async throws -> (arguments: [String], stdin: String) {
    let base = "https://127.0.0.1:\(server.port)"
    switch verb {
    case .login:
      let account = try await rig.space.addAccount(kind: .human, name: "alice")
      let minted = try await rig.space.mintJoinToken(
        account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600,
      )
      let pin = fingerprint.map { "&fp=\($0)" } ?? ""
      return (["login"], "\(base)/_/enroll#token=\(minted.token.rawValue)&space=\(server.space)\(pin)\n")
    case .machineJoin:
      let machine = try await rig.space.addMachine(name: "box")
      let minted = try await rig.space.mintJoinToken(
        account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600,
      )
      return (["machine", "join", base] + (fingerprint.map { [$0] } ?? []), minted.token.rawValue + "\n")
    }
  }

  static func probe(systemTrusts: Bool) -> ServerTrustProbe {
    ServerTrustProbe(
      validateSystem: { _, _ in
        guard systemTrusts else { throw CLIError(message: "certificate not trusted") }
      },
      observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
    )
  }

  // The system trust store, as far as this test is concerned: it accepts the
  // served certificate.
  static func systemTrusting(_ fingerprint: String, log: RequestLog) -> FetchClient {
    FetchClient { request in
      log.record(request.url.path)
      return try await PinnedTLS.fetch(request, pinnedFingerprint: fingerprint, timeout: .seconds(10))
    }
  }
}
