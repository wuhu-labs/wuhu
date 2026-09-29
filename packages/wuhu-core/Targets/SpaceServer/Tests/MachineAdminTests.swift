import Clocks
import ControlledTime
import Crypto
import Dependencies
import Fetch
import Foundation
import JSONValue
import MachineContract
import Serve
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct MachineAdminTests {
  @Test func enrollRotateRevokeVerifyRoundTrip() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())

    let response = try await server.http(.post, "/v1/machine", json: .object(["name": .string("box")]))
    #expect(response.status == .ok)
    let added = try await response.json(MachineAddOutput.self)
    #expect(MachineID.isValid(added.id.rawValue))
    #expect(added.token.hasPrefix("jt_"))

    let key = try await enrollMachineKey(server, token: added.token)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == added.id)

    let record = try #require(try await space.machine(added.id))
    let enrolled = try #require(try await space.keys(account: record.account).first)
    #expect(enrolled.capabilities == [.execMachine])

    let replayed = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string(testPubkey("thief")),
    ]))
    #expect(replayed.status == .unauthorized)

    let rotate = try await server.http(.post, "/v1/machine/\(added.id.rawValue)/rotate")
    #expect(rotate.status == .ok)
    let rotated = try await rotate.json(MachineRotateOutput.self).token
    #expect(rotated != added.token)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
    let nextKey = try await enrollMachineKey(server, token: rotated)
    #expect(try await space.machine(pubkey: nextKey.pubkeyLabel) == added.id)

    let revoke = try await server.http(.post, "/v1/machine/\(added.id.rawValue)/revoke")
    #expect(revoke.status == .ok)
    #expect(try await space.machine(pubkey: nextKey.pubkeyLabel) == nil)

    let reissued = try await server.http(.post, "/v1/machine/\(added.id.rawValue)/rotate")
    let reissuedKey = try await enrollMachineKey(server, token: try await reissued.json(MachineRotateOutput.self).token)
    #expect(try await space.machine(pubkey: reissuedKey.pubkeyLabel) == added.id)

    #expect(try await server.http(.post, "/v1/machine/mc_zzzzzzzz/rotate").status == .notFound)
  }

  @Test func rotateKillsTheOutstandingJoinToken() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let added = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    _ = try await server.http(.post, "/v1/machine/\(added.id.rawValue)/rotate")
    let stale = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string(testPubkey("late")),
    ]))
    #expect(stale.status == .unauthorized)
  }

  @Test func signatureGateRefusesBeforeAnyFrame() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)

    guard case let .refused(missing) = try await server.openWebSocket("/v1/machine/connect") else {
      Issue.record("absent handshake must refuse the upgrade")
      return
    }
    #expect(missing.status == .unauthorized)

    var forged = try await connectHeaders(server, key: key)
    let stranger = Curve25519.Signing.PrivateKey()
    forged[0] = (MachineConnect.pubkeyHeader, stranger.pubkeyLabel)
    guard case let .refused(badSignature) = try await server.openWebSocket("/v1/machine/connect", headers: forged) else {
      Issue.record("a signature that does not verify against the presented pubkey must refuse the upgrade")
      return
    }
    #expect(badSignature.status == .unauthorized)

    let headers = try await connectHeaders(server, key: key)
    let socket = try await server.requireSocket("/v1/machine/connect", headers: headers)
    socket.close()
    guard case let .refused(replay) = try await server.openWebSocket("/v1/machine/connect", headers: headers) else {
      Issue.record("a challenge is one-shot; a captured handshake must not replay")
      return
    }
    #expect(replay.status == .unauthorized)

    let account = try await space.addAccount(kind: .human, name: nil)
    let deviceKey = Curve25519.Signing.PrivateKey()
    _ = try await space.addKey(deviceKey.pubkeyLabel, account: account.id, capabilities: [.device, .seat], createdBy: nil, expiresAt: nil)
    guard case let .refused(userKey) = try await server.openWebSocket(
      "/v1/machine/connect",
      headers: try await connectHeaders(server, key: deviceKey),
    ) else {
      Issue.record("a user key is not a machine key even on the same space")
      return
    }
    #expect(userKey.status == .unauthorized)

    _ = try await server.http(.post, "/v1/machine/\(id.rawValue)/revoke")
    guard case let .refused(revoked) = try await server.openWebSocket(
      "/v1/machine/connect",
      headers: try await connectHeaders(server, key: key),
    ) else {
      Issue.record("a revoked key must refuse the upgrade")
      return
    }
    #expect(revoked.status == .unauthorized)
  }

  @Test func aP256MachineKeyConnectsAndCrossCurveSignaturesAreRefused() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let added = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    let key = P256.Signing.PrivateKey()
    let consumed = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string(key.pubkeyLabel),
    ]))
    #expect(consumed.status == .ok)

    func challenge() async throws -> String {
      try await (try await server.http(.get, "/v1/machine/challenge")).json(MachineChallengeOutput.self).challenge
    }
    func headers(challenge: String, signature: Data) -> [(String, String)] {
      [
        (MachineConnect.pubkeyHeader, key.pubkeyLabel),
        (MachineConnect.challengeHeader, challenge),
        (MachineConnect.signatureHeader, signature.base64EncodedString()),
      ]
    }

    let fresh = try await challenge()
    let rawECDSA = try key.signature(for: MachineConnect.signingPayload(challenge: fresh)).rawRepresentation
    let socket = try await server.requireSocket("/v1/machine/connect", headers: headers(challenge: fresh, signature: rawECDSA))
    socket.close()

    let forEd25519 = try await challenge()
    let ed25519Signature = try Curve25519.Signing.PrivateKey().signature(for: MachineConnect.signingPayload(challenge: forEd25519))
    guard case let .refused(crossCurve) = try await server.openWebSocket(
      "/v1/machine/connect",
      headers: headers(challenge: forEd25519, signature: ed25519Signature),
    ) else {
      Issue.record("an ed25519 signature presented under a p256 label must refuse the upgrade")
      return
    }
    #expect(crossCurve.status == .unauthorized)

    let forDER = try await challenge()
    let der = try key.signature(for: MachineConnect.signingPayload(challenge: forDER)).derRepresentation
    guard case let .refused(derRefused) = try await server.openWebSocket(
      "/v1/machine/connect",
      headers: headers(challenge: forDER, signature: der),
    ) else {
      Issue.record("a DER-encoded ECDSA signature must refuse the upgrade; the wire format is raw r||s")
      return
    }
    #expect(derRefused.status == .unauthorized)
  }

  @Test func staleChallengeRefusesTheDial() async throws {
    let anchor = Date(timeIntervalSinceReferenceDate: 0)
    let (server, time) = try withDependencies {
      $0.installTimeControl()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 7))
    } operation: { () throws -> (TestServer, TimeControl) in
      @Dependency(\.timeControl) var timeControl
      let space = try Space.inMemory()
      return (TestServer(space: space, clock: ContinuousClock()), timeControl)
    }
    let (_, key) = try await addMachine(server)

    let stale = try await connectHeaders(server, key: key)
    await time.advance(to: anchor.addingTimeInterval(61))
    guard case let .refused(expired) = try await server.openWebSocket("/v1/machine/connect", headers: stale) else {
      Issue.record("a challenge older than its 60s lifetime must refuse the upgrade")
      return
    }
    #expect(expired.status == .unauthorized)

    let boundary = try await connectHeaders(server, key: key)
    await time.advance(to: anchor.addingTimeInterval(121))
    guard case let .refused(dead) = try await server.openWebSocket("/v1/machine/connect", headers: boundary) else {
      Issue.record("a challenge at exactly its expiry is dead, matching isLive")
      return
    }
    #expect(dead.status == .unauthorized)

    let fresh = try await connectHeaders(server, key: key)
    await time.advance(to: anchor.addingTimeInterval(180))
    let socket = try await server.requireSocket("/v1/machine/connect", headers: fresh)
    socket.close()
  }

  // A junk pubkey dies at enrollment, so no junk key row is ever reachable;
  // the rejected attempt leaves the machine's join token alive for a retry.
  @Test func junkPubkeyCannotEnrollForAMachine() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let added = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    let rejected = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string("ed25519:!!!not-a-key!!!"),
    ]))
    #expect(rejected.status == .badRequest)
    let record = try #require(try await space.machine(added.id))
    #expect(try await space.keys(account: record.account) == [])
    let retried = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string(testPubkey("box")),
    ]))
    #expect(retried.status == .ok)
  }

  @Test func revokeKicksTheLiveConnection() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)

    await withTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        do {
          let socket = try await connectMachine(server, key: key)
          _ = try await realPollUntil { await server.hub.attachedMachines().contains(id) }
          _ = try await server.http(.post, "/v1/machine/\(id.rawValue)/revoke")
          _ = try await realPollUntil { await !server.hub.attachedMachines().contains(id) }
          #expect(await !server.hub.attachedMachines().contains(id))
          // The kicked socket is closed server-side; its inbound stream ends.
          for await _ in socket.inbound {}
        } catch {
          Issue.record("revoke kick flow failed: \(error)")
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  @Test func rotateKicksTheLiveConnection() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)

    await withTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        do {
          _ = try await connectMachine(server, key: key)
          _ = try await realPollUntil { await server.hub.attachedMachines().contains(id) }
          let rotate = try await server.http(.post, "/v1/machine/\(id.rawValue)/rotate")
          _ = try await realPollUntil { await !server.hub.attachedMachines().contains(id) }
          #expect(await !server.hub.attachedMachines().contains(id))
          let nextKey = try await enrollMachineKey(server, token: try await rotate.json(MachineRotateOutput.self).token)
          let rejoined = try await connectMachine(server, key: nextKey)
          _ = try await realPollUntil { await server.hub.attachedMachines().contains(id) }
          #expect(await server.hub.attachedMachines().contains(id))
          rejoined.close()
        } catch {
          Issue.record("rotate kick flow failed: \(error)")
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  // Revocation must drop a live connection even when it bypasses the machine
  // routes (a raw key removal): the hub's watchdog re-checks the live key row
  // on the hub clock and severs the leg when it stops resolving.
  @Test func watchdogSeversWhenTheKeyRowDies() async throws {
    let space = try makeMachineSpace()
    let clock = TestClock<Duration>()
    let server = TestServer(space: space, clock: clock)
    let (id, key) = try await addMachine(server)

    await withTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        do {
          _ = try await connectMachine(server, key: key)
          _ = try await realPollUntil { await server.hub.attachedMachines().contains(id) }

          await clock.advance(by: .seconds(30))
          _ = try await realPollUntil { await server.hub.attachedMachines().contains(id) }
          #expect(await server.hub.attachedMachines().contains(id))

          try await space.removeKey(pubkey: key.pubkeyLabel)
          // A single advance races the watchdog's re-entry into sleep: an
          // advance nobody is suspended on is simply lost. Advance per poll
          // instead, so the recheck fires whenever the loop gets there.
          _ = try await realPollUntil {
            await clock.advance(by: .seconds(30))
            return await !server.hub.attachedMachines().contains(id)
          }
          #expect(await !server.hub.attachedMachines().contains(id))
        } catch {
          Issue.record("watchdog flow failed: \(error)")
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  @Test func machineListReportsAttachment() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (id, key) = try await addMachine(server)

    let before = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
    #expect(before == [MachineStatus(id: id, name: "box", attached: false)])

    await withTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        do {
          let socket = try await connectMachine(server, key: key)
          _ = try await realPollUntil {
            try await server.http(.get, "/v1/machine").json([MachineStatus].self).allSatisfy(\.attached)
          }
          let attached = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
          #expect(attached == [MachineStatus(id: id, name: "box", attached: true)])
          socket.close()
          _ = try await realPollUntil {
            try await server.http(.get, "/v1/machine").json([MachineStatus].self).allSatisfy { !$0.attached }
          }
          let detached = try await server.http(.get, "/v1/machine").json([MachineStatus].self)
          #expect(detached == [MachineStatus(id: id, name: "box", attached: false)])
        } catch {
          Issue.record("attachment flow failed: \(error)")
        }
      }
      _ = await group.next()
      group.cancelAll()
    }
  }

  @Test func everyMachineRouteAcceptsTheNameInPlaceOfTheID() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let added = try await (try await server.http(.post, "/v1/machine", json: .object(["name": .string("Mini")])))
      .json(MachineAddOutput.self)
    #expect(try await space.machine(added.id)?.name == "mini")

    let renamed = try await server.http(.put, "/v1/machine/mini/name", json: .object(["name": .string("Studio")]))
    #expect(renamed.status == .ok)
    #expect(try await renamed.json(MachineStatus.self) == MachineStatus(id: added.id, name: "studio", attached: false))

    #expect(try await server.http(.post, "/v1/machine/mini/rotate").status == .notFound)
    #expect(try await server.http(.post, "/v1/machine/studio/rotate").status == .ok)

    let junk = try await server.http(.put, "/v1/machine/studio/name", json: .object(["name": .string("my box")]))
    #expect(junk.status == .badRequest)
    let second = try await (try await server.http(.post, "/v1/machine", json: .object(["name": .string("laptop")])))
      .json(MachineAddOutput.self)
    let clash = try await server.http(.put, "/v1/machine/\(second.id.rawValue)/name", json: .object(["name": .string("STUDIO")]))
    #expect(clash.status == .conflict)

    let duplicate = try await server.http(.post, "/v1/machine", json: .object(["name": .string("Studio")]))
    #expect(duplicate.status == .conflict)
  }

  @Test func joiningClaimsTheHostnameAndSuffixesACollision() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())

    let first = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    let joined = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(first.token), "pubkey": .string(testPubkey("box-a")), "name": .string("Mini.local"),
    ]))
    #expect(try await joined.json(EnrollConsumeOutput.self).machineName == "mini.local")

    let second = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    let collided = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(second.token), "pubkey": .string(testPubkey("box-b")), "name": .string("mini.local"),
    ]))
    #expect(try await collided.json(EnrollConsumeOutput.self).machineName == "mini.local-2")

    let third = try await (try await server.http(.post, "/v1/machine")).json(MachineAddOutput.self)
    let unnamed = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(third.token), "pubkey": .string(testPubkey("box-c")),
    ]))
    #expect(try await unnamed.json(EnrollConsumeOutput.self).machineName == nil)
  }

  @Test func joiningNeverRenamesAMachineThatAlreadyHasAName() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())

    let added = try await (try await server.http(.post, "/v1/machine", json: .object(["name": .string("studio")])))
      .json(MachineAddOutput.self)
    let joined = try await server.http(.post, "/v1/enroll/consume", json: .object([
      "token": .string(added.token), "pubkey": .string(testPubkey("box-a")), "name": .string("some-laptop"),
    ]))
    #expect(try await joined.json(EnrollConsumeOutput.self).machineName == "studio")
    #expect(try await space.machine(added.id)?.name == "studio")
    #expect(try await space.machine(named: "some-laptop") == nil)
  }

  @Test func nonDevGateStillAdmitsChallengeAndConnect() async throws {
    let space = try makeMachineSpace()
    let devServer = TestServer(space: space, clock: ContinuousClock())
    let (_, key) = try await addMachine(devServer)

    let walled = TestServer(space: space, clock: ContinuousClock(), dev: false)

    let denied = try await walled.http(.post, "/v1/machine")
    #expect(denied.status == .unauthorized)

    let headers = try await connectHeaders(walled, key: key)
    guard case .socket = try await walled.openWebSocket("/v1/machine/connect", headers: headers) else {
      Issue.record("a valid signature handshake is the connect route's own credential")
      return
    }
  }
}
