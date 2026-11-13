#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum SpaceContract.EnrollLink

public struct UserRecoveryError: Error, Equatable, CustomStringConvertible {
  public let message: String
  public var description: String { message }
}

// Offline recovery: possession of the space folder is root, so these verbs
// operate directly on <folder>/space.sqlite with the server stopped instead
// of trusting a localhost side channel.
public enum UserRecovery {
  public static func add(folder: URL, name: String?, admin: Bool = false) async throws -> String {
    try requireSpaceFolder(folder)
    let record = try await withSpace(in: folder) { try await add(space: $0, name: name, admin: admin) }
    return "account \(record.id.rawValue)\(name.map { " (\($0))" } ?? "")\(record.isAdmin ? " admin" : "")\n"
  }

  public static func add(space: Space, name: String?, admin: Bool = false) async throws -> AccountRecord {
    // The first admin needs no admin to appoint it: a space without one makes
    // the next offline add the admin, which also recovers an adminless space.
    let isAdmin = admin ? true : !(try await space.hasAdminAccount())
    return try await space.addAccount(kind: .human, name: name, admin: isAdmin)
  }

  public static func reset(folder: URL, account: String) async throws -> String {
    try requireSpaceFolder(folder)
    guard AccountID.isValid(account) else {
      throw UserRecoveryError(message: "malformed account id: \(account)")
    }
    let id = AccountID(rawValue: account)
    let removed = try await withSpace(in: folder) { space in
      guard try await space.account(id) != nil else {
        throw UserRecoveryError(message: "no account \(account) in \(folder.path)")
      }
      return try await space.resetCredentials(account: id)
    }
    return "reset \(account) keys \(removed.keys) read-sessions \(removed.readSessions)\n"
  }

  public static func invite(folder: URL, account: String, server: String?, ttl: TimeInterval?) async throws -> (output: String, note: String?) {
    try requireSpaceFolder(folder)
    guard AccountID.isValid(account) else {
      throw UserRecoveryError(message: "malformed account id: \(account)")
    }
    return try await withSpace(in: folder) { try await makeInvite(space: $0, account: account, server: server, ttl: ttl, location: folder.path) }
  }

  public static func invite(space: Space, account: String, server: String?, ttl: TimeInterval?) async throws -> (output: String, note: String?) {
    try await makeInvite(space: space, account: account, server: server, ttl: ttl, location: nil)
  }

  private static func makeInvite(space: Space, account: String, server: String?, ttl: TimeInterval?, location: String?) async throws -> (output: String, note: String?) {
    guard AccountID.isValid(account) else {
      throw UserRecoveryError(message: "malformed account id: \(account)")
    }
    let id = AccountID(rawValue: account)
    guard try await space.account(id) != nil else {
      throw UserRecoveryError(message: "no account \(account)\(location.map { " in \($0)" } ?? "")")
    }
    let deployment = try await space.deployment()
    guard let server = server ?? deployment?.origin else {
      throw UserRecoveryError(message: """
      no server origin recorded\(location.map { " in \($0)" } ?? ""); pass --server <url>, or boot the server once with --origin
      """)
    }
    let lifetime = ttl ?? 3600
    let minted = try await space.mintJoinToken(account: id, capabilities: [.device], createdBy: nil, lifetime: lifetime)
    let identity = try await space.identity()
    let link = EnrollLink.format(
      origin: server,
      token: minted.token.rawValue,
      space: identity.rawValue,
      fingerprint: deployment?.pin,
    )
    let unproven = deployment.map { $0.certificate == nil } ?? false
    return (
      "\(link)\n",
      (unproven ? unprovenCertificateNote : "") + "one-time link; it dies at first use or in \(Int(lifetime)) seconds\n",
    )
  }

  static let unprovenCertificateNote = """
  the deployment record predates certificate tracking, so this link carries no certificate fingerprint; \
  boot the server once to record it

  """

  /// A folder with `records.sqlite` is the storage of a server that keeps no `space.sqlite`:
  /// opening one there would make an account that server never reads.
  private static func requireSpaceFolder(_ folder: URL) throws {
    guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
      throw UserRecoveryError(message: "no space folder at \(folder.path)")
    }
    guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("records.sqlite").path) else {
      throw UserRecoveryError(message: """
      \(folder.path) is another server's storage (it holds records.sqlite), not a space folder; \
      with that server stopped, recover it with its own user add|invite|reset
      """)
    }
  }

  private static func withSpace<R>(in folder: URL, _ body: (Space) async throws -> R) async throws -> R {
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    let result: R
    do { result = try await body(space) } catch {
      try? await space.close()
      throw error
    }
    try await space.close()
    return result
  }
}
