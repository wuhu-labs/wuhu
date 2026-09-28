#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import FetchAsyncHTTPClient
import enum PinnedTLS.PinnedTLS
import Testing

@Suite(.serialized)
struct TrustContractTests {
  @Test(arguments: TrustContractScenario.allCases)
  func nioTransportSatisfiesTheTrustContract(scenario: TrustContractScenario) async throws {
    let verdict = try await TrustContract.verdict(scenario, dialer: nioDialer)
    #expect(verdict.satisfied, "\(scenario.rawValue): \(verdict.failure ?? "dial succeeded")")
  }
}

// The production shape: system trust rides AsyncHTTPClient (h2-capable) with
// the injected anchors as trust roots; pins ride the PinnedTLS NIO dial.
private let nioDialer = TrustDialer { url, policy, anchors in
  switch policy {
  case .pinned(let fingerprint):
    let response = try await PinnedTLS.fetch(Request(url: url), pinnedFingerprint: fingerprint, timeout: .seconds(10))
    return try await response.body.text()
  case .system:
    let client = HTTPClient(
      eventLoopGroupProvider: .singleton,
      configuration: HTTPClient.Configuration(tlsConfiguration: anchors.clientConfiguration()),
    )
    do {
      let response = try await FetchClient.asyncHTTPClient(client)(Request(url: url))
      let text = try await response.body.text()
      try await client.shutdown()
      return text
    } catch {
      try? await client.shutdown()
      throw error
    }
  }
}
