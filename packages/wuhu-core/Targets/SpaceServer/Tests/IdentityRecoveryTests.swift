import Clocks
import Dependencies
import Fetch
import Foundation
import JSONValue
import Logging
import ServeTesting
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.dependency(\.continuousClock, ContinuousClock())) struct IdentityRecoveryTests {
  @Test(arguments: ["unavailable", "rateLimited", "transport", "unconfirmed", "invalidID"])
  func failedFreshRegistrationPreservesSavedIssuerAndMinting(failure: String) async throws {
    let rig = try await RotationRig(directory: true)
    let issuer = try await rig.controller.issuerFor(URL(string: "https://verifier.test")!)
    let fetch = FetchClient { request in
      if request.method == .put { return try Response.json(["confirmed": true]) }
      switch failure {
      case "rateLimited": return Response(status: .tooManyRequests)
      case "transport": throw IdentityError.directoryUnavailable
      case "unconfirmed": return try Response.json(["confirmed": false], status: .created)
      case "invalidID": return try Response.json(JSONValue.object(["id": "bad", "issuer": "https://id.wuhu.ai/bad", "confirmed": true]), status: .created)
      default: return Response(status: .serviceUnavailable)
      }
    }
    let controller = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .filesystem(rig.fs), fetch: fetch)
    let before = await controller.settings
    let tokenBefore = try await rig.tokenKid(controller)
    await #expect(throws: IdentityError.directoryUnavailable) { try await controller.registerNew() }
    #expect(await controller.settings == before)
    #expect(await controller.directoryConfirmed)
    #expect(try await rig.tokenKid(controller) == tokenBefore)
    #expect(try await controller.snapshot().object?["publicationFailure"] == .null)
    try await controller.maintain()
    let reopened = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .filesystem(rig.fs), fetch: fetch)
    #expect(await reopened.settings == before)
    let token = try await reopened.token(audience: URL(string: "https://verifier.test")!, space: "s", group: "g", now: rig.epoch, id: UUID(0))
    #expect(try rotationJSON(String(token.split(separator: ".")[1])).object?["iss"] == .string(issuer))
  }

  @Test func registrationTimeoutPreservesConfirmedIssuer() async throws {
    let rig = try await RotationRig(directory: true)
    let clock = TestClock<Duration>()
    let entered = Gate()
    let fetch = FetchClient { request in
      if request.method == .put { return try Response.json(["confirmed": true]) }
      entered.open()
      try await clock.sleep(for: .seconds(60))
      return Response(status: .serviceUnavailable)
    }
    let controller = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .filesystem(rig.fs), fetch: fetch)
    let before = await controller.settings
    await withDependencies { $0.continuousClock = clock } operation: {
      await withTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
          await #expect(throws: IdentityError.directoryUnavailable) { try await controller.registerNew() }
        }
        await entered.wait()
        await clock.run()
        await tasks.waitForAll()
      }
    }
    #expect(await controller.settings == before)
    #expect(await controller.directoryConfirmed)
    #expect(try await rig.tokenKid(controller) == rig.key.kid)
  }

  @Test func confirmedRegistrationWithFailedSaveKeepsOldIssuerAcrossRestartAndExplicitRetry() async throws {
    let rig = try await RotationRig(directory: true)
    let oldSettings = await rig.controller.settings
    let fail = Mutex(false)
    let store = IdentityStateStore.filesystem(rig.fs)
    let failingStore = IdentityStateStore(load: store.load, save: { data in
      if fail.withLock({ $0 }) { throw IdentityError.keyUnavailable }
      try await store.save(data)
    })
    let registrations = Mutex(0)
    let targets = Mutex<[String]>([])
    let fetch = FetchClient { request in
      targets.withLock { $0.append(request.url.absoluteString) }
      if request.method == .put { return try Response.json(["confirmed": true]) }
      let id = registrations.withLock { count in
        count += 1
        return String(repeating: count == 1 ? "n" : "m", count: 32)
      }
      return try Response.json(JSONValue.object(["id": .string(id), "issuer": .string("https://id.wuhu.ai/" + id), "confirmed": true]), status: .created)
    }
    let controller = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: fetch)
    fail.withLock { $0 = true }
    await #expect(throws: IdentityError.directoryUnavailable) { try await controller.registerNew() }
    #expect(await controller.settings == oldSettings)
    #expect(await controller.directoryConfirmed)
    #expect(try await rig.tokenKid(controller) == rig.key.kid)
    let reopened = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: fetch)
    #expect(await reopened.settings == oldSettings)
    #expect(registrations.withLock { $0 } == 1)
    #expect(targets.withLock { $0.last } == "https://id.wuhu.ai/" + oldSettings.directoryID! + "/keys")
    fail.withLock { $0 = false }
    try await reopened.registerNew()
    let newID = String(repeating: "m", count: 32)
    #expect(await reopened.settings.directoryID == newID)
    let again = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: fetch)
    #expect(await again.settings.directoryID == newID)
    #expect(targets.withLock { $0.last } == "https://id.wuhu.ai/" + newID + "/keys")
    #expect(try await again.issuerFor(URL(string: "https://verifier.test")!) == "https://id.wuhu.ai/" + newID)
    #expect(registrations.withLock { $0 } == 2)
  }

  @Test func freshRegistrationRequiresDirectorySelectionOrExistingID() async throws {
    let rig = try await RotationRig(directory: false)
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://private.test", dev: true, webApp: nil, identityController: rig.controller))
    let response = try await api(Request(url: URL(string: "https://private.test/v1/identity/register-new")!, method: .post))
    #expect(response.status == .unprocessableContent)
    #expect(try await response.json(JSONValue.self).object?["code"] == "directoryNotSelected")
    #expect(await rig.controller.settings.directoryID == nil)
    #expect(rig.remote.withLock { $0.effects.isEmpty })
    try await rig.controller.set(audience: "https://verifier.test", choice: .directory)
    try await rig.controller.registerNew()
    #expect(await rig.controller.settings.defaultIssuer == .self)
    #expect(rig.remote.withLock { $0.effects.map(\.method) } == [.post, .post])
    try await rig.controller.set(audience: "https://verifier.test", choice: nil)
    try await rig.controller.registerNew()
    #expect(rig.remote.withLock { $0.effects.last?.method } == .post)
  }

  @Test(arguments: [false, true]) func pendingRotationRefusesFreshRegistration(directory: Bool) async throws {
    let rig = try await RotationRig(directory: directory)
    try await rig.at(0) { try await rig.controller.rotate() }
    let before = await rig.controller.settings
    let effects = rig.remote.withLock { $0.effects.count }
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://private.test", dev: true, webApp: nil, identityController: rig.controller))
    let response = try await api(Request(url: URL(string: "https://private.test/v1/identity/register-new")!, method: .post))
    #expect(response.status == .conflict)
    #expect(try await response.json(JSONValue.self).object?["code"] == "identityBusy")
    #expect(await rig.controller.settings == before)
    #expect(rig.remote.withLock { $0.effects.count } == effects)
  }

  @Test func transientPublicationFailureDuringRotationStillRefusesFreshRegistration() async throws {
    let rig = try await RotationRig(directory: true)
    rig.remote.withLock { $0.reject = true }
    await #expect(throws: IdentityError.directoryUnavailable) { try await rig.at(90 * 86400) { try await rig.controller.maintain() } }
    let before = await rig.controller.settings
    let effects = rig.remote.withLock { $0.effects.count }
    await #expect(throws: IdentityError.mutationInProgress) { try await rig.controller.registerNew() }
    #expect(await rig.controller.settings == before)
    #expect(rig.remote.withLock { $0.effects.count } == effects)
  }

  @Test(arguments: [IdentityError.unknownId, .unlistedKey])
  func lostOwnershipDuringAutomaticRotationCanRecoverAndKeepOverlapAcrossRestart(failure: IdentityError) async throws {
    let rig = try await RotationRig(directory: true)
    let lost = Mutex(false)
    let newID = String(repeating: "n", count: 32)
    let fetch = FetchClient { request in
      if request.method == .put, lost.withLock({ $0 }) {
        return try Response.json(["code": failure.directoryCode!], status: .forbidden)
      }
      let response = try await rig.fetch(request)
      if request.method == .post {
        lost.withLock { $0 = false }
        return try Response.json(JSONValue.object(["id": .string(newID), "issuer": .string("https://id.wuhu.ai/" + newID), "confirmed": true]), status: .created)
      }
      return response
    }
    let store = IdentityStateStore.filesystem(rig.fs)
    let controller = try await rig.at(0) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: store, fetch: fetch)
    }
    lost.withLock { $0 = true }
    let dayZero = 90 * 86400
    await #expect(throws: failure) { try await rig.at(dayZero) { try await controller.maintain() } }
    let staged = await controller.settings.keySchedule!
    let both = await controller.jwks
    #expect(staged.nextKey != nil)
    #expect(staged.overlapBeganAt == nil)
    #expect(both.object?["keys"]?.array?.count == 2)
    #expect(rig.remote.withLock { $0.keys.object?["keys"]?.array?.count } == 1)
    let blocked = try await rig.at(dayZero) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: store, fetch: fetch)
    }
    #expect(await blocked.settings.keySchedule == staged)
    #expect(try await blocked.snapshot().object?["publicationFailure"] == .string(failure.directoryCode!))
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://private.test", dev: true, webApp: nil, identityController: blocked))
    let response = try await rig.at(dayZero) {
      try await api(Request(url: URL(string: "https://private.test/v1/identity/register-new")!, method: .post))
    }
    #expect(response.status == .ok)
    #expect(await blocked.settings.directoryID == newID)
    #expect(await blocked.settings.keySchedule == staged)
    #expect(await blocked.directoryConfirmed)
    #expect(rig.remote.withLock { $0.keys } == both)
    #expect(rig.remote.withLock { $0.effects.last?.signer } == rig.key.kid)
    #expect(try await rig.tokenKid(blocked) == rig.key.kid)
    let resumed = try await rig.at(dayZero + 1) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: store, fetch: fetch)
    }
    #expect(await resumed.settings.directoryID == newID)
    #expect(await resumed.settings.keySchedule?.nextKey == staged.nextKey)
    #expect(await resumed.settings.keySchedule?.overlapBeganAt == rig.epoch.addingTimeInterval(Double(dayZero + 1)))
    await #expect(throws: IdentityError.mutationInProgress) { try await resumed.registerNew() }
    try await rig.at(dayZero + 86400) { try await resumed.maintain() }
    #expect(try await rig.tokenKid(resumed) == rig.key.kid)
    #expect(await resumed.jwks == both)
    try await rig.at(dayZero + 86401) { try await resumed.maintain() }
    let newKid = try await rig.tokenKid(resumed)
    #expect(newKid != rig.key.kid)
    #expect(rig.remote.withLock { $0.keys } == both)
    let switched = try await rig.at(dayZero + 86402) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: store, fetch: fetch)
    }
    #expect(try await rig.tokenKid(switched) == newKid)
    #expect(await switched.jwks == both)
    try await rig.at(dayZero + 172_800) { try await switched.maintain() }
    #expect(await switched.jwks == both)
    try await rig.at(dayZero + 172_801) { try await switched.maintain() }
    #expect(await switched.jwks.object?["keys"]?.array?.count == 1)
    #expect(await switched.jwks == rig.remote.withLock { $0.keys })
    #expect(await switched.settings.directoryID == newID)
    #expect(try await rig.tokenKid(switched) == newKid)
  }

  @Test(arguments: [IdentityError.unknownId, .unlistedKey, .directoryUnavailable])
  func publicationFailureIsVisibleAndLogsOnlyCode(failure: IdentityError) async throws {
    let rig = try await RotationRig(directory: true)
    let logs = IdentityLogs()
    let reject = Mutex(true)
    let controller = try IdentityController(identity: rig.key, origin: "https://private.test", settings: await rig.controller.settings, store: .filesystem(rig.fs), fetch: FetchClient { _ in
      if reject.withLock({ $0 }) { return try Response.json(["code": failure.directoryCode!], status: .forbidden) }
      return try Response.json(["confirmed": true])
    }, logger: logs.logger)
    await #expect(throws: failure) { try await controller.publish() }
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://private.test", dev: true, webApp: nil, identityController: controller))
    let response = try await api(Request(url: URL(string: "https://private.test/v1/identity")!))
    #expect(response.status == .ok)
    let snapshot = try await response.json(JSONValue.self)
    #expect(snapshot.object?["publicationFailure"] == .string(failure.directoryCode!))
    #expect(snapshot.object?.keys.sorted() == ["defaultIssuer", "overrides", "publicationFailure"])
    await #expect(throws: failure) { try await controller.maintain() }
    await #expect(throws: failure) { try await controller.registerNew() }
    #expect(try await controller.snapshot() == snapshot)
    #expect(logs.entries.withLock { $0.count } == 3)
    #expect(logs.entries.withLock { $0.allSatisfy { $0.0 == "identity publication failed" && $0.1 == ["code": .string(failure.directoryCode!)] } })
    reject.withLock { $0 = false }
    try await controller.maintain()
    #expect(try await controller.snapshot().object?["publicationFailure"] == .null)
  }
}

private final class IdentityLogs: Sendable {
  let entries = Mutex<[(String, Logger.Metadata)]>([])
  var logger: Logger { Logger(label: "test") { _ in Handler(sink: self) } }

  private struct Handler: LogHandler {
    let sink: IdentityLogs
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
      sink.entries.withLock { $0.append((event.message.description, event.metadata ?? [:])) }
    }
  }
}
