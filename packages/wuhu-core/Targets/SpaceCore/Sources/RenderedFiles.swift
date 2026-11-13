#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import Wuwei

/// `/_/rendered/<hash>`: what a generation's requests send besides their messages, the system text and tool list its line 0 names. Content-addressed and immutable, without revisions; a group reads the ones its own sessions were sent.
public enum RenderedFiles {
  static let root = ["_", "rendered"]

  public static func contains(_ path: String) -> Bool {
    (try? SpacePath(validating: path))?.components.starts(with: root) == true
  }

  public static func path(_ hash: String) -> String { "/_/rendered/\(hash)" }
}

extension Space {
  /// The rendered files `group`'s sessions were sent; only paths `RenderedFiles.contains` names resolve.
  public nonisolated func renderedFiles(in group: GroupID) -> any SpaceVFS {
    RenderedVFS(store: sessions, group: group)
  }
}

struct RenderedVFS: SpaceVFS {
  let store: SessionStore
  let group: GroupID

  private static let token = VersionToken(rev: 0)

  func read(_ path: String) async throws -> (VersionToken, Data) {
    (Self.token, try await content(path))
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    SpaceDataReader(try await content(path))
  }

  func write(_ path: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken {
    throw SpaceError.sentViewReadOnly(path)
  }

  func delete(_ path: String, ifMatch _: VersionToken?) async throws {
    throw SpaceError.sentViewReadOnly(path)
  }

  func move(_ path: String, to _: String) async throws {
    throw SpaceError.sentViewReadOnly(path)
  }

  // Nothing lists them: a hash is learned from a transcript's position 0.
  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    guard try hash(path) == nil else { throw SpaceError.notADirectory(path) }
    return (Self.token, [])
  }

  func stat(_ path: String) async throws -> Entry {
    let epoch = Date(timeIntervalSince1970: 0)
    guard let hash = try hash(path) else { return Entry(name: "rendered", kind: .directory, size: 0, lineCount: nil, token: Self.token, mtime: epoch) }
    let data = try await content(path)
    return Entry(name: hash, kind: .file, size: data.count, lineCount: data.count(where: { $0 == UInt8(ascii: "\n") }), token: Self.token, mtime: epoch)
  }

  private func hash(_ path: String) throws -> String? {
    guard let p = try? SpacePath(validating: path), p.components.starts(with: RenderedFiles.root), p.components.count <= 3 else { throw SpaceError.notFound(path) }
    return p.components.count == 3 ? p.components[2] : nil
  }

  private func content(_ path: String) async throws -> Data {
    guard let hash = try hash(path) else { throw SpaceError.notAFile(path) }
    guard let bytes = try await store.rendered(hash, sentIn: group) else { throw SpaceError.notFound(path) }
    return Data(bytes)
  }
}

extension SessionStore {
  /// The rendered blob `hash`, when a session of `group` has it as a generation's line 0 or as its current prompt.
  func rendered(_ hash: String, sentIn group: GroupID) async throws -> [UInt8]? {
    let line = try Sessions.preambleLine(rendered: hash)
    guard runtime.worker().cell(SpaceCell.ID("space")).renders(hash, line: line, in: group) else { return nil }
    return try await bucket.bytes(hash)
  }
}

extension SpaceCell {
  /// Whether a session of `group` has `rendered` as its current prompt or as a generation's line 0, which carries
  /// the hash in place of the bytes.
  func renders(_ rendered: String, line: String, in group: GroupID) -> Bool {
    db.one(
      """
      SELECT EXISTS (
        SELECT 1 FROM sessions s WHERE s.grp = ?
          AND (EXISTS (SELECT 1 FROM session_prompts p WHERE p.session_id = s.id AND p.rendered = ?)
            OR EXISTS (SELECT 1 FROM session_lines l WHERE l.session_id = s.id AND l.position = 0 AND l.message = ?))
      )
      """,
      .text(group.rawValue), .text(rendered), .text(line),
    )?.integer == 1
  }
}
