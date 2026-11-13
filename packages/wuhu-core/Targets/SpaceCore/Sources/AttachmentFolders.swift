#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID
import SpaceFS
import Wuwei

/// `/_/conversations/<id>/attachments/…` in a group's tree: the attachments of the conversations homed there, files answered from each conversation's rows. A post writes one once and nothing rewrites it, so it has no revisions and reads the same at any of them.
struct AttachmentFolders: SpaceVFS {
  let base: any SpaceVFS
  let runtime: SpaceRuntime
  let writer: any DatabaseWriter
  let bucket: Bucket
  let group: GroupID

  private static let root = ["_", "conversations"]
  private static let token = VersionToken(rev: 0)

  func read(_ path: String) async throws -> (VersionToken, Data) {
    guard let components = inside(path) else { return try await base.read(path) }
    let hash = try file(components, at: path).blob
    return (Self.token, Data(try await bucket.bytes(hash)))
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    guard let components = inside(path) else { return try await base.reader(path) }
    return BucketReader(bucket: bucket, hash: try file(components, at: path).blob)
  }

  // The journal refuses every mutation under `/_/conversations/`: the paths are reserved.
  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    try await base.write(path, data, ifMatch: ifMatch)
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    try await base.delete(path, ifMatch: ifMatch)
  }

  func move(_ path: String, to destination: String) async throws {
    try await base.move(path, to: destination)
  }

  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    guard inside(path) != nil || isSystemFolder(path) else { return try await base.list(path, from: from, limit: limit) }
    return try await listBySlicing(path, from: from, limit: limit)
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    if isSystemFolder(path) {
      var (token, entries) = (Self.token, [Entry]())
      do { (token, entries) = try await base.list(path) } catch SpaceError.notFound {}
      entries.removeAll { $0.name == Self.root[1] }
      if !conversations().isEmpty { entries.append(directory(Self.root[1])) }
      guard !entries.isEmpty else { throw SpaceError.notFound(path) }
      return (token, entries.sorted { $0.name < $1.name })
    }
    guard let components = inside(path) else { return try await base.list(path) }
    let entries = components.count == 2 ? conversations().map { directory($0.rawValue) } : try children(of: components)
    guard !entries.isEmpty else { throw SpaceError.notFound(path) }
    return (Self.token, entries)
  }

  func stat(_ path: String) async throws -> Entry {
    guard let components = inside(path) else { return try await base.stat(path) }
    if components.count == 2 {
      guard !conversations().isEmpty else { throw SpaceError.notFound(path) }
      return directory(Self.root[1])
    }
    if let row = rows(components).first(where: { $0.path == rawPath(components) }) { return try entry(row) }
    guard try !children(of: components).isEmpty else { throw SpaceError.notFound(path) }
    return directory(components.last!)
  }

  private func inside(_ path: String) -> [String]? {
    guard let components = (try? SpacePath(validating: path))?.components, components.starts(with: Self.root) else { return nil }
    return components
  }

  private func isSystemFolder(_ path: String) -> Bool {
    (try? SpacePath(validating: path))?.components == [Self.root[0]]
  }

  private func rawPath(_ components: [String]) -> String {
    "/" + components.joined(separator: "/")
  }

  /// The attachments of the conversation `components` names, when it is homed in this group.
  private func rows(_ components: [String]) -> [AttachmentRow] {
    let cell: ConversationCell = runtime.worker().cell(ConversationCell.ID(components[2]))
    guard cell.record()?.group == group else { return [] }
    return cell.attachments()
  }

  private func file(_ components: [String], at path: String) throws -> AttachmentRow {
    guard components.count > 2 else { throw SpaceError.notAFile(path) }
    if let row = rows(components).first(where: { $0.path == rawPath(components) }) { return row }
    throw try children(of: components).isEmpty ? SpaceError.notFound(path) : SpaceError.notAFile(path)
  }

  private func children(of components: [String]) throws -> [Entry] {
    let prefix = rawPath(components) + "/"
    var entries: [Entry] = []
    for row in rows(components) where row.path.hasPrefix(prefix) {
      let rest = row.path.dropFirst(prefix.count).split(separator: "/")
      if rest.count == 1 {
        entries.append(try entry(row))
      } else if entries.last?.name != String(rest[0]) {
        entries.append(directory(String(rest[0])))
      }
    }
    return entries
  }

  /// The conversations homed in this group that hold an attachment: the one read here that spans cells, answered by the group's.
  private func conversations() -> [ConversationID] {
    runtime.worker().cell(GroupCell.ID(group.rawValue)).attachmentConversations()
  }

  private func entry(_ row: AttachmentRow) throws -> Entry {
    Entry(
      name: String(row.path.split(separator: "/").last!), kind: .file, size: row.size, lineCount: nil, token: Self.token,
      mtime: try SQLiteDateFormat.date(from: row.createdAt),
    )
  }

  private func directory(_ name: String) -> Entry {
    Entry(name: name, kind: .directory, size: 0, lineCount: nil, token: Self.token, mtime: .init(timeIntervalSince1970: 0))
  }
}
