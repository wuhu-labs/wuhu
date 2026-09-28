#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct Fetch.Response
import struct Fetch.Status
import NIOSSL
import enum PinnedTLS.TrustAnchors
import enum PinnedTLS.TrustPolicy
import ServeNIO
import ServeTLS

struct TrustDialer: Sendable {
  var fetchText: @Sendable (_ url: URL, _ policy: TrustPolicy, _ anchors: TrustAnchors) async throws -> String

  init(fetchText: @escaping @Sendable (URL, TrustPolicy, TrustAnchors) async throws -> String) {
    self.fetchText = fetchText
  }
}

enum TrustContractScenario: String, CaseIterable, Sendable {
  case systemTrustsAnAnchoredAuthority
  case systemRejectsAnUnknownAuthority
  case systemRejectsAHostnameMismatch
  case pinMatchesTheServedLeaf
  case pinMatchesASelfSignedLeaf
  case pinRejectsADifferentLeaf
  case pinSkipsHostnameVerification

  var expectsSuccess: Bool {
    switch self {
    case .systemTrustsAnAnchoredAuthority, .pinMatchesTheServedLeaf, .pinMatchesASelfSignedLeaf,
         .pinSkipsHostnameVerification:
      true
    case .systemRejectsAnUnknownAuthority, .systemRejectsAHostnameMismatch, .pinRejectsADifferentLeaf:
      false
    }
  }

  var servedHostnameMatches: Bool {
    switch self {
    case .systemRejectsAHostnameMismatch, .pinSkipsHostnameVerification: false
    default: true
    }
  }

  var servedLeafIsSelfSigned: Bool {
    self == .pinMatchesASelfSignedLeaf
  }
}

struct TrustContractVerdict: Sendable {
  let scenario: TrustContractScenario
  let failure: String?

  var satisfied: Bool {
    (self.failure == nil) == self.scenario.expectsSuccess
  }
}

enum TrustContract {
  static func verdict(_ scenario: TrustContractScenario, dialer: TrustDialer) async throws -> TrustContractVerdict {
    let authority = try TLSIdentity.selfSigned(hosts: ["wuhu-trust-contract-ca"])
    let hosts = scenario.servedHostnameMatches ? ["localhost"] : ["wuhu.invalid"]
    let identity = scenario.servedLeafIsSelfSigned
      ? try TLSIdentity.selfSigned(hosts: hosts)
      : try TLSIdentity.issued(hosts: hosts, by: authority)
    let anchors: TrustAnchors = switch scenario {
    case .systemRejectsAnUnknownAuthority:
      .certificates([try derBytes(of: try TLSIdentity.selfSigned(hosts: ["wuhu-other-ca"]))])
    default:
      .certificates([try derBytes(of: authority)])
    }
    let policy: TrustPolicy = switch scenario {
    case .pinMatchesTheServedLeaf, .pinMatchesASelfSignedLeaf, .pinSkipsHostnameVerification:
      .pinned(fingerprint: try identity.fingerprint())
    case .pinRejectsADifferentLeaf:
      .pinned(fingerprint: try TLSIdentity.selfSigned(hosts: ["localhost"]).fingerprint())
    default:
      .system
    }
    let server = try await ServeNIOServer.bind(host: "localhost", port: 0, tls: identity) { request in
      Response(status: .ok, body: .chunk(Data("trusted \(request.url.path)".utf8)))
    }
    guard let port = server.boundAddress.port, let url = URL(string: "https://localhost:\(port)/contract") else {
      await server.shutdown()
      throw TrustContractError.serverAddressUnavailable
    }
    let verdict: TrustContractVerdict
    do {
      let text = try await dialer.fetchText(url, policy, anchors)
      verdict = TrustContractVerdict(
        scenario: scenario,
        failure: text == "trusted /contract" ? nil : "unexpected body: \(text)",
      )
    } catch {
      verdict = TrustContractVerdict(scenario: scenario, failure: String(describing: error))
    }
    await server.shutdown()
    return verdict
  }
}

enum TrustContractError: Error, Sendable {
  case serverAddressUnavailable
}

private func derBytes(of identity: TLSIdentity) throws -> [UInt8] {
  try NIOSSLCertificate(bytes: Array(identity.certificatePEM.utf8), format: .pem).toDERBytes()
}
