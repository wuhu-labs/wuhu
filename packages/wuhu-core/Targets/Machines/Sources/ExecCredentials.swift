#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import struct SpaceIDs.GroupID
import struct SpaceIDs.SessionID

/// What a machine exec carries when it starts: the credential the server's identity mints for that session and that
/// one exec, named for the machine and the operation so the machine can refuse a token minted for another.
public struct ExecCredentials: Sendable {
  public static let prefix = "wst_"
  public static let longestLife: Double = 24 * 60 * 60

  public let spaceURL: String
  /// The server's identity signing one session's exec credential.
  public let mint: @Sendable (SessionID, GroupID, MachineID, ExecID, Duration, Date) async throws -> String

  public init(spaceURL: String, mint: @escaping @Sendable (SessionID, GroupID, MachineID, ExecID, Duration, Date) async throws -> String) {
    self.spaceURL = spaceURL
    self.mint = mint
  }

  public func credential(session: SessionID, group: GroupID, machine: MachineID, exec: ExecID, timeout: Duration, issuedAt: Date) async throws -> JSONValue {
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    precondition(seconds > 0)
    let life = Int(min(seconds.rounded(.up), Self.longestLife))
    let token = try await mint(session, group, machine, exec, .seconds(life), issuedAt)
    return ["token": .string(Self.prefix + token), "spaceURL": .string(spaceURL), "expiresAt": .number(Double(Int(issuedAt.timeIntervalSince1970) + life))]
  }
}
