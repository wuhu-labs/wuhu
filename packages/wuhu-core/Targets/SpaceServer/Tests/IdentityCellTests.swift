import ControlledTime
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import GRDB
import JSONValue
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct IdentityCellTests {
  private func controlled(_ body: (TimeControl) async throws -> Void) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.timeControl) var time
      try await body(time)
    }
  }

  @Test func scheduleAndProofUseTheRuntimeClockNotTheConfigurationClock() async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      _ = space.worker
      let controller = withDependencies {
        $0.date = .constant(fixedDate.addingTimeInterval(100 * 86400))
      } operation: {
        IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { request in
          let proof = try #require(try await request.body?.text())
          let claims = try #require(JSONValue.parse(String(decoding: identityJWTData(String(proof.split(separator: ".")[1])), as: UTF8.self))?.object)
          #expect(claims["iat"]?.intValue == Int(fixedDate.timeIntervalSince1970))
          return try Response.json(["confirmed": true])
        })
      }
      try await controller.initialize(identity: ServerIdentity.generate(), settings: .init(defaultIssuer: .directory, directoryID: String(repeating: "c", count: 32)))
      space.worker.start()
      try await identitySettles(controller) { controller.state!.confirmed }
      #expect(!controller.state!.rotating)
      #expect(controller.state!.pending == nil)
      let nextWake = space.worker.cell(IdentityController.cellID).nextWake()!
      #expect(nextWake.milliseconds == Int64(fixedDate.addingTimeInterval(90 * 86400).timeIntervalSince1970 * 1000))
      try await space.close()
    }
  }

  @Test func anImportedScheduleKeepsItsKnownAge() async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      let controller = IdentityController.configure(space: space, origin: nil, keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in Response(status: .forbidden) })
      let key = try ServerIdentity.generate()
      let rotatedAt = fixedDate.addingTimeInterval(-86400)
      try await controller.initialize(identity: key, settings: .init(keySchedule: .init(currentKey: key.rawKey, rotatedAt: rotatedAt)))
      #expect(controller.state!.schedule.rotatedAt == rotatedAt)
      #expect(space.worker.cell(IdentityController.cellID).nextWake()?.milliseconds == Int64(rotatedAt.addingTimeInterval(90 * 86400).timeIntervalSince1970 * 1000))
      try await space.close()
    }
  }

  @Test func rotationAndPublicationSurviveAnOverlappingWorker() async throws {
    try await controlled { time in
      let folder = try ScratchFolder("identity-rollover")
      let file = folder.url.appendingPathComponent("space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      do {
        let keys = MemoryFiles().identityKeys
        let calls = Mutex(0)
        let blocked = AsyncStream<Void>.makeStream()
        let requests = AsyncStream<Int>.makeStream()
        let published = Mutex<[Publication]>([])
        let fetch = FetchClient { request in
          let publication = try await readPublication(request)
          published.withLock { $0.append(publication) }
          let call = calls.withLock { $0 += 1; return $0 }
          requests.continuation.yield(call)
          if call == 2 {
            for await _ in blocked.stream {}
            try Task.checkCancellation()
          }
          return try Response.json(["confirmed": true])
        }
        let first = IdentityController.configure(space: old, origin: "https://space.test", keys: keys, fetch: fetch)
        let second = IdentityController.configure(space: new, origin: "https://space.test", keys: keys, fetch: fetch)
        let key = try ServerIdentity.generate()
        try await first.initialize(identity: key, settings: .init(defaultIssuer: .directory, overrides: ["https://local.test": .self], directoryID: String(repeating: "a", count: 32)))
        old.worker.start()
        try await identitySettles(first) { first.state!.confirmed }
        let initial = first.state!.schedule.signer
        let accepted = try await first.rotate()
        #expect(accepted.object?["rotating"] == true)
        for await call in requests.stream where call == 2 { break }
        #expect(first.state!.schedule.next != nil)
        new.worker.start()
        #expect(second.state!.schedule.signer == initial)
        #expect(try await tokenKid(second, selfAudience: true) == initial)
        await old.stopWorker()
        try await time.wake("replacement worker scan", after: 1)
        try await identitySettles(second) { second.state!.confirmed && second.state!.schedule.overlapBeganAt != nil }
        #expect(calls.withLock { $0 } == 3)
        #expect(second.state!.pending == nil)
        #expect(try await tokenKid(second) == initial)
        let next = second.state!.schedule.next!
        try await identityWake(second, in: time)
        try await identitySettles(second) { second.state!.schedule.switchedAt != nil }
        #expect(try await tokenKid(second) == next)
        #expect(try await second.jwks.object?["keys"]?.array?.count == 2)
        try await identityWake(second, in: time)
        try await identitySettles(second) { second.state!.schedule.next == nil && second.state!.confirmed }
        #expect(calls.withLock { $0 } == 4)
        let proofs = published.withLock { $0 }
        #expect(proofs.map(\.signer) == [initial, initial, initial, next])
        #expect(proofs.map(\.kids) == [[initial], [initial, next], [initial, next], [next]])
        #expect(proofs.allSatisfy { $0.target == IdentityController.directoryOrigin + "/" + String(repeating: "a", count: 32) + "/keys" && $0.method == "PUT" })
        #expect(second.state!.schedule.current == next)
        #expect(try await second.jwks.object?["keys"]?.array?.count == 1)
      } catch {
        try await old.close()
        try await new.close()
        throw error
      }
      try await old.close()
      try await new.close()
    }
  }

  @Test func automaticRotationAndDelayedSwitchKeepAFullDayOfOverlap() async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in Issue.record("self issuer must not publish"); return Response(status: .forbidden) })
      try await controller.initialize(identity: ServerIdentity.generate())
      space.worker.start()
      try await identityWake(controller, in: time)
      try await identitySettles(controller) { controller.state!.schedule.overlapBeganAt != nil }
      let old = controller.state!.schedule.current
      let next = controller.state!.schedule.next!
      #expect(try await tokenKid(controller) == old)
      await space.stopWorker()
      await time.advance(by: 3 * 86400)
      let reopened = IdentityController.configure(space: space, origin: "https://space.test", keys: controller.keys, fetch: FetchClient { _ in Response(status: .forbidden) })
      space.worker.start()
      try await time.wake("reopened worker scan", after: 1)
      try await identitySettles(reopened) { reopened.state!.schedule.switchedAt != nil }
      #expect(reopened.state!.schedule.next == next)
      #expect(try await tokenKid(reopened) == next)
      try await identityWake(reopened, in: time)
      try await identitySettles(reopened) { reopened.state!.schedule.next == nil }
      #expect(reopened.state!.schedule.current == next)
      try await space.close()
    }
  }

  @Test func directoryFailureIsDurableAndRetriedOnlyWhenDue() async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let calls = Mutex(0)
      let id = String(repeating: "d", count: 32)
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in
        let count = calls.withLock { $0 += 1; return $0 }
        if count == 1 { return try Response.json(["code": "unknownId"], status: .notFound) }
        return try Response.json(JSONValue.object(["confirmed": true, "id": .string(id), "issuer": .string(IdentityController.directoryOrigin + "/" + id)]), status: .created)
      })
      try await controller.initialize(identity: ServerIdentity.generate())
      space.worker.start()
      let snapshot = try await controller.set(defaultIssuer: .directory)
      #expect(snapshot.object?["defaultIssuer"] == .null)
      #expect(snapshot.object?["publicationFailure"] == .null)
      #expect(snapshot.object?["state"] == "publishing")
      try await identitySettles(controller) { controller.state!.failure == .unknownId }
      #expect(try controller.snapshot().object?["state"] == "failed")
      await #expect(throws: IdentityError.unknownId) { try await tokenKid(controller) }
      await time.advance(by: 59)
      #expect(calls.withLock { $0 } == 1)
      try await identityWake(controller, in: time)
      try await identitySettles(controller) { controller.state!.confirmed }
      #expect(calls.withLock { $0 } == 2)
      #expect(controller.state!.directoryID == id)
      #expect(try controller.issuerFor(URL(string: "https://backend.test")!) == IdentityController.directoryOrigin + "/" + id)
      try await space.close()
    }
  }

  @Test(arguments: [false, true]) func failedRecoveryKeepsTheOldIssuerUntilConfirmed(retryBySetting: Bool) async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let calls = Mutex(0)
      let oldID = String(repeating: "o", count: 32)
      let newID = String(repeating: "n", count: 32)
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { request in
        let call = calls.withLock { $0 += 1; return $0 }
        if request.method == .put { return try Response.json(["confirmed": true]) }
        if call == 2 { return try Response.json(["code": "unlistedKey"], status: .forbidden) }
        return try Response.json(JSONValue.object(["confirmed": true, "id": .string(newID), "issuer": .string(IdentityController.directoryOrigin + "/" + newID)]), status: .created)
      })
      try await controller.initialize(identity: ServerIdentity.generate(), settings: .init(defaultIssuer: .directory, directoryID: oldID))
      space.worker.start()
      try await identitySettles(controller) { controller.state!.confirmed }
      let accepted = try await controller.registerNew()
      #expect(accepted.object?["state"] == "publishing")
      #expect(accepted.object?["defaultIssuer"] == .string(IdentityController.directoryOrigin + "/" + oldID))
      try await identitySettles(controller) { controller.state!.failure == .unlistedKey }
      #expect(controller.state!.directoryID == oldID)
      #expect(controller.state!.confirmed)
      _ = try await tokenKid(controller)
      if retryBySetting { _ = try await controller.set(defaultIssuer: .directory) }
      else { try await identityWake(controller, in: time) }
      try await identitySettles(controller) { controller.state!.directoryID == newID }
      #expect(controller.state!.failure == nil)
      #expect(calls.withLock { $0 } == (retryBySetting ? 4 : 3))
      try await space.close()
    }
  }

  @Test(arguments: [false, true]) func disablingDirectoryDropsQueuedPublicationAndRecovery(recovery: Bool) async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let calls = Mutex(0)
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in
        calls.withLock { $0 += 1 }
        return try Response.json(["code": "unlistedKey"], status: .forbidden)
      })
      try await controller.initialize(identity: ServerIdentity.generate())
      space.worker.start()
      _ = try await controller.set(defaultIssuer: .directory)
      try await identitySettles(controller) { controller.state!.retry != nil }
      if recovery {
        _ = try await controller.registerNew()
        try await identitySettles(controller) { controller.state!.retry?.action == .register }
        #expect(controller.state!.registeringNew)
      }
      let retry = controller.state!.retry!.at
      let accepted = try await controller.set(defaultIssuer: .self)
      #expect(accepted.object?["publicationFailure"] == .null)
      #expect(controller.state!.retry == nil)
      #expect(!controller.state!.registeringNew)
      #expect(controller.state!.directoryID == nil)
      #expect(controller.space.worker.cell(IdentityController.cellID).nextWake()!.milliseconds > Int64(retry.timeIntervalSince1970 * 1000))
      await time.advance(to: retry.addingTimeInterval(1))
      _ = try await controller.set(defaultIssuer: .self)
      #expect(calls.withLock { $0 } == (recovery ? 2 : 1))
      #expect(controller.state!.directoryID == nil)
      try await space.close()
    }
  }

  @Test(arguments: [false, true]) func disablingDirectoryDiscardsAnInflightRegistration(fails: Bool) async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      let entered = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let newID = String(repeating: "d", count: 32)
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in
        entered.continuation.yield(())
        for await _ in release.stream { break }
        if fails { return Response(status: .serviceUnavailable) }
        return try Response.json(JSONValue.object(["confirmed": true, "id": .string(newID), "issuer": .string(IdentityController.directoryOrigin + "/" + newID)]), status: .created)
      })
      try await controller.initialize(identity: ServerIdentity.generate())
      space.worker.start()
      _ = try await controller.set(defaultIssuer: .directory)
      for await _ in entered.stream { break }
      _ = try await controller.set(defaultIssuer: .self)
      release.continuation.yield(())
      try await identitySettles(controller) { controller.state!.pending == nil }
      #expect(controller.state!.directoryID == nil)
      #expect(controller.state!.retry == nil)
      #expect(controller.state!.failure == nil)
      #expect(try controller.issuerFor(URL(string: "https://backend.test")!) == "https://space.test")
      try await space.close()
    }
  }

  @Test func registerNewRefusesWhilePublicationIsPending() async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      let entered = AsyncStream<Void>.makeStream()
      let blocked = AsyncStream<Void>.makeStream()
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in
        entered.continuation.yield(())
        for await _ in blocked.stream {}
        throw CancellationError()
      })
      try await controller.initialize(identity: ServerIdentity.generate(), settings: .init(defaultIssuer: .directory))
      space.worker.start()
      for await _ in entered.stream { break }
      await #expect(throws: IdentityError.busy) { try await controller.registerNew() }
      #expect(!controller.state!.registeringNew)
      try await space.close()
    }
  }

  @Test func registerNewRefusesDuringAConfirmedRotation() async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in try Response.json(["confirmed": true]) })
      let current = try ServerIdentity.generate()
      let next = try ServerIdentity.generate()
      try await controller.initialize(identity: current, settings: .init(defaultIssuer: .directory, directoryID: String(repeating: "b", count: 32), keySchedule: .init(currentKey: current.rawKey, rotatedAt: fixedDate, nextKey: next.rawKey, overlapBeganAt: fixedDate)))
      space.worker.start()
      try await identitySettles(controller) { controller.state!.confirmed }
      #expect(controller.state!.pending == nil)
      await #expect(throws: IdentityError.busy) { try await controller.registerNew() }
      #expect(controller.state!.schedule.next == next.kid)
      #expect(!controller.state!.registeringNew)
      try await space.close()
    }
  }

  @Test func registerNewRecoversBothKeysWithoutChangingRotationTimes() async throws {
    try await controlled { _ in
      let space = try Space.inMemory()
      let oldID = String(repeating: "o", count: 32)
      let newID = String(repeating: "n", count: 32)
      let publications = Mutex<[Publication]>([])
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { request in
        let publication = try await readPublication(request)
        publications.withLock { $0.append(publication) }
        if request.method == .put { return try Response.json(["code": "unlistedKey"], status: .forbidden) }
        return try Response.json(JSONValue.object(["confirmed": true, "id": .string(newID), "issuer": .string(IdentityController.directoryOrigin + "/" + newID)]), status: .created)
      })
      let current = try ServerIdentity.generate()
      let next = try ServerIdentity.generate()
      let overlap = fixedDate.addingTimeInterval(-3600)
      let settings = IdentitySettings(defaultIssuer: .directory, directoryID: oldID, keySchedule: .init(currentKey: current.rawKey, rotatedAt: fixedDate.addingTimeInterval(-90 * 86400), nextKey: next.rawKey, overlapBeganAt: overlap))
      try await controller.initialize(identity: current, settings: settings)
      space.worker.start()
      try await identitySettles(controller) { controller.state!.failure == .unlistedKey }
      let before = controller.state!.schedule
      _ = try await controller.registerNew()
      try await identitySettles(controller) { controller.state!.directoryID == newID }
      let after = controller.state!.schedule
      #expect(after.current == before.current && after.next == before.next)
      #expect(after.rotatedAt == before.rotatedAt && after.overlapBeganAt == before.overlapBeganAt && after.switchedAt == before.switchedAt)
      let proofs = publications.withLock { $0 }
      #expect(proofs.count == 2)
      #expect(proofs.allSatisfy { $0.kids == [current.kid, next.kid] && $0.signer == current.kid })
      #expect(proofs.last?.target == IdentityController.directoryOrigin + "/register")
      #expect(controller.state!.confirmed)
      try await space.close()
    }
  }

  @Test func directoryTimeoutIsARecordedFailureWithAWakeRetry() async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let blocked = AsyncStream<Void>.makeStream()
      let calls = Mutex(0)
      let id = String(repeating: "t", count: 32)
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in
        if calls.withLock({ $0 += 1; return $0 }) == 1 {
          for await _ in blocked.stream {}
          try Task.checkCancellation()
        }
        return try Response.json(JSONValue.object(["confirmed": true, "id": .string(id), "issuer": .string(IdentityController.directoryOrigin + "/" + id)]), status: .created)
      })
      try await controller.initialize(identity: ServerIdentity.generate())
      space.worker.start()
      _ = try await controller.set(defaultIssuer: .directory)
      try await time.wake("directory HTTP timeout", after: 15)
      try await identitySettles(controller) { controller.state!.failure == .directoryUnavailable }
      #expect(controller.state!.pending == nil)
      #expect(calls.withLock { $0 } == 1)
      try await identityWake(controller, in: time)
      try await identitySettles(controller) { controller.state!.confirmed }
      #expect(calls.withLock { $0 } == 2)
      try await space.close()
    }
  }

  @Test func keyFileFailureRetriesGenerationWithoutChangingTheSigner() async throws {
    try await controlled { time in
      let space = try Space.inMemory()
      let files = MemoryFiles().identityKeys
      let stores = Mutex(0)
      let keys = IdentityKeys(load: files.load, store: { key in
        if stores.withLock({ $0 += 1; return $0 }) == 2 { throw IdentityError.keyUnavailable }
        try await files.store(key)
      })
      let controller = IdentityController.configure(space: space, origin: "https://space.test", keys: keys, fetch: FetchClient { _ in try Response.json(["confirmed": true]) })
      let initial = try ServerIdentity.generate()
      try await controller.initialize(identity: initial, settings: .init(defaultIssuer: .directory, directoryID: String(repeating: "k", count: 32)))
      space.worker.start()
      try await identitySettles(controller) { controller.state!.confirmed }
      _ = try await controller.rotate()
      try await identitySettles(controller) { controller.state!.failure == .keyUnavailable }
      #expect(controller.state!.schedule.next == nil)
      #expect(controller.state!.confirmed)
      #expect(try await tokenKid(controller) == initial.kid)
      try await identityWake(controller, in: time)
      try await identitySettles(controller) { controller.state!.schedule.overlapBeganAt != nil }
      #expect(controller.state!.failure == nil)
      #expect(try await keys.load(controller.state!.schedule.next!).kid == controller.state!.schedule.next!)
      try await space.close()
    }
  }

  @Test func bootstrapImportsKeysOnceWithoutPuttingPrivateBytesInSQLite() async throws {
    try await controlled { _ in
      let folder = try ScratchFolder("identity-bootstrap")
      let directory = folder.url.appendingPathComponent("identity")
      let original = try await ServerIdentity.loadOrCreate(directory: directory)
      let current = try ServerIdentity.generate()
      let next = try ServerIdentity.generate()
      let settings = IdentitySettings(keySchedule: .init(currentKey: current.rawKey, rotatedAt: fixedDate, nextKey: next.rawKey, overlapBeganAt: fixedDate))
      let settingsFile = directory.appendingPathComponent("settings.json")
      let bytes = try JSONEncoder().encode(settings)
      try bytes.write(to: settingsFile)
      let file = folder.url.appendingPathComponent("space.sqlite")
      let space = try Space.open(file: file)
      let controller = try await IdentityController.load(space: space, origin: "https://space.test", directory: directory, fetch: FetchClient { _ in Response(status: .forbidden) })
      #expect(controller.state!.schedule.current == current.kid)
      #expect(controller.state!.schedule.next == next.kid)
      #expect(try await controller.keys.load(next.kid).rawKey == next.rawKey)
      #expect(try Data(contentsOf: settingsFile) == bytes)
      let row = try await DatabaseQueue(path: file.path).read { try String.fetchOne($0, sql: "SELECT state FROM server_identity")! }
      for key in [original, current, next] { #expect(!row.contains(key.rawKey.base64EncodedString())) }
      try await space.close()
      try Data("invalid settings".utf8).write(to: settingsFile)
      let reopened = try Space.open(file: file)
      let second = try await IdentityController.load(space: reopened, origin: "https://space.test", directory: directory, fetch: FetchClient { _ in Response(status: .forbidden) })
      #expect(second.state!.schedule.current == current.kid)
      #expect(try await tokenKid(second) == current.kid)
      try await reopened.close()
    }
  }

  @Test(arguments: ["https://example.test/path", "https://user@example.test", "https://*.test", "https://example.test:443", "https://EXAMPLE.test", "https://example.test/"])
  func invalidOverridesDoNotChangeTheRow(origin: String) async throws {
    let identity = try await testIdentity()
    await #expect(throws: IdentityError.invalidAudience) { try await identity.controller.set(audience: origin, choice: .directory) }
    #expect(identity.controller.state!.overrides.isEmpty)
    try await identity.controller.space.close()
  }
}

