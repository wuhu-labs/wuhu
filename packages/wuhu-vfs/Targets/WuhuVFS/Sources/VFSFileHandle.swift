import Foundation

/// How a file handle opened by ``VFSNode/open(_:)`` will be used.
public enum VFSOpenMode: Sendable {
  case read
  case write
}

/// An open, stateful handle to one file's contents.
///
/// Returned by ``VFSNode/open(_:)``. Unlike the one-shot `readData`/`writeData`
/// on a node, a handle can *stage* edits and reconcile them at ``close()``.
/// Backends that version writes use optimistic concurrency: ``close()`` throws
/// ``VFSError/conflict(path:)`` when the node changed under the handle since it
/// was opened. Backends that do not stage (disk, in-memory) write through
/// immediately and never conflict.
///
/// A handle must be closed exactly once; dropping it without closing discards
/// any staged writes.
public protocol VFSFileHandle: Sendable {
  func readData() async throws -> Data
  func writeData(_ data: Data, append: Bool) async throws

  /// Commit any staged writes. Returns a backend-defined commit token (e.g. the
  /// new node version) or `nil` when the backend does not version writes.
  /// Throws ``VFSError/conflict(path:)`` if the node changed under the handle.
  @discardableResult
  func close() async throws -> Int64?
}

/// The default ``VFSFileHandle`` for backends that do not stage: every
/// operation forwards straight to the node, so there is nothing to reconcile.
struct PassthroughFileHandle: VFSFileHandle {
  let node: any VFSNode

  func readData() async throws -> Data {
    try await node.readData()
  }

  func writeData(_ data: Data, append: Bool) async throws {
    try await node.writeData(data, append: append)
  }

  func close() async throws -> Int64? { nil }
}
