#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Loro

enum WmdMarkdown {
  /// The agent view's spelling of `markdown`: what a write of it reads back as.
  static func canonical(_ markdown: String) throws(WmdSyntaxError) -> String {
    try Content(markdown: markdown).markdown
  }
}

public enum WmdError: Error, Hashable, Sendable {
  case syntax(WmdSyntaxError)
  /// Loro refused the bytes.
  case invalidUpdate(String)
  /// The update names operations this replica has not seen; Loro holds it until they arrive.
  case missingDependencies
  case invalidVersion
}

/// One `.wmd` node's Loro document. Not `Sendable`: exactly one actor owns a replica.
public final class WmdReplica {
  let doc: LoroDoc

  public init() {
    self.doc = LoroDoc()
    configure(self.doc)
  }

  /// Rebuilds from a snapshot and the updates logged after it, in log order.
  public init(snapshot: Data?, updates: [Data]) throws(WmdError) {
    self.doc = LoroDoc()
    configure(self.doc)
    do {
      if let snapshot { _ = try self.doc.import(bytes: snapshot) }
      if !updates.isEmpty { _ = try self.doc.importBatch(bytes: updates) }
    } catch {
      throw .invalidUpdate(String(describing: error))
    }
  }

  public var markdown: String { project(self.doc).content.markdown }

  public func snapshot() throws(WmdError) -> Data {
    do { return try self.doc.export(mode: .snapshot) } catch { throw .invalidUpdate(String(describing: error)) }
  }

  public var versionVector: Data { self.doc.oplogVv().encode() }
  public var frontiers: Data { self.doc.oplogFrontiers().encode() }

  func markdown(at frontiers: Data) throws(WmdError) -> String {
    try project(self.fork(at: frontiers)).content.markdown
  }

  /// nil when `versionVector` already holds everything here.
  public func updates(since versionVector: Data) throws(WmdError) -> Data? {
    let theirs: VersionVector
    do { theirs = try VersionVector.decode(bytes: versionVector) } catch { throw .invalidVersion }
    guard !theirs.includesVv(other: self.doc.oplogVv()) else { return nil }
    do { return try self.doc.export(mode: .updates(from: theirs)) } catch { throw .invalidUpdate(String(describing: error)) }
  }

  /// Returns whether the update added anything.
  @discardableResult
  public func importUpdate(_ bytes: Data) throws(WmdError) -> Bool {
    let before = self.doc.oplogVv()
    let status: ImportStatus
    do { status = try self.doc.import(bytes: bytes) } catch { throw .invalidUpdate(String(describing: error)) }
    if let pending = status.pending, !pending.isEmpty { throw .missingDependencies }
    return !self.doc.oplogVv().eq(other: before)
  }

  /// An agent's markdown as edits made at `base` (the frontiers the agent read), as `peer`, for
  /// the caller to log and then import; concurrent edits since `base` survive. nil when the
  /// markdown changes nothing. `peer` must be new to the document: a fork at an older `base`
  /// would reuse a known peer's counters.
  public func merge(markdown: String, base: Data?, peer: UInt64) throws(WmdError) -> Data? {
    let target: Content
    do { target = try Content(markdown: markdown) } catch { throw .syntax(error) }
    let fork = try base.map { frontiers throws(WmdError) in try self.fork(at: frontiers) } ?? self.doc.fork()
    configure(fork)
    do {
      try fork.setPeerId(peer: peer)
      let before = fork.oplogVv()
      try apply(target, to: fork)
      fork.commit()
      guard !fork.oplogVv().eq(other: before) else { return nil }
      return try fork.export(mode: .updates(from: before))
    } catch {
      throw .invalidUpdate(String(describing: error))
    }
  }

  private func fork(at frontiers: Data) throws(WmdError) -> LoroDoc {
    do {
      let decoded = try Frontiers.decode(bytes: frontiers)
      return try self.doc.forkAt(frontiers: decoded)
    } catch {
      throw .invalidVersion
    }
  }
}