private func identitySettles(_ controller: IdentityController, _ condition: () async throws -> Bool) async throws {
  let writer = await controller.space.writer
  let changes = ValueObservation.tracking { db in
    try String.fetchOne(db, sql: "SELECT state FROM server_identity")
  }.values(in: writer, bufferingPolicy: .bufferingNewest(1))
  for try await _ in changes {
    if try await condition() { return }
  }
  preconditionFailure("identity observation ended before its space closed")
}

private func tokenKid(_ controller: IdentityController, selfAudience: Bool = false) async throws -> String {
  let audience = URL(string: selfAudience ? "https://local.test" : "https://backend.test")!
  let token = try await controller.token(audience: audience, space: "s", group: "g", now: fixedDate, id: UUID())
  let header = try identityJWTData(String(token.split(separator: ".")[0]))
  return try #require(JSONValue.parse(String(decoding: header, as: UTF8.self))?.object?["kid"]?.stringValue)
}

private extension TimeControl {
  func advance(by seconds: Double) async {
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds))
  }
}

private struct Publication: Sendable {
  let target: String
  let method: String
  let signer: String
  let kids: [String]
}

private func readPublication(_ request: Request) async throws -> Publication {
  let jwt = try #require(try await request.body?.text())
  let parts = jwt.split(separator: ".").map(String.init)
  let header = try #require(JSONValue.parse(String(decoding: identityJWTData(parts[0]), as: UTF8.self))?.object)
  let claims = try #require(JSONValue.parse(String(decoding: identityJWTData(parts[1]), as: UTF8.self))?.object)
  let signer = try #require(header["kid"]?.stringValue)
  let keys = try #require(claims["jwks"]?.object?["keys"]?.array)
  let jwk = try #require(keys.first { $0.object?["kid"] == .string(signer) }?.object)
  let point = Data([4]) + (try identityJWTData(#require(jwk["x"]?.stringValue))) + (try identityJWTData(#require(jwk["y"]?.stringValue)))
  let key = try P256.Signing.PublicKey(x963Representation: point)
  #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: identityJWTData(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
  #expect(header["alg"] == "ES256" && header["typ"] == "JWT")
  #expect(claims["aud"] == .string(request.url.absoluteString))
  #expect(try #require(claims["exp"]?.intValue) - #require(claims["iat"]?.intValue) == 300)
  #expect(claims["jti"]?.stringValue?.count == 32)
  #expect(request.body?.contentType == "application/jose")
  return Publication(target: request.url.absoluteString, method: request.method.rawValue, signer: signer, kids: try keys.map { try #require($0.object?["kid"]?.stringValue) })
}

private func identityJWTData(_ value: String) throws -> Data {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}

private func identityWake(_ controller: IdentityController, in time: TimeControl) async throws {
  let wake = controller.space.worker.cell(IdentityController.cellID).nextWake()!
  await time.advance(to: Date(timeIntervalSince1970: Double(wake.milliseconds) / 1000 + 0.002))
  // A day-sized jump can run idle eviction before the alarm; let the scan reclaim that cell.
  while controller.space.worker.cell(IdentityController.cellID).nextWake() == wake {
    try await time.asleep("identity runtime scan", dueIn: 1)
    if controller.space.worker.cell(IdentityController.cellID).nextWake() != wake { break }
    await time.advance(by: 1)
  }
}
