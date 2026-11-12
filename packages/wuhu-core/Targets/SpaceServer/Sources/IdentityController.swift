#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import JSONValue
import func MainHub.fetchOrigin
import SpaceCore
import enum WuhuAI.InferenceError
import Wuwei

enum IssuerChoice: String, Codable, Sendable { case `self`, directory }

struct IdentitySettings: Codable, Sendable {
  var defaultIssuer: IssuerChoice = .self
  var overrides: [String: IssuerChoice] = [:]
  var directoryID: String?
  var keySchedule: IdentityKeySchedule?
}

struct IdentityController: Sendable {
  static let directoryOrigin = "https://id.wuhu.ai"
  static let cellID = IdentityCell.ID("server")
  let space: Space
  let origin: String?
  let keys: IdentityKeys

  static func load(space: Space, origin: String?, directory: URL, fetch: FetchClient) async throws -> Self {
    let keys = IdentityKeys.disk(directory)
    let controller = configure(space: space, origin: origin, keys: keys, fetch: fetch)
    if controller.state == nil {
      let identity = try await ServerIdentity.loadOrCreate(directory: directory)
      let file = directory.appendingPathComponent("settings.json")
      let settings: IdentitySettings
      if FileManager.default.fileExists(atPath: file.path) {
        guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.keyUnavailable }
        settings = try JSONDecoder().decode(IdentitySettings.self, from: Data(contentsOf: file))
      } else { settings = IdentitySettings() }
      try await controller.initialize(identity: identity, settings: settings)
    }
    return controller
  }

  static func configure(space: Space, origin: String?, keys: IdentityKeys, fetch: FetchClient) -> Self {
    @Dependency(\.uuid) var uuid
    @Dependency(\.continuousClock) var clock
    space.worker.provide(IdentityClient(keys: keys, fetch: fetch, uuid: { uuid() }, sleep: { try await clock.sleep(for: $0) }))
    space.worker.register(.cell(IdentityCell.self))
    space.worker.register(.job(IdentityJob.self))
    return Self(space: space, origin: origin, keys: keys)
  }

  func initialize(identity: ServerIdentity, settings: IdentitySettings = .init()) async throws {
    let legacy = settings.keySchedule
    try legacy?.validate()
    if let id = settings.directoryID, !Self.validID(id) { throw IdentityError.keyUnavailable }
    for audience in settings.overrides.keys { try Self.validateAudience(audience) }
    let current = try legacy.map { try ServerIdentity(rawKey: $0.currentKey) } ?? identity
    try await keys.store(current)
    let next = try legacy?.nextKey.map(ServerIdentity.init(rawKey:))
    if let next { try await keys.store(next) }
    let bootstrap: IdentityBootstrap = if let legacy {
      .imported(IdentitySchedule(current: current.kid, rotatedAt: legacy.rotatedAt, next: next?.kid, overlapBeganAt: legacy.overlapBeganAt, switchedAt: legacy.switchedAt))
    } else { .fresh(current.kid) }
    try await space.worker.call(Self.cellID) { try $0.initialize(bootstrap, defaultIssuer: settings.defaultIssuer, overrides: settings.overrides, directoryID: settings.directoryID) }
  }

  var state: IdentityState? { space.worker.cell(Self.cellID).state() }
  var jwks: JSONValue { get async throws { try await keys.jwks(state!.schedule.keys) } }

  func snapshot() throws -> JSONValue { try snapshot(state!) }

  private func snapshot(_ state: IdentityState) throws -> JSONValue {
    func resolved(_ choice: IssuerChoice) throws -> JSONValue {
      if choice == .directory, state.directoryID == nil { return .null }
      return .string(try resolve(choice, state))
    }
    var overrides: [String: JSONValue] = [:]
    for (origin, choice) in state.overrides { overrides[origin] = try resolved(choice) }
    return .object([
      "defaultIssuer": try resolved(state.defaultIssuer),
      "overrides": .object(.init(uniqueKeysWithValues: overrides.sorted { $0.key < $1.key })),
      "publicationFailure": state.failure.map { .string($0.workCode) } ?? .null,
      "state": .string(state.pending != nil ? "publishing" : state.failure != nil ? "failed" : "confirmed"),
      "rotating": .bool(state.rotating),
    ])
  }

  func issuerFor(_ audience: URL) throws -> String {
    let state = state!
    return try resolve(state.overrides[ServerIdentity.audience(audience)] ?? state.defaultIssuer, state)
  }

  func inferenceReplayIdentity(audience: URL, space: String, group: String) throws -> String {
    String(decoding: try JSONEncoder().encode([issuerFor(audience), ServerIdentity.audience(audience), space, group]), as: UTF8.self)
  }

  private func resolve(_ choice: IssuerChoice, _ state: IdentityState) throws -> String {
    switch choice {
    case .self: return try ServerIdentity.issuer(origin)
    case .directory:
      guard let id = state.directoryID else { throw IdentityError.directoryUnavailable }
      return Self.directoryOrigin + "/" + id
    }
  }

  func token(audience: URL, space: String, group: String, session: String? = nil, now: Date, id: UUID, lifetime: Int = 300, page: String? = nil, viewer: String? = nil, exec: ExecClaims? = nil) async throws -> String {
    let state = state!
    let choice = state.overrides[try ServerIdentity.audience(audience)] ?? state.defaultIssuer
    if choice == .directory, !state.confirmed { throw state.failure ?? IdentityError.directoryUnavailable }
    let signer = try await keys.load(state.schedule.signer)
    return try signer.token(issuer: origin, audience: audience, space: space, group: group, session: session, now: now, id: id, lifetime: lifetime, page: page, viewer: viewer, exec: exec, directoryIssuer: choice == .directory ? resolve(.directory, state) : nil)
  }

  func tokenForInference(audience: URL, space: String, group: String, session: String, now: Date, id: UUID) async throws(InferenceError) -> String {
    do { return try await token(audience: audience, space: space, group: group, session: session, now: now, id: id) }
    catch let error as IdentityError { throw error.inferenceError }
    catch { throw InferenceError.normalize(error) }
  }

  func set(defaultIssuer: IssuerChoice? = nil, audience: String? = nil, choice: IssuerChoice? = nil) async throws -> JSONValue {
    try snapshot(await space.worker.call(Self.cellID) { try $0.set(defaultIssuer: defaultIssuer, audience: audience, choice: choice) })
  }

  func registerNew() async throws -> JSONValue {
    try snapshot(await space.worker.call(Self.cellID) { try $0.registerNew() })
  }

  func rotate() async throws -> JSONValue {
    try snapshot(await space.worker.call(Self.cellID) { try $0.rotate() })
  }

  static func validID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 95 }
  }

  static func validateAudience(_ audience: String) throws {
    guard let url = URL(string: audience), try ServerIdentity.audience(url) == audience, fetchOrigin(url) == audience,
          let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.isEmpty, parts.query == nil, parts.fragment == nil
    else { throw IdentityError.invalidAudience }
  }
}
