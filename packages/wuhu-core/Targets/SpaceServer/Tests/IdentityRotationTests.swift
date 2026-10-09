import Clocks
import Crypto
import Dependencies
import DependenciesTestSupport
import Fetch
import Foundation
import JSONValue
import NIOCore
import Scratch
@testable import SpaceServer
import Synchronization
import Testing
import WuhuVFS

@Suite(.dependency(\.continuousClock, ContinuousClock())) struct IdentityRotationTests {
  @Test(arguments: [false, true]) func overlapSwitchRetireAndRestart(directory: Bool) async throws {
    let rig = try await RotationRig(directory: directory)
    let oldKeys = await rig.controller.jwks
    try await rig.at(0) { try await rig.controller.rotate() }
    let both = await rig.controller.jwks
    #expect(both.object?["keys"]?.array?.count == 2)
    #expect(try await rig.tokenKid() == rig.key.kid)
    try await rig.at(86399) { try await rig.controller.maintain() }
    #expect(try await rig.tokenKid() == rig.key.kid)
    var controller = try await rig.at(86400) { try await rig.reopen() }
    #expect(await controller.jwks == both)
    let newKid = try await rig.tokenKid(controller)
    #expect(newKid != rig.key.kid)
    if directory { #expect(rig.remote.withLock { $0.keys } == both) }
    controller = try await rig.at(172_799) { try await rig.reopen() }
    #expect(await controller.jwks == both)
    controller = try await rig.at(172_800) { try await rig.reopen() }
    let newKeys = await controller.jwks
    #expect(newKeys.object?["keys"]?.array?.count == 1)
    #expect(try await rig.tokenKid(controller) == newKid)
    #expect(newKeys != oldKeys)
    if directory {
      #expect(rig.remote.withLock { $0.keys } == newKeys)
      let effects = rig.remote.withLock { $0.effects }
      #expect(effects.first?.method == .post)
      #expect(effects.dropFirst().allSatisfy { $0.method == .put })
      #expect(effects[1].signer == rig.key.kid)
      #expect(effects.last?.signer == newKid)
    } else { #expect(rig.remote.withLock { $0.effects.isEmpty }) }
    let again = try await rig.at(172_801) { try await rig.reopen() }
    #expect(try await rig.tokenKid(again) == newKid)
    #expect(await again.settings.directoryID == rig.controller.settings.directoryID)
  }

  @Test func failedDayZeroDoesNotStartClockOrSwitchAndRestartRetriesSameKey() async throws {
    let rig = try await RotationRig(directory: true)
    rig.remote.withLock { $0.reject = true }
    await #expect(throws: IdentityError.directoryUnavailable) { try await rig.at(0) { try await rig.controller.rotate() } }
    let staged = await rig.controller.jwks
    #expect(await rig.controller.settings.keySchedule?.overlapBeganAt == nil)
    await #expect(throws: IdentityError.directoryUnavailable) { try await rig.tokenKid() }
    let blocked = try await rig.at(3 * 86400) { try await rig.reopen() }
    #expect(await blocked.jwks == staged)
    #expect(await blocked.settings.keySchedule?.signingWithNext == false)
    rig.remote.withLock { $0.reject = false }
    try await rig.at(3 * 86400) { try await blocked.maintain() }
    #expect(try await rig.tokenKid(blocked) == rig.key.kid)
    #expect(await blocked.jwks == staged)
    try await rig.at(4 * 86400 - 1) { try await blocked.maintain() }
    #expect(try await rig.tokenKid(blocked) == rig.key.kid)
    try await rig.at(4 * 86400) { try await blocked.maintain() }
    #expect(try await rig.tokenKid(blocked) != rig.key.kid)
  }

  @Test func refusedRemovalKeepsOldPublishedAndResumesWithNewProof() async throws {
    let rig = try await RotationRig(directory: true)
    try await rig.at(0) { try await rig.controller.rotate() }
    try await rig.at(86400) { try await rig.controller.maintain() }
    let newKid = try await rig.tokenKid()
    rig.remote.withLock { $0.reject = true }
    await #expect(throws: IdentityError.directoryUnavailable) { try await rig.at(172_800) { try await rig.controller.maintain() } }
    #expect(await rig.controller.jwks.object?["keys"]?.array?.count == 2)
    #expect(rig.remote.withLock { $0.keys.object?["keys"]?.array?.count } == 2)
    let blocked = try await rig.at(200_000) { try await rig.reopen() }
    await #expect(throws: IdentityError.directoryUnavailable) { try await rig.tokenKid(blocked) }
    rig.remote.withLock { $0.reject = false }
    try await rig.at(200_000) { try await blocked.maintain() }
    #expect(await blocked.jwks.object?["keys"]?.array?.count == 1)
    #expect(try await rig.tokenKid(blocked) == newKid)
    #expect(rig.remote.withLock { $0.effects.last?.signer } == newKid)
  }

  @Test func automaticNinetyDayScheduleAndDuplicateAdminTrigger() async throws {
    let rig = try await RotationRig(directory: false)
    try await rig.at(90 * 86400 - 1) { try await rig.controller.maintain() }
    #expect(await rig.controller.jwks.object?["keys"]?.array?.count == 1)
    let restarted = try await rig.at(90 * 86400) { try await rig.reopen() }
    #expect(await restarted.jwks.object?["keys"]?.array?.count == 2)
    await #expect(throws: IdentityError.mutationInProgress) { try await restarted.rotate() }
    try await rig.at(91 * 86400) { try await restarted.maintain() }
    try await rig.at(92 * 86400) { try await restarted.maintain() }
    #expect(await restarted.jwks.object?["keys"]?.array?.count == 1)
    try await rig.at(182 * 86400 - 1) { try await restarted.maintain() }
    #expect(await restarted.jwks.object?["keys"]?.array?.count == 1)
    try await rig.at(182 * 86400) { try await restarted.maintain() }
    #expect(await restarted.jwks.object?["keys"]?.array?.count == 2)
  }

  @Test func delayedSwitchDoesNotRetireRecentlyMintedOldTokens() async throws {
    let rig = try await RotationRig(directory: false)
    try await rig.at(0) { try await rig.controller.rotate() }
    #expect(try await rig.tokenKid() == rig.key.kid)
    try await rig.at(3 * 86400) { try await rig.controller.maintain() }
    #expect(try await rig.tokenKid() != rig.key.kid)
    #expect(await rig.controller.jwks.object?["keys"]?.array?.count == 2)
    try await rig.at(4 * 86400 - 1) { try await rig.controller.maintain() }
    #expect(await rig.controller.jwks.object?["keys"]?.array?.count == 2)
    try await rig.at(4 * 86400) { try await rig.controller.maintain() }
    #expect(await rig.controller.jwks.object?["keys"]?.array?.count == 1)
  }

  @Test(arguments: [IdentityError.unknownId, .unlistedKey])
  func ownershipFailureIsTypedForAllMintSitesAndFreshRegistrationChangesIssuer(failure: IdentityError) async throws {
    let rig = try await RotationRig(directory: true)
    let oldIssuer = try await rig.controller.issuerFor(URL(string: "https://verifier.test")!)
    let fetch = FetchClient { request in
      if request.method == .put { return try Response.json(["code": failure.directoryCode!], status: failure == .unknownId ? .notFound : .unauthorized) }
      let id = String(repeating: "n", count: 32)
      return try Response.json(JSONValue.object(["id": .string(id), "issuer": .string("https://id.wuhu.ai/" + id), "confirmed": true]), status: .created)
    }
    let controller = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .filesystem(rig.fs), fetch: fetch)
    await #expect(throws: failure) { try await rig.tokenKid(controller) }
    await #expect(throws: failure.inferenceError) {
      try await controller.tokenForInference(audience: URL(string: "https://verifier.test")!, space: "s", group: "g", session: "a", now: rig.epoch, id: UUID(0))
    }
    let page = PageFetch(controller: controller, hop: { _, _ in Issue.record("unconfirmed identity must not connect"); return Response(status: .ok) })
    do {
      _ = try await page.response(Request(url: URL(string: "https://verifier.test")!), allow: ["https://verifier.test"], space: "s", group: "g", page: "/p", viewer: "v", deadline: .now() + .seconds(60))
      Issue.record("ownership failure minted a token")
    } catch let error as PageFetchError { #expect(error.code == failure.directoryCode) }
    let script = ScriptFetch(controller: controller, hop: { _, _ in Issue.record("unconfirmed identity must not connect"); return Response(status: .ok) })
    try await withIdentityScript(proxy: script) { rig in
      let output = try await rig.evaluate("try { await fetch('https://verifier.test', {identity:true}) } catch(e) { result(e.code) }")
      #expect(output == .string(failure.directoryCode!))
    }
    try await controller.registerNew()
    let issuer = try await controller.issuerFor(URL(string: "https://verifier.test")!)
    #expect(issuer != oldIssuer)
    #expect(issuer == "https://id.wuhu.ai/" + String(repeating: "n", count: 32))
    let reopened = try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .filesystem(rig.fs), fetch: fetch)
    #expect(try await reopened.issuerFor(URL(string: "https://verifier.test")!) == issuer)
    #expect(await controller.directoryConfirmed)
  }

  @Test func lifecycleAutomaticallyMaintainsAndCancelsItsSleep() async throws {
    let rig = try await RotationRig(directory: false)
    let entered = Gate()
    let store = IdentityStateStore.filesystem(rig.fs)
    let controller = try await rig.at(0) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: .init(load: store.load, save: { data in
        try await store.save(data)
        entered.open()
      }), fetch: rig.fetch)
    }
    let clock = TestClock<Duration>()
    await withDependencies {
      $0.continuousClock = clock
      $0.date = .constant(rig.epoch.addingTimeInterval(90 * 86400))
    } operation: {
      await withTaskGroup(of: Void.self) { tasks in
        tasks.addTask { await controller.run() }
        await entered.wait()
        tasks.cancelAll()
        await tasks.waitForAll()
      }
    }
    #expect(await controller.jwks.object?["keys"]?.array?.count == 2)
    #expect(try await rig.tokenKid(controller) == rig.key.kid)
  }

  @Test func diskSchedulePersistsSecretKeysPrivatelyAndRestartsWithNewSigner() async throws {
    let scratch = try scratchURL("identity-rotation")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let directory = scratch.appendingPathComponent("identity")
    let key = try await ServerIdentity.loadOrCreate(directory: directory)
    let fetch = FetchClient { _ in Issue.record("self rotation must not publish remotely"); return Response(status: .forbidden) }
    let controller = try await withDependencies { $0.date = .constant(fixedDate) } operation: {
      try await IdentityController.load(identity: key, origin: "https://space.test", store: .disk(directory), fetch: fetch)
    }
    try await withDependencies { $0.date = .constant(fixedDate) } operation: { try await controller.rotate() }
    try await withDependencies { $0.date = .constant(fixedDate.addingTimeInterval(86400)) } operation: { try await controller.maintain() }
    let reopened = try await withDependencies { $0.date = .constant(fixedDate.addingTimeInterval(86400)) } operation: {
      try await IdentityController.load(identity: key, origin: "https://space.test", store: .disk(directory), fetch: fetch)
    }
    #expect(await reopened.identity.kid != key.kid)
    #expect(await reopened.jwks == controller.jwks)
    let file = directory.appendingPathComponent("settings.json")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(directoryMode?.intValue == 0o700)
    let discovery = try await reopened.snapshot().jsonString()
    #expect(!discovery.contains("currentKey"))
    #expect(!discovery.contains("nextKey"))
  }

  @Test(arguments: [false, true]) func acceptedPublicationBeforeStoreFailureRestartsWithSamePendingKey(retiring: Bool) async throws {
    let rig = try await RotationRig(directory: true)
    if retiring {
      try await rig.at(0) { try await rig.controller.rotate() }
      try await rig.at(86400) { try await rig.controller.maintain() }
    }
    let store = IdentityStateStore.filesystem(rig.fs)
    let fail = Mutex(false)
    let failingStore = IdentityStateStore(load: store.load, save: { data in
      let schedule = try JSONDecoder().decode(IdentitySettings.self, from: data).keySchedule!
      if fail.withLock({ $0 }), retiring ? schedule.nextKey == nil : schedule.overlapBeganAt != nil { throw IdentityError.keyUnavailable }
      try await store.save(data)
    })
    let controller = try await rig.at(retiring ? 86401 : 0) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: rig.fetch)
    }
    fail.withLock { $0 = true }
    await #expect(throws: IdentityError.keyUnavailable) {
      try await rig.at(retiring ? 172_800 : 0) {
        if retiring { try await controller.maintain() }
        else { try await controller.rotate() }
      }
    }
    let both = await controller.jwks
    let staged = await controller.settings.keySchedule!
    #expect(both.object?["keys"]?.array?.count == 2)
    #expect(rig.remote.withLock { $0.keys.object?["keys"]?.array?.count } == (retiring ? 1 : 2))
    let signer = try await rig.tokenKid(controller)
    #expect(rig.remote.withLock { $0.effects.last?.signer } == signer)
    let effectsBeforeRestart = rig.remote.withLock { $0.effects.count }
    let resumed = try await rig.at(retiring ? 172_801 : 1) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: rig.fetch)
    }
    #expect(await resumed.jwks == both)
    #expect(await resumed.settings.keySchedule?.nextKey == staged.nextKey)
    #expect(await resumed.settings.keySchedule?.currentKey == staged.currentKey)
    #expect(try await rig.tokenKid(resumed) == signer)
    let effects = rig.remote.withLock { Array($0.effects.dropFirst(effectsBeforeRestart)) }
    #expect(effects.allSatisfy { $0.signer == signer && $0.method == .put })
    #expect(effects.count == 2)
    if !retiring {
      #expect(await resumed.settings.keySchedule?.overlapBeganAt == nil)
      #expect(rig.remote.withLock { $0.keys } == both)
    }
    fail.withLock { $0 = false }
    try await rig.at(retiring ? 172_802 : 2) { try await resumed.maintain() }
    if retiring {
      #expect(await resumed.jwks == rig.remote.withLock { $0.keys })
      #expect(await resumed.jwks.object?["keys"]?.array?.count == 1)
    } else {
      #expect(await resumed.settings.keySchedule?.overlapBeganAt == rig.epoch.addingTimeInterval(2))
      try await rig.at(86401) { try await resumed.maintain() }
      #expect(try await rig.tokenKid(resumed) == rig.key.kid)
      try await rig.at(86402) { try await resumed.maintain() }
      #expect(try await rig.tokenKid(resumed) != rig.key.kid)
      #expect(await resumed.jwks == both)
    }
  }

  @Test func durableWriteFailureNeverSwitchesSigner() async throws {
    let rig = try await RotationRig(directory: true)
    try await rig.at(0) { try await rig.controller.rotate() }
    let store = IdentityStateStore.filesystem(rig.fs)
    let failure = Mutex(false)
    let failingStore = IdentityStateStore(load: store.load, save: { data in
      if failure.withLock({ $0 }) { throw IdentityError.keyUnavailable }
      try await store.save(data)
    })
    let controller = try await rig.at(1) {
      try await IdentityController.load(identity: rig.key, origin: "https://private.test", store: failingStore, fetch: rig.fetch)
    }
    failure.withLock { $0 = true }
    await #expect(throws: IdentityError.keyUnavailable) { try await rig.at(86400) { try await controller.maintain() } }
    #expect(try await rig.tokenKid(controller) == rig.key.kid)
    #expect(await controller.settings.keySchedule?.signingWithNext == false)
    failure.withLock { $0 = false }
    let resumed = try await rig.at(86400) { try await rig.reopen() }
    #expect(try await rig.tokenKid(resumed) != rig.key.kid)
  }
}

