import Foundation
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
    let space = try open(folder: folder)
    // The first admin needs no admin to appoint it: a space without one makes
    // the next offline add the admin, which also recovers an adminless space.
    let isAdmin = admin ? true : !(try await space.hasAdminAccount())
    let record: AccountRecord
    do {
      record = try await space.addAccount(kind: .human, name: name, admin: isAdmin)
    } catch let SpaceError.reservedAccountName(name) {
      throw UserRecoveryError(message: "\(name) is reserved: unenrolled --dev seats act as the owner principal")
    }
    return "account \(record.id.rawValue)\(name.map { " (\($0))" } ?? "")\(record.isAdmin ? " admin" : "")\n"
  }

  public static func reset(folder: URL, account: String) async throws -> String {
    guard AccountID.isValid(account) else {
      throw UserRecoveryError(message: "malformed account id: \(account)")
    }
    let space = try open(folder: folder)
    let id = AccountID(rawValue: account)
    guard try await space.account(id) != nil else {
      throw UserRecoveryError(message: "no account \(account) in \(folder.path)")
    }
    let removed = try await space.resetCredentials(account: id)
    return "reset \(account) keys \(removed.keys) read-sessions \(removed.readSessions)\n"
  }

  public static func invite(folder: URL, account: String, server: String?, ttl: TimeInterval?) async throws -> (output: String, note: String?) {
    guard AccountID.isValid(account) else {
      throw UserRecoveryError(message: "malformed account id: \(account)")
    }
    let space = try open(folder: folder)
    let id = AccountID(rawValue: account)
    guard try await space.account(id) != nil else {
      throw UserRecoveryError(message: "no account \(account) in \(folder.path)")
    }
    let deployment = try await space.deployment()
    guard let server = server ?? deployment?.origin else {
      throw UserRecoveryError(message: """
      no server origin recorded in \(folder.path); pass --server <url>, or boot the server once with --origin
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

  private static func open(folder: URL) throws -> Space {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw UserRecoveryError(message: "no space folder at \(folder.path)")
    }
    return try Space.open(file: folder.appendingPathComponent("space.sqlite"))
  }
}
