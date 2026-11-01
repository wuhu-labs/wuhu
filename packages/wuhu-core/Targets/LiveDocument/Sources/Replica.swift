#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Loro

/// A document kind kept as one Loro doc per node: its schema, its agent view, and the agent
/// view's merge back into the doc.
public struct LiveFormat: Sendable {
  let configure: @Sendable (LoroDoc) -> Void
  let text: @Sendable (LoroDoc) -> String
  let apply: @Sendable (_ text: String, _ doc: LoroDoc, _ peer: UInt64, _ restoring: Bool) throws -> [String]

  /// `apply` edits the doc into what the agent's text says and answers notes on what it did
  /// beyond that; it throws `LiveSyntaxError` to refuse the text. `restoring` is an older
  /// revision's text coming back, which may name what the doc no longer has.
  public init(
    configure: @escaping @Sendable (LoroDoc) -> Void, text: @escaping @Sendable (LoroDoc) -> String,
    apply: @escaping @Sendable (_ text: String, _ doc: LoroDoc, _ peer: UInt64, _ restoring: Bool) throws -> [String],
  ) {
    self.configure = configure
    self.text = text
    self.apply = apply
  }
}

/// An agent's text refused whole.
public struct LiveSyntaxError: Error, Hashable, Sendable, CustomStringConvertible {
  /// 1-based.
  public let line: Int
  public let reason: String

  public init(line: Int, reason: String) {
    self.line = line
    self.reason = reason
  }

  public var description: String { "line \(self.line): \(self.reason)" }
}

public enum LiveError: Error, Hashable, Sendable {
  case syntax(LiveSyntaxError)
  /// Loro refused the bytes.
  case invalidUpdate(String)
  /// The update names operations this replica has not seen; Loro holds it until they arrive.
  case missingDependencies
  case invalidVersion
}

/// An agent write as Loro operations.
public struct LiveMerge: Hashable, Sendable {
  public let update: Data
  public let notes: [String]
}

/// One live node's Loro document. Not `Sendable`: exactly one actor owns a replica.
public final class LiveReplica {
  let format: LiveFormat
  let doc: LoroDoc

  public init(_ format: LiveFormat) {
    self.format = format
    self.doc = LoroDoc()
    format.configure(self.doc)
  }

  /// Rebuilds from a snapshot and the updates logged after it, in log order.
  public init(_ format: LiveFormat, snapshot: Data?, updates: [Data]) throws(LiveError) {
    self.format = format
    self.doc = LoroDoc()
    format.configure(self.doc)
    do {
      if let snapshot { _ = try self.doc.import(bytes: snapshot) }
      if !updates.isEmpty { _ = try self.doc.importBatch(bytes: updates) }
    } catch {
      throw .invalidUpdate(String(describing: error))
    }
  }

  /// The agent view.
  public var text: String { self.format.text(self.doc) }

  public func text(at frontiers: Data) throws(LiveError) -> String {
    try self.format.text(self.fork(at: frontiers))
  }

  public func snapshot() throws(LiveError) -> Data {
    do { return try self.doc.export(mode: .snapshot) } catch { throw .invalidUpdate(String(describing: error)) }
  }

  public var versionVector: Data { self.doc.oplogVv().encode() }
  public var frontiers: Data { self.doc.oplogFrontiers().encode() }

  /// nil when `versionVector` already holds everything here.
  public func updates(since versionVector: Data) throws(LiveError) -> Data? {
    let theirs: VersionVector
    do { theirs = try VersionVector.decode(bytes: versionVector) } catch { throw .invalidVersion }
    guard !theirs.includesVv(other: self.doc.oplogVv()) else { return nil }
    do { return try self.doc.export(mode: .updates(from: theirs)) } catch { throw .invalidUpdate(String(describing: error)) }
  }

  /// Returns whether the update added anything.
  @discardableResult
  public func importUpdate(_ bytes: Data) throws(LiveError) -> Bool {
    let before = self.doc.oplogVv()
    let status: ImportStatus
    do { status = try self.doc.import(bytes: bytes) } catch { throw .invalidUpdate(String(describing: error)) }
    if let pending = status.pending, !pending.isEmpty { throw .missingDependencies }
    return !self.doc.oplogVv().eq(other: before)
  }

  /// An agent's text as edits made at `base` (the frontiers the agent read), as `peer`, for the
  /// caller to log and then import; concurrent edits since `base` survive. nil when the text
  /// changes nothing. `peer` must be new to the document: a fork at an older `base` would reuse a
  /// known peer's counters.
  public func merge(text: String, base: Data?, peer: UInt64, restoring: Bool = false) throws(LiveError) -> LiveMerge? {
    let fork = try base.map { frontiers throws(LiveError) in try self.fork(at: frontiers) } ?? self.doc.fork()
    self.format.configure(fork)
    do {
      try fork.setPeerId(peer: peer)
      let before = fork.oplogVv()
      let notes = try self.format.apply(text, fork, peer, restoring)
      fork.commit()
      guard !fork.oplogVv().eq(other: before) else { return nil }
      return try LiveMerge(update: fork.export(mode: .updates(from: before)), notes: notes)
    } catch let error as LiveSyntaxError {
      throw .syntax(error)
    } catch {
      throw .invalidUpdate(String(describing: error))
    }
  }

  private func fork(at frontiers: Data) throws(LiveError) -> LoroDoc {
    do {
      let decoded = try Frontiers.decode(bytes: frontiers)
      return try self.doc.forkAt(frontiers: decoded)
    } catch {
      throw .invalidVersion
    }
  }
}