final class RotationRig: Sendable {
  struct Remote: Sendable {
    var keys: JSONValue = .object(["keys": .array([])])
    var reject = false
    var effects: [(method: Fetch.Method, signer: String)] = []
  }

  let fs: NodeTreeVFS
  let key: ServerIdentity
  let controller: IdentityController
  let fetch: FetchClient
  final class RemoteBox: Sendable {
    let state = Mutex(Remote())
    func withLock<T: Sendable>(_ operation: (inout Remote) throws -> T) rethrows -> T { try state.withLock { try operation(&$0) } }
  }

  let remote: RemoteBox
  let epoch = Date(timeIntervalSince1970: 1_800_000_000)

  init(directory: Bool) async throws {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    self.fs = fs
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    self.key = key
    let remote = RemoteBox()
    self.remote = remote
    let fetch = FetchClient { request in
      let proof = try await request.body!.text()
      let parts = proof.split(separator: ".").map(String.init)
      let header = try rotationJSON(parts[0])
      let payload = try rotationJSON(parts[1])
      let supplied = try #require(payload.object?["jwks"])
      let existing = remote.withLock { $0.keys }
      let verificationKeys = request.method == .post ? supplied : existing
      let kid = try #require(header.object?["kid"]?.stringValue)
      try rotationVerify(proof, keys: verificationKeys)
      #expect(payload.object?["aud"] == .string(request.url.absoluteString))
      #expect(!payload.jsonString().contains("private.test"))
      let reject = remote.withLock { state in
        state.effects.append((request.method, kid))
        if !state.reject { state.keys = supplied }
        return state.reject
      }
      if reject { return Response(status: .forbidden) }
      let id = String(repeating: "r", count: 32)
      return try Response.json(request.method == .post ? JSONValue.object(["id": .string(id), "issuer": .string("https://id.wuhu.ai/" + id), "confirmed": true]) : ["confirmed": true], status: request.method == .post ? .created : .ok)
    }
    self.fetch = fetch
    controller = try await withDependencies { $0.date = .constant(epoch) } operation: {
      try await IdentityController.load(identity: key, origin: "https://private.test", store: .filesystem(fs), fetch: fetch)
    }
    if directory {
      try await withDependencies { $0.date = .constant(epoch) } operation: { try await controller.set(defaultIssuer: .directory) }
    }
  }

