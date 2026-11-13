#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import StructuredQueries
import Wuwei
import WuweiQueries

public struct UserAvatar: Sendable {
  public static let maximumBytes = 4 * 1024 * 1024
  public let hash: String
  public let data: Data
}

public enum UserAvatarError: Error, Equatable, Sendable {
  case tooLarge
  case invalidPNG
}

extension Space {
  public func userAvatar(principal: String) async throws -> UserAvatar? {
    let principal = cell.userProfile(handle: principal)?.principal ?? principal
    guard let owner = cell.personCell(principal),
          let hash = worker.cell(owner).avatarHash(principal: principal) else { return nil }
    return try await UserAvatar(hash: hash, data: Data(bucket.bytes(hash)))
  }

  public func setUserAvatar(principal: String, data: Data?) async throws {
    if let data {
      guard data.count <= UserAvatar.maximumBytes else { throw UserAvatarError.tooLarge }
      guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw UserAvatarError.invalidPNG }
    }
    guard let owner = cell.personCell(principal) else { throw SpaceError.notFound(principal) }
    let hash: String?
    if let data { hash = try await bucket.put(Array(data)) } else { hash = nil }
    try await worker.call(owner) { try $0.setAvatarHash(principal: principal, hash: hash) }
  }
}

extension PersonCell {
  public func avatarHash(principal: String) -> String? {
    db.rows(UserProfileRow.where { $0.ownerAccount.eq(id.key) && $0.principal.eq(principal) }.select { $0.avatarHash }).first ?? nil
  }

  public mutating func setAvatarHash(principal: String, hash: String?) throws {
    try requireAccount()
    try db.execute(UserProfileRow.insert {
      UserProfileRow(principal: principal, ownerAccount: id.key, displayName: nil, avatarHash: hash)
    } onConflict: { $0.principal } doUpdate: { $0.avatarHash = $1.avatarHash })
  }
}
