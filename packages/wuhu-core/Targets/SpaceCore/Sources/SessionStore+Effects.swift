import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries

public struct RecordedWrite: Sendable {
  public let payload: ToolResultPayload
  public let replayed: Bool
}

/// A tool call's answer, recorded in the same transaction as the effect it
/// stands for: a retry of the call reads it back instead of acting again.
public struct ToolReceipt: Sendable {
  public let session: SessionID
  public let callID: ToolCallID
  public let payload: ToolResultPayload

  public init(session: SessionID, callID: ToolCallID, payload: ToolResultPayload) {
    self.session = session
    self.callID = callID
    self.payload = payload
  }

  func record(now: String, in db: Database) throws {
    try Sessions.recordReceipt(session.rawValue, toolCallID: callID.rawValue, payload: try Sessions.encode(payload), now: now, in: db)
  }

  /// The answer this call already has, if any.
  func recorded(in db: Database) throws -> ToolResultPayload? {
    try Sessions.receipt(session.rawValue, toolCallID: callID.rawValue, in: db)
  }
}

extension SessionStore {
  // The fs journal write and the receipt commit in one transaction: there is
  // no crash window in which the effect happened but the receipt did not, so
  // a retry can never report a false failure for its own write. A nil
  // toolCallID (a run_script write, which nothing replays) records no receipt.
  public func recordedSpaceWrite(
    _ id: SessionID,
    toolCallID: ToolCallID?,
    path: String,
    in group: GroupID,
    content: Data,
    ifMatchRev: Int64?,
    payload: @escaping @Sendable (Int64) -> ToolResultPayload,
  ) async throws -> RecordedWrite {
    let key = id.rawValue
    let mtime = SQLiteDateFormat.string(from: dateGen.now)
    let p = try await LiveFS.validatedFileTarget(MachineFolders.stored(path, mutating: true, in: writer))
    let home = try await writer.read { db in try Sessions.group(of: key, in: db) }
    try SessionHome.refuseForeignWrite(to: p, in: group, by: id, home: home)
    try await writer.read { db in try GroupWrites.refuseWrite(p, in: group, by: .session(id), acting: home, in: db) }
    let blob = try await blobs.stage(Array(content))
    let broadcast = broadcast
    let result: RecordedWrite = try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
      if let toolCallID, let recorded = try Sessions.receipt(key, toolCallID: toolCallID.rawValue, in: db) {
        return RecordedWrite(payload: recorded, replayed: true)
      }
      let head = try Substrate.head(p, group: group, in: db)
      // ifMatchRev nil is the creation case: the guard admitted the write only
      // because no read was logged, so the file must not exist yet.
      switch (ifMatchRev, head) {
      case (nil, nil):
        break
      case let (rev?, head?) where head.rev == rev:
        break
      default:
        throw SpaceError.versionMismatch(p.rawValue)
      }
      let outcome = try LiveFS.commitFile(p, group: group, acting: home, blob: blob, head: head, mtime: mtime, in: db)
      let rev: Int64
      switch outcome {
      case let .unchanged(current):
        rev = current
      case let .wrote(minted):
        rev = minted
        pending += [MutationEvent(group: group, path: p.rawValue, rev: Int(minted), kind: .write, entry: .file)]
      }
      let built = payload(rev)
      if let toolCallID {
        try Sessions.recordReceipt(
          key, toolCallID: toolCallID.rawValue, payload: try Sessions.encode(built), now: mtime, in: db,
        )
      }
      return RecordedWrite(payload: built, replayed: false)
    }
    return result
  }
}