  func at<T: Sendable>(_ seconds: Int, _ operation: () async throws -> T) async rethrows -> T {
    try await withDependencies { $0.date = .constant(epoch.addingTimeInterval(Double(seconds))) } operation: { try await operation() }
  }

  func reopen() async throws -> IdentityController {
    try await IdentityController.load(identity: key, origin: "https://private.test", store: .filesystem(fs), fetch: fetch)
  }

  func tokenKid(_ controller: IdentityController? = nil) async throws -> String {
    let controller = controller ?? self.controller
    let token = try await controller.token(audience: URL(string: "https://verifier.test")!, space: "s", group: "g", now: epoch, id: UUID(0))
    try rotationVerify(token, keys: await controller.jwks)
    return try #require(rotationJSON(String(token.split(separator: ".")[0])).object?["kid"]?.stringValue)
  }
}

private func rotationDecode(_ value: String) throws -> Data {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}

func rotationJSON(_ value: String) throws -> JSONValue {
  try #require(JSONValue.parse(String(decoding: rotationDecode(value), as: UTF8.self)))
}

func rotationVerify(_ token: String, keys: JSONValue) throws {
  let parts = token.split(separator: ".").map(String.init)
  let kid = try #require(rotationJSON(parts[0]).object?["kid"]?.stringValue)
  let jwk = try #require(keys.object?["keys"]?.array?.first { $0.object?["kid"] == .string(kid) }?.object)
  let point = Data([4]) + (try rotationDecode(#require(jwk["x"]?.stringValue))) + (try rotationDecode(#require(jwk["y"]?.stringValue)))
  let key = try P256.Signing.PublicKey(x963Representation: point)
  #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: rotationDecode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
}
