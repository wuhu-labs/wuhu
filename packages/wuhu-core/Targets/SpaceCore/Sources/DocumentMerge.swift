#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import LiveDocument
import SpaceFS

struct DocumentMaterial: Sendable {
  var history: String?
  var fileRev: Int64?
  var snapshot: Data?
  var updates: [Data] = []
  var base: Data?
  var notDocument: String?
  var text: Data?
  var hash: String?
}

struct DocumentSeed: Sendable {
  var history: String
  var fileRev: Int64?
  var snapshot: Data
  var notDocument: String?
}

struct DocumentPrepared: Sendable {
  enum History: Sendable {
    case current(String)
    case seed(DocumentSeed)
  }

  var history: History
  var update: Data?
}

/// The sole host merge seam: inputs and outputs are bytes, never a shared replica or a database handle.
struct DocumentMerge: Sendable {
  var prepare: @Sendable (DocumentMaterial, SpacePath, String, DocumentBase, Bool, UInt64, UInt64) async throws -> DocumentPrepared

  static let live = Self { material, path, text, base, checkout, peer, seedPeer in
    try prepare(material, path, text, base, checkout, peer, seedPeer)
  }

  private static func prepare(
    _ material: DocumentMaterial, _ path: SpacePath, _ text: String, _ base: DocumentBase, _ checkout: Bool,
    _ peer: UInt64, _ seedPeer: UInt64,
  ) throws -> DocumentPrepared {
    let replica: LiveReplica
    let history: DocumentPrepared.History
    let frontiers: Data?
    let notDocument: String?
    if let identity = material.history {
      do throws(LiveError) {
        replica = try LiveReplica(path.liveKind!.format, snapshot: material.snapshot!, updates: material.updates)
      } catch { preconditionFailure("\(path.rawValue) cannot rebuild its own history: \(error)") }
      history = .current(identity)
      frontiers = material.base
      notDocument = material.notDocument
    } else {
      replica = LiveReplica(path.liveKind!.format)
      var reason: String?
      if let bytes = material.text {
        if let string = String(validating: bytes, as: UTF8.self) {
          do throws(LiveError) {
            if let merged = try replica.merge(text: string, base: nil, peer: seedPeer, restoring: true) {
              try replica.importUpdate(merged.update)
            }
          } catch {
            guard case let .syntax(syntax) = error else { preconditionFailure("a seed failed: \(error)") }
            reason = "line \(syntax.line): \(syntax.reason)"
          }
        } else { reason = "a .\(path.liveKind!.rawValue) file is UTF-8 text" }
      }
      let seed = DocumentSeed(
        history: UUID().uuidString, fileRev: material.fileRev, snapshot: try! replica.snapshot(), notDocument: reason,
      )
      history = .seed(seed)
      notDocument = reason
      frontiers = try base.frontiers(path, rev: material.fileRev, notDocument: reason) { rev in
        guard rev == material.fileRev else { throw SpaceError.versionMismatch(path.rawValue) }
        return replica.frontiers
      }
    }
    do throws(LiveError) {
      let update = try replica.merge(
        text: text, base: frontiers, peer: peer, restoring: checkout || material.fileRev == nil || notDocument != nil,
      )?.update
      return DocumentPrepared(history: history, update: update)
    } catch {
      guard case let .syntax(syntax) = error else { preconditionFailure("\(path.rawValue) cannot merge its own frontiers: \(error)") }
      throw SpaceError.liveSyntax(path: path.rawValue, line: syntax.line, reason: syntax.reason)
    }
  }
}

extension DocumentBase {
  func frontiers(_ path: SpacePath, rev: Int64?, notDocument: String?, checkpoint: (Int64) throws -> Data) throws -> Data? {
    switch self {
    case .latest:
      guard let rev, notDocument == nil else { return nil }
      return try checkpoint(rev)
    case let .current(expected):
      guard rev == expected else { throw SpaceError.versionMismatch(path.rawValue) }
      return notDocument == nil ? try checkpoint(expected) : nil
    case let .read(read):
      if read == rev { return notDocument == nil ? try checkpoint(read) : nil }
      guard notDocument == nil else { throw SpaceError.versionMismatch(path.rawValue) }
      return try checkpoint(read)
    }
  }
}
