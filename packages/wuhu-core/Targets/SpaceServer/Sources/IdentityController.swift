#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import Fetch
import JSONValue
import Logging
import enum WuhuAI.InferenceError
import WuhuVFS

enum IssuerChoice: String, Codable, Sendable { case `self`, directory }

struct IdentitySettings: Codable, Equatable, Sendable {
  var defaultIssuer: IssuerChoice = .self
  var overrides: [String: IssuerChoice] = [:]
  var directoryID: String?
  var keySchedule: IdentityKeySchedule?

  var usesDirectory: Bool { defaultIssuer == .directory || overrides.values.contains(.directory) }
}

struct IdentityStateStore: Sendable {
  var load: @Sendable () async throws -> Data?
  var save: @Sendable (Data) async throws -> Void

  static func filesystem(_ fs: any VirtualFileSystem) -> Self {
    let path = try! VFSPath(absoluteFilePath: "/settings.json")
    return Self(load: {
      try await fs.status(at: path) == nil ? nil : fs.readData(at: path)
    }, save: { data in
      if try await fs.status(at: path) == nil { try await fs.createFile(at: path, data: data) }
      else { try await fs.writeData(data, at: path, append: false) }
    })
  }

  static func disk(_ directory: URL) -> Self {
    let file = directory.appendingPathComponent("settings.json")
    return Self(load: {
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IdentityError.keyUnavailable }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return try Data(contentsOf: file)
    }, save: { data in
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    })
  }
}

