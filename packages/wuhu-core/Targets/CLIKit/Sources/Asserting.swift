#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Dependencies
import Fetch
import protocol MachineChannel.FrameTransport
import SpaceClient
import Synchronization

private let assertionLifetime: TimeInterval = 3600
private let remintLeeway: TimeInterval = 60

struct AssertionMinter: Sendable {
  var space: String
  var host: String
  var keys: DeviceKeyStore
  var dateGen: DateGenerator

  func mint() async throws -> SignedAssertion {
    guard let key = try self.keys.load(space: self.space) else {
      throw CLIError(message: """
      no device key for \(self.host); it was removed or never enrolled
      re-enroll this device: wuhu login < invite-link (mint one on an enrolled device: wuhu share-login)
      """)
    }
    let claims = AssertionClaims(
      key: key.pubkeyLabel,
      space: self.space,
      expiresAt: self.dateGen.now.addingTimeInterval(assertionLifetime),
    )
    return try claims.signed(by: key)
  }
}

final class BearerSource: Sendable {
  private let dateGen: DateGenerator
  private let remint: @Sendable () async throws -> SignedAssertion
  private let current: Mutex<SignedAssertion>

  init(
    initial: SignedAssertion,
    dateGen: DateGenerator,
    remint: @escaping @Sendable () async throws -> SignedAssertion,
  ) {
    self.dateGen = dateGen
    self.remint = remint
    self.current = Mutex(initial)
  }

  func value() async throws -> String {
    let held = self.current.withLock { $0 }
    if held.claims.isLive(at: self.dateGen.now.addingTimeInterval(remintLeeway)) {
      return held.rawValue
    }
    let fresh = try await self.remint()
    self.current.withLock { $0 = fresh }
    return fresh.rawValue
  }
}

extension Executor {
  mutating func authenticated(_ space: String) async throws -> SpaceClient {
    if let session = self.session {
      return self.sessionClient(session)
    }
    let group = self.group.group
    if let group {
      try await self.requireGroups(space: space, selected: group)
    }
    guard let bearer = try await self.bearerSource(space: space) else {
      return self.client(space, group: group)
    }
    let runner = self.runner
    var dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)?
    if let inner = runner.dial {
      dial = { url, headers in
        let assertion = try await bearer.value()
        return try await inner(url, headers + [("authorization", "Bearer " + assertion)])
      }
    }
    return SpaceClient(
      space: space,
      fetch: authorized(runner.fetch, bearer),
      observeFetch: authorized(runner.observeFetch, bearer),
      dial: dial,
      group: group,
    )
  }

  mutating func bearerSource(space: String) async throws -> BearerSource? {
    // A session's exec never reads the device keys.
    guard self.session == nil else { return nil }
    let endpoint = try self.endpoint(space: space)
    let held = self.wallet.assertion(space: space).flatMap(SignedAssertion.init(rawValue:))
    guard endpoint.secure else { return nil }
    @Dependency(\.date) var dateGen
    let keys = try DeviceKeyStore(environment: self.runner.environment)
    guard FileManager.default.fileExists(atPath: keys.directory.path) else { return nil }
    let identities = try SpaceIdentityStore(environment: self.runner.environment)
    guard let identity = try identities.identity(forHost: endpoint.key) else { return nil }
    // The store is authoritative for the audience: a cached assertion is
    // honored only if it targets that id, so a stale id left by a space reset
    // + re-enroll can never shadow the live one into permanent 401s.
    let cached = held.flatMap { $0.claims.space == identity ? $0 : nil }
    if cached == nil {
      guard try keys.load(space: identity) != nil else { return nil }
    }
    let minter = AssertionMinter(
      space: identity,
      host: endpoint.key,
      keys: keys,
      dateGen: dateGen,
    )
    if let cached, cached.claims.isLive(at: dateGen.now.addingTimeInterval(remintLeeway)) {
      return BearerSource(initial: cached, dateGen: dateGen, remint: minter.mint)
    }
    let minted = try await minter.mint()
    self.wallet.recordAssertion(minted.rawValue, space: space)
    return BearerSource(initial: minted, dateGen: dateGen, remint: minter.mint)
  }
}

private func authorized(_ fetch: FetchClient, _ bearer: BearerSource) -> FetchClient {
  FetchClient { request in
    var request = request
    request.headers.setSensitive(.authorization, "Bearer " + (try await bearer.value()))
    return try await fetch(request)
  }
}
