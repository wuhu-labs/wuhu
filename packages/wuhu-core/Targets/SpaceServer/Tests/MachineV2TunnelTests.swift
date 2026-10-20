import Crypto
import DeterministicDependencies
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

@Suite(.deterministicDependencies) struct MachineV2TunnelTests {
  struct Fixture {
    let space: Space
    let hub: MachineV2Hub
    let handler: UpgradingHandler
    let machine: MachineRecord
    let key: Curve25519.Signing.PrivateKey
    init() async throws {
      space = try Space.inMemory()
      hub = MachineV2Hub(space: space)
      handler = SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), dev: true, machineV2Hub: hub)
      key = .init()
      let handler = self.handler
      func http<T: Encodable & Sendable>(_ path: String, method: Fetch.Method, input: T) async throws -> Response {
        let result = try await handler(Request(url: URL(string: "https://space.test" + path)!, method: method, body: .json(input)))
        guard case let .response(response) = result else { throw OperationError(.invalidResponse) }
        return response
      }
      let add = try await http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "scratch-v2"))
      let output = try await add.body.json(MachineAddOutput.self)
      _ = try await http("/v1/enroll/consume", method: .post, input: ["token": output.token, "pubkey": key.pubkeyLabel])
      machine = try #require(try await space.machine(output.id))
    }

    func http<T: Encodable & Sendable>(_ path: String, method: Fetch.Method, input: T) async throws -> Response {
      let result = try await handler(Request(url: URL(string: "https://space.test" + path)!, method: method, body: .json(input)))
      guard case let .response(response) = result else { throw OperationError(.invalidResponse) }
      return response
    }

    func challenge() async throws -> String {
      guard case let .response(response) = try await handler(Request(url: URL(string: "https://space.test/v1/machine-v2/challenge")!)) else { throw OperationError(.invalidResponse) }
      return try await response.body.json(MachineChallengeOutput.self).challenge
    }

    func connect(_ challenge: String, machines: [String], payload: Data? = nil, protocolName: String = "wuhu-fetch-tunnel.v1") async throws -> UpgradeResult {
      var headers = RequestHeaders()
      headers["connection"] = "Upgrade"; headers["upgrade"] = "websocket"
      headers["sec-websocket-key"] = "dGhlIHNhbXBsZSBub25jZQ=="; headers["sec-websocket-version"] = "13"
      headers["sec-websocket-protocol"] = protocolName
      headers[MachineV2Connect.pubkeyHeader] = key.pubkeyLabel
      headers[MachineV2Connect.challengeHeader] = challenge
      headers[MachineV2Connect.signatureHeader] = try key.signature(for: payload ?? MachineV2Connect.signingPayload(challenge: challenge, machines: machines)).base64EncodedString()
      headers[MachineV2Connect.machinesHeader] = machines.joined(separator: ",")
      return try await handler(Request(url: URL(string: "https://space.test/v1/machine-v2/connect")!, headers: headers))
    }
  }

  @Test func enrolledKeyNewDomainOneShotAndMachineCredential() async throws {
    let f = try await Fixture()
    let challenge = try await f.challenge()
    let result = try await f.connect(challenge, machines: [f.machine.id.rawValue])
    guard case let .boundedWebSocket(_, protocolName, _) = result else { Issue.record("valid credential rejected"); return }
    #expect(protocolName == "wuhu-fetch-tunnel.v1")
    guard case let .response(replayed) = try await f.connect(challenge, machines: [f.machine.id.rawValue]) else { Issue.record("replayed challenge accepted"); return }
    #expect(replayed.status == .unauthorized)
    let v1 = try await f.challenge()
    guard case let .response(wrongDomain) = try await f.connect(v1, machines: [f.machine.id.rawValue], payload: MachineConnect.signingPayload(challenge: v1)) else { Issue.record("v1 signature accepted"); return }
    #expect(wrongDomain.status == .unauthorized)
    guard case let .response(wrongMachine) = try await f.connect(try await f.challenge(), machines: ["mc_zzzzzzzz"]) else { Issue.record("wrong credential accepted"); return }
    #expect(wrongMachine.status == .unauthorized)
    let both = [f.machine.id.rawValue, "mc_zzzzzzzz"]
    guard case let .response(tooWide) = try await f.connect(try await f.challenge(), machines: both) else { Issue.record("overbroad credential accepted"); return }
    #expect(tooWide.status == .unauthorized)
    let noProtocol = try await f.connect(try await f.challenge(), machines: [f.machine.id.rawValue], protocolName: "wrong")
    guard case let .response(refused) = noProtocol else { Issue.record("subprotocol not enforced"); return }
    #expect(refused.status == .badRequest)
  }

  @Test func everyDispatchChecksIdentityVisibilityAndNoFallbackRoute() async throws {
    let f = try await Fixture()
    let dispatched = Mutex(0)
    let aborts = Mutex(0)
    let credential = MachineV2Hub.Credential(pubkey: f.key.pubkeyLabel, machines: [f.machine.id.rawValue])
    let request = Request(url: URL(string: "https://operation.test/machine/v2/machines/" + f.machine.id.rawValue)!)
    do { _ = try await f.hub.fetch(request, usableFrom: .shared); Issue.record("missing route should fail") }
    catch let error as OperationError { #expect(error.code == .machineUnavailable) }
    let first = try await f.hub.attach(credential, client: FetchClient { _ in dispatched.withLock { $0 += 1 }; return Response(status: .ok) }, abort: { aborts.withLock { $0 += 1 } })
    _ = try await f.hub.fetch(request, usableFrom: .shared)
    #expect(dispatched.withLock { $0 } == 1)
    let second = try await f.hub.attach(credential, client: FetchClient { _ in dispatched.withLock { $0 += 1 }; return Response(status: .ok) }, abort: { aborts.withLock { $0 += 1 } })
    #expect(aborts.withLock { $0 } == 1)
    await f.hub.remove(first)
    _ = try await f.hub.fetch(request, usableFrom: .shared)
    #expect(dispatched.withLock { $0 } == 2)
    let other = try await f.space.addMachine(name: "other-v2", group: .shared)
    try await f.space.registerMachineV2(other.id.rawValue, group: .shared)
    do { _ = try await f.hub.fetch(Request(url: URL(string: "https://operation.test/machine/v2/machines/" + other.id.rawValue)!), usableFrom: .shared); Issue.record("connection cannot authorize another machine") }
    catch let error as OperationError { #expect(error.code == .machineUnavailable) }
    _ = try await f.space.resetCredentials(account: f.machine.account)
    do { _ = try await f.hub.fetch(request, usableFrom: .shared); Issue.record("revoked key dispatched") }
    catch let error as OperationError { #expect(error.code == .machineNotAuthorized) }
    #expect(dispatched.withLock { $0 } == 2)
    await f.hub.remove(second)
  }
}

extension MachineV2TunnelTests {
  @Test func v1EnrollmentTokenRefusalDoesNotConsumeOrInstallItsKey() async throws {
    let f = try await Fixture()
    let legacy = try await f.space.addMachine(name: "legacy", group: .shared)
    let token = try await f.space.mintJoinToken(account: legacy.account, capabilities: [.execMachine], createdBy: nil, lifetime: 3600)
    let key = Curve25519.Signing.PrivateKey()
    let rejected = try await f.http("/v1/machine-v2/enroll", method: .post, input: ["token": token.token.rawValue, "pubkey": key.pubkeyLabel])
    #expect(rejected.status == .unauthorized)
    #expect(try await f.space.keys(account: legacy.account).isEmpty)
    _ = try await f.space.consumeJoinToken(token.token, pubkey: key.pubkeyLabel)
    #expect(try await f.space.machine(pubkey: key.pubkeyLabel) == legacy.id)
    let replayedAsV2 = try await f.http("/v1/machine-v2/enroll", method: .post, input: ["token": token.token.rawValue, "pubkey": key.pubkeyLabel])
    #expect(replayedAsV2.status == .unauthorized)
  }

  @Test func aLostEnrollResponseReplaysWithTheSameKeyOnly() async throws {
    let f = try await Fixture()
    let created = try await f.space.addMachineV2(name: "retry-v2")
    let key = Curve25519.Signing.PrivateKey()
    let input = ["token": created.token.token.rawValue, "pubkey": key.pubkeyLabel]
    let first = try await f.http("/v1/machine-v2/enroll", method: .post, input: input)
    #expect(first.status == .ok)
    let enrolled = try await first.body.json(EnrollConsumeOutput.self)
    #expect(enrolled.machine == created.machine.id.rawValue)
    let replayed = try await f.http("/v1/machine-v2/enroll", method: .post, input: input)
    #expect(replayed.status == .ok)
    #expect(try await replayed.body.json(EnrollConsumeOutput.self) == enrolled)
    let thief = try await f.http("/v1/machine-v2/enroll", method: .post, input: ["token": created.token.token.rawValue, "pubkey": Curve25519.Signing.PrivateKey().pubkeyLabel])
    #expect(thief.status == .unauthorized)
    #expect(try await f.space.keys(account: created.machine.account).map(\.pubkey) == [key.pubkeyLabel])
  }
}

extension MachineV2TunnelTests {
  @Test func machineMovePreservesExplicitMembershipButRevokesOldGroupVisibility() async throws {
    let f = try await Fixture()
    let person = try await f.space.addAccount(kind: .human, name: "other", admin: false)
    let group = try await f.space.ensurePersonalGroup(account: person.id)
    let credential = MachineV2Hub.Credential(pubkey: f.key.pubkeyLabel, machines: [f.machine.id.rawValue])
    _ = try await f.hub.attach(credential, client: FetchClient { _ in Response(status: .ok) }, abort: {})
    _ = try await f.space.moveMachine(f.machine.id, to: group)
    #expect(try await f.space.machineV2Members(group: .shared).isEmpty)
    #expect(try await f.space.machineV2Members(group: group) == [f.machine.id.rawValue])
    let request = Request(url: URL(string: "https://operation.test/machine/v2/machines/" + f.machine.id.rawValue)!)
    do { _ = try await f.hub.fetch(request, usableFrom: .shared); Issue.record("old group retained v2 visibility") }
    catch let error as OperationError { #expect(error.code == .unknownMachine) }
    #expect(try await f.hub.fetch(request, usableFrom: group).status == .ok)
  }
}

extension MachineV2TunnelTests {
  @Test func productionWallAdmitsOnlySelfAuthenticatedV2Routes() async throws {
    let f = try await Fixture()
    let handler = SpaceServer.configuredHandler(space: f.space, hub: MachineHub(space: f.space), dev: false, machineV2Hub: f.hub)
    guard case let .response(challengeResponse) = try await handler(Request(url: URL(string: "https://space.test/v1/machine-v2/challenge")!)) else { Issue.record("challenge should be HTTP"); return }
    #expect(challengeResponse.status == .ok)
    let challenge = try await challengeResponse.body.json(MachineChallengeOutput.self).challenge
    var headers = RequestHeaders()
    headers[MachineV2Connect.pubkeyHeader] = f.key.pubkeyLabel
    headers[MachineV2Connect.challengeHeader] = challenge
    headers[MachineV2Connect.machinesHeader] = f.machine.id.rawValue
    headers[MachineV2Connect.signatureHeader] = try f.key.signature(for: MachineV2Connect.signingPayload(challenge: challenge, machines: [f.machine.id.rawValue])).base64EncodedString()
    let status = Request(url: URL(string: "https://space.test/v1/machine-v2/" + f.machine.id.rawValue)!, headers: headers)
    guard case let .response(verified) = try await handler(status) else { Issue.record("status should be HTTP"); return }
    #expect(verified.status == .ok)
    #expect(try await verified.body.json(MachineStatus.self).id == f.machine.id)
    guard case let .response(replay) = try await handler(status) else { Issue.record("status should be HTTP"); return }
    #expect(replay.status == .unauthorized)
    let add = Request(url: URL(string: "https://space.test/v1/machine-v2")!, method: .post, body: try .json(MachineAddInput(name: "unauthorized-v2")))
    guard case let .response(refused) = try await handler(add) else { Issue.record("add should be HTTP"); return }
    #expect(refused.status == .unauthorized)
  }
}

extension MachineV2TunnelTests {
  @Test func missingRoutePreservesPersistedGoodbyeAcrossServerRestart() async throws {
    let f = try await Fixture()
    try await f.space.recordMachineV2Presence(f.machine.id.rawValue, group: .shared, state: .detached, reason: "leaving")
    let evidence = try #require(try await f.space.machineV2PresenceEvidence(f.machine.id.rawValue, group: .shared))
    let restarted = MachineV2Hub(space: f.space)
    let request = Request(url: URL(string: "https://operation.test/machine/v2/machines/" + f.machine.id.rawValue)!)
    do { _ = try await restarted.fetch(request, usableFrom: .shared); Issue.record("missing route must not dispatch") }
    catch let error as OperationError {
      #expect(error.code == .machineUnavailable)
      #expect(error.details == ["state": "detached", "started": false, "leftAt": .number(evidence.observedAt.timeIntervalSince1970)])
    }
  }

  @Test func missingRoutePreservesKnownSilenceAndRegistrationOrigin() async throws {
    let f = try await Fixture()
    let request = Request(url: URL(string: "https://operation.test/machine/v2/machines/" + f.machine.id.rawValue)!)
    let registration = try #require(try await f.space.machineV2PresenceEvidence(f.machine.id.rawValue, group: .shared))
    do { _ = try await f.hub.fetch(request, usableFrom: .shared); Issue.record("unanswered machine must not dispatch") }
    catch let error as OperationError {
      #expect(error.details == ["state": "lost", "started": false, "silentSince": .number(registration.observedAt.timeIntervalSince1970)])
    }
    try await f.space.recordMachineV2Presence(f.machine.id.rawValue, group: .shared, state: .attached, description: .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []))
    let answer = try #require(try await f.space.machineV2PresenceEvidence(f.machine.id.rawValue, group: .shared))
    try await f.space.recordMachineV2Presence(f.machine.id.rawValue, group: .shared, state: .lost, reason: "transportLost")
    let restarted = MachineV2Hub(space: f.space)
    do { _ = try await restarted.fetch(request, usableFrom: .shared); Issue.record("lost machine must not dispatch") }
    catch let error as OperationError {
      #expect(error.details == ["state": "lost", "started": false, "silentSince": .number(answer.observedAt.timeIntervalSince1970)])
    }
  }
}

extension MachineV2TunnelTests {
  func signed(_ handler: UpgradingHandler, _ path: String, method: Fetch.Method = .post, key: Curve25519.Signing.PrivateKey, machine: MachineID) async throws -> Request {
    guard case let .response(minted) = try await handler(Request(url: URL(string: "https://space.test/v1/machine-v2/challenge")!)) else { throw OperationError(.invalidResponse) }
    let challenge = try await minted.body.json(MachineChallengeOutput.self).challenge
    var headers = RequestHeaders()
    headers[MachineV2Connect.pubkeyHeader] = key.pubkeyLabel
    headers[MachineV2Connect.challengeHeader] = challenge
    headers[MachineV2Connect.machinesHeader] = machine.rawValue
    headers[MachineV2Connect.signatureHeader] = try key.signature(for: MachineV2Connect.signingPayload(challenge: challenge, machines: [machine.rawValue])).base64EncodedString()
    return Request(url: URL(string: "https://space.test" + path)!, method: method, headers: headers)
  }

  @Test func oneCallEnrollmentInstallsTheKeyWithoutASuffixOrJoinToken() async throws {
    let f = try await Fixture()
    let key = Curve25519.Signing.PrivateKey()
    let enrolled = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "Laptop", pubkey: key.pubkeyLabel))
    #expect(enrolled.status == .ok)
    let output = try await enrolled.body.json(EnrollConsumeOutput.self)
    #expect(output.machineName == "laptop")
    #expect(output.capabilities == ["exec-machine"])
    let machine = MachineID(rawValue: try #require(output.machine))
    #expect(try await f.space.machine(pubkey: key.pubkeyLabel) == machine)
    #expect(try await f.space.machineV2Members(group: .shared).contains(machine.rawValue))
    #expect(try await f.space.machine(machine)?.account.rawValue == output.account)
    try await f.hub.authorize(.init(pubkey: key.pubkeyLabel, machines: [machine.rawValue]))

    let taken = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "laptop", pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel))
    #expect(taken.status == .conflict)
    _ = try await f.space.addMachine(name: "old-box")
    let takenByV1 = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "old-box", pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel))
    #expect(takenByV1.status == .conflict)
    let reused = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "other", pubkey: key.pubkeyLabel))
    #expect(reused.status == .conflict)
    let malformed = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "other", pubkey: "ed25519:nope"))
    #expect(malformed.status == .badRequest)
    let unknownDevice = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "other", pubkey: Curve25519.Signing.PrivateKey().pubkeyLabel, device: "no-such-device"))
    #expect(unknownDevice.status == .notFound)
    let deviceWithoutKey = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "other-v2", device: "no-such-device"))
    #expect(deviceWithoutKey.status == .badRequest)
    #expect(try await f.space.resolveMachine("other") == nil)
  }

  @Test func aMachineRevokesItsOwnKeyWithOneSignedRequest() async throws {
    let f = try await Fixture()
    let path = "/v1/machine-v2/\(f.machine.id.rawValue)/revoke"
    let stranger = Curve25519.Signing.PrivateKey()
    let other = try await f.http("/v1/machine-v2", method: .post, input: MachineAddInput(name: "other", pubkey: stranger.pubkeyLabel))
    #expect(other.status == .ok)
    guard case let .response(foreign) = try await f.handler(try await signed(f.handler, path, key: stranger, machine: f.machine.id)) else { Issue.record("revoke should be HTTP"); return }
    #expect(foreign.status == .unauthorized)
    #expect(try await f.space.machine(pubkey: f.key.pubkeyLabel) == f.machine.id)

    let wall = SpaceServer.configuredHandler(space: f.space, hub: MachineHub(space: f.space), dev: false, machineV2Hub: f.hub)
    let request = try await signed(wall, path, key: f.key, machine: f.machine.id)
    guard case let .response(revoked) = try await wall(request) else { Issue.record("revoke should be HTTP"); return }
    #expect(revoked.status == .ok)
    #expect(try await f.space.machine(pubkey: f.key.pubkeyLabel) == nil)
    #expect(try await f.space.machine(f.machine.id) != nil)
    await #expect(throws: (any Error).self) { try await f.hub.authorize(.init(pubkey: f.key.pubkeyLabel, machines: [f.machine.id.rawValue])) }
    guard case let .response(again) = try await f.handler(try await signed(f.handler, path, key: f.key, machine: f.machine.id)) else { Issue.record("revoke should be HTTP"); return }
    #expect(again.status == .unauthorized)
    #expect(try await f.space.machine(pubkey: stranger.pubkeyLabel) != nil)
  }

  @Test func aRotationCommittingDuringAnAuthenticatedRevokeKeepsTheReplacementKey() async throws {
    let parked = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let space = try Space.inMemory()
    let hub = MachineV2Hub(space: space) { _ in
      parked.continuation.yield()
      for await _ in resume.stream { return }
    }
    let handler = SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), dev: true, machineV2Hub: hub)
    let key = Curve25519.Signing.PrivateKey()
    let enrolled = try await space.enrollMachineV2(name: "racer", group: .shared, pubkey: key.pubkeyLabel)
    let machine = enrolled.machine
    let revoke = try await signed(handler, "/v1/machine-v2/\(machine.id.rawValue)/revoke", key: key, machine: machine.id)
    let inFlight = Task { try await handler(revoke) }
    for await _ in parked.stream { break }
    _ = try await space.resetCredentials(account: machine.account)
    let replacement = Curve25519.Signing.PrivateKey()
    _ = try await space.addKey(replacement.pubkeyLabel, account: machine.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    resume.continuation.yield()
    guard case let .response(stale) = try await inFlight.value else { Issue.record("revoke should be HTTP"); return }
    #expect(stale.status == .unauthorized)
    #expect(try await space.machine(pubkey: replacement.pubkeyLabel) == machine.id)
  }
}