actor IdentityController {
  static let directoryOrigin = "https://id.wuhu.ai"
  private(set) var identity: ServerIdentity
  let origin: String?
  let store: IdentityStateStore
  let fetch: FetchClient
  private let logger: Logger
  private(set) var settings: IdentitySettings
  private(set) var directoryConfirmed = false
  private(set) var publicationFailure = IdentityError.directoryUnavailable
  var mutationInProgress = false

  init(identity: ServerIdentity, origin: String?, settings: IdentitySettings = .init(), store: IdentityStateStore, fetch: FetchClient, logger: Logger = Logger(label: "wuhu.identity")) throws {
    var settings = settings
    if settings.keySchedule == nil {
      @Dependency(\.date) var date
      settings.keySchedule = .init(currentKey: identity.rawKey, rotatedAt: date.now)
    }
    try Self.validate(settings)
    self.identity = try ServerIdentity(rawKey: settings.keySchedule!.signingKey)
    self.origin = origin
    self.settings = settings
    self.store = store
    self.fetch = fetch
    self.logger = logger
  }

  static func load(identity: ServerIdentity, origin: String?, store: IdentityStateStore, fetch: FetchClient) async throws -> IdentityController {
    let data = try await store.load()
    let settings = try data.map { try JSONDecoder().decode(IdentitySettings.self, from: $0) } ?? IdentitySettings()
    let controller = try IdentityController(identity: identity, origin: origin, settings: settings, store: store, fetch: fetch)
    if settings.keySchedule == nil { try await controller.persist(controller.settings) }
    try? await controller.publish()
    try? await controller.maintain()
    return controller
  }

  var jwks: JSONValue {
    let schedule = settings.keySchedule!
    let current = try! ServerIdentity(rawKey: schedule.currentKey)
    guard let next = schedule.nextKey else { return current.jwks }
    return .object(["keys": .array(current.jwks.object!["keys"]!.array! + (try! ServerIdentity(rawKey: next)).jwks.object!["keys"]!.array!)])
  }

  func snapshot() throws -> JSONValue {
    let defaultIssuer = try resolve(settings.defaultIssuer)
    var overrides: [String: JSONValue] = [:]
    for (origin, choice) in settings.overrides { overrides[origin] = .string(try resolve(choice)) }
    return .object(["defaultIssuer": .string(defaultIssuer), "overrides": .object(.init(uniqueKeysWithValues: overrides.sorted { $0.key < $1.key })), "publicationFailure": (settings.usesDirectory || settings.directoryID != nil) && !directoryConfirmed ? .string(publicationFailure.directoryCode!) : .null])
  }

  func issuerFor(_ audience: URL) throws -> String {
    try resolve(settings.overrides[ServerIdentity.audience(audience)] ?? settings.defaultIssuer)
  }

  private func resolve(_ choice: IssuerChoice) throws -> String {
    switch choice {
    case .self: return try ServerIdentity.issuer(origin)
    case .directory:
      guard let id = settings.directoryID else { throw IdentityError.directoryUnavailable }
      return Self.directoryOrigin + "/" + id
    }
  }

  func token(audience: URL, space: String, group: String, session: String? = nil, now: Date, id: UUID, lifetime: Int = 300, page: String? = nil, viewer: String? = nil) throws -> String {
    let choice = settings.overrides[try ServerIdentity.audience(audience)] ?? settings.defaultIssuer
    if choice == .directory, !directoryConfirmed { throw publicationFailure }
    return try identity.token(issuer: origin, audience: audience, space: space, group: group, session: session, now: now, id: id, lifetime: lifetime, page: page, viewer: viewer, directoryIssuer: choice == .directory ? resolve(.directory) : nil)
  }

  func tokenForInference(audience: URL, space: String, group: String, session: String, now: Date, id: UUID) throws(InferenceError) -> String {
    do { return try token(audience: audience, space: space, group: group, session: session, now: now, id: id) }
    catch let error as IdentityError { throw error.inferenceError }
    catch { throw InferenceError.normalize(error) }
  }

  func set(defaultIssuer: IssuerChoice? = nil, audience: String? = nil, choice: IssuerChoice? = nil) async throws {
    guard !mutationInProgress else { throw IdentityError.mutationInProgress }
    mutationInProgress = true
    defer { mutationInProgress = false }
    var next = settings
    if let defaultIssuer { next.defaultIssuer = defaultIssuer }
    if let audience {
      guard let url = URL(string: audience), try ServerIdentity.audience(url) == audience, fetchOrigin(url) == audience,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path.isEmpty, parts.query == nil, parts.fragment == nil
      else { throw IdentityError.invalidAudience }
      next.overrides[audience] = choice
    }
    try Self.validate(next)
    try await commit(next)
    if next.usesDirectory || next.directoryID != nil { try await publishCurrent() }
  }

  func registerNew() async throws {
    guard !mutationInProgress else { throw IdentityError.mutationInProgress }
    mutationInProgress = true
    defer { mutationInProgress = false }
    let ownershipLost = !directoryConfirmed && (publicationFailure == .unknownId || publicationFailure == .unlistedKey)
    guard settings.keySchedule!.nextKey == nil || ownershipLost else { throw IdentityError.mutationInProgress }
    guard settings.usesDirectory || settings.directoryID != nil else { throw IdentityError.directoryNotSelected }
    try await publishCurrent(registeringNew: true)
  }

  func publish() async throws {
    guard !mutationInProgress else { throw IdentityError.mutationInProgress }
    mutationInProgress = true
    defer { mutationInProgress = false }
    if settings.usesDirectory || settings.directoryID != nil { try await publishCurrent() }
  }

  func publishCurrent(keys: JSONValue? = nil, registeringNew: Bool = false) async throws {
    if !registeringNew {
      directoryConfirmed = false
      publicationFailure = .directoryUnavailable
    }
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    let registration = registeringNew || settings.directoryID == nil
    let target = Self.directoryOrigin + (registration ? "/register" : "/" + settings.directoryID! + "/keys")
    do {
      let proof = try identity.proof(audience: target, jwks: keys ?? jwks, now: date.now, id: uuid())
      let request = Request(url: URL(string: target)!, method: registration ? .post : .put, body: .bytes(Data(proof.utf8), contentType: "application/jose"))
      @Dependency(\.continuousClock) var clock
      let fetch = fetch
      let result = try await withThrowingTaskGroup(of: JSONValue.self) { tasks in
        tasks.addTask {
          let response = try await fetch(request)
          guard response.status == (registration ? .created : .ok) else {
            let result = try? await response.json(JSONValue.self, upTo: 4096)
            switch result?.object?["code"]?.stringValue {
            case "unknownId": throw IdentityError.unknownId
            case "unlistedKey": throw IdentityError.unlistedKey
            default: throw IdentityError.directoryUnavailable
            }
          }
          return try await response.json(JSONValue.self, upTo: 4096)
        }
        tasks.addTask { [clock] in
          try await clock.sleep(for: .seconds(15))
          throw IdentityError.directoryUnavailable
        }
        defer { tasks.cancelAll() }
        return try await tasks.next()!
      }
      guard result.object?["confirmed"] == .bool(true) else { throw IdentityError.directoryUnavailable }
      if registration {
        guard let id = result.object?["id"]?.stringValue, Self.validID(id), result.object?["issuer"] == .string(Self.directoryOrigin + "/" + id) else { throw IdentityError.directoryUnavailable }
        var next = settings
        next.directoryID = id
        try await commit(next)
      }
      directoryConfirmed = true
    } catch {
      let failure: IdentityError = switch error as? IdentityError {
      case .unknownId: .unknownId
      case .unlistedKey: .unlistedKey
      default: .directoryUnavailable
      }
      if !registeringNew { publicationFailure = failure }
      logger.warning("identity publication failed", metadata: ["code": "\(failure.directoryCode!)"])
      throw failure
    }
  }

  func persist(_ settings: IdentitySettings) async throws {
    try await store.save(JSONEncoder().encode(settings))
  }

  func commit(_ next: IdentitySettings) async throws {
    try Self.validate(next)
    let signer = try ServerIdentity(rawKey: next.keySchedule!.signingKey)
    try await persist(next)
    settings = next
    identity = signer
  }

  private static func validID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 95 }
  }

  private static func validate(_ settings: IdentitySettings) throws {
    if let schedule = settings.keySchedule { try schedule.validate() }
    if let id = settings.directoryID, !validID(id) { throw IdentityError.keyUnavailable }
    for audience in settings.overrides.keys {
      guard let url = URL(string: audience), try ServerIdentity.audience(url) == audience, fetchOrigin(url) == audience else { throw IdentityError.invalidAudience }
    }
  }
}
