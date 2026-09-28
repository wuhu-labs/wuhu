#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

// The space id cannot be re-derived from the transport (that is the whole
// point of decoupling it from the TLS certificate), so the first login for a
// host:port must persist it here for every later bearerSource/share-login
// lookup from any working directory — mirrors ServerTrust's trust.json.
struct SpaceIdentityStore {
  let directory: URL

  init(environment: [String: String]) throws {
    directory = try ServerTrust.userConfigDirectory(environment: environment)
  }

  init(directory: URL) {
    self.directory = directory
  }

  func identity(forHost key: String) throws -> String? {
    try load()[key]
  }

  func record(_ identity: String, forHost key: String) throws {
    precondition(isValidSpaceIdentity(identity), "space identities are spc_<32 lowercase alnum>, got \(identity)")
    var identities = try load()
    identities[key] = identity
    try save(identities)
  }

  private var file: URL {
    directory.appendingPathComponent("spaces.json")
  }

  private func load() throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    let data = try Data(contentsOf: file)
    guard let identities = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw MalformedSpaceIdentityStore(file: file, reason: "not a JSON object of host to space id")
    }
    if let (host, value) = identities.first(where: { !isValidSpaceIdentity($0.value) }) {
      throw MalformedSpaceIdentityStore(
        file: file,
        reason: "value for \(host) is not a spc_<32 lowercase alnum> space id (got \(value.prefix(24))…)",
      )
    }
    return identities
  }

  private func save(_ identities: [String: String]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try (try encoder.encode(identities)).write(to: file, options: .atomic)
  }
}

struct SpaceIdentityMismatch: Error, CustomStringConvertible, Sendable {
  let host: String
  let recorded: String
  let advertised: String

  var description: String {
    """
    \(self.host) advertises space \(self.advertised), but this device recorded it as \(self.recorded)
    refusing to overwrite the recorded identity. if the server was genuinely replaced:
      wuhu untrust \(self.host)
    then re-enroll: wuhu login < invite-link
    """
  }
}

struct MalformedSpaceIdentityStore: Error, CustomStringConvertible, Sendable {
  let file: URL
  let reason: String

  var description: String {
    """
    malformed space identity store \(self.file.path): \(self.reason)
    fix or remove it, then re-enroll: wuhu login < invite-link
    """
  }
}
