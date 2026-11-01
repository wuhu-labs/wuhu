import GRDB
import Logging
import struct SpaceContract.GroupID
import enum SpaceContract.WmdAccess
import enum SpaceContract.WmdErrorCode
import SpaceFS
import Synchronization
import TaskLifetime

/// The space's live `.wmd` nodes, one actor each, created on first touch and
/// gone once they retire.
final class WmdHub: Sendable {
  private struct Key: Hashable {
    let group: GroupID
    let path: SpacePath
  }

  private let nodes = Mutex<[Key: WmdNode]>([:])
  private let store: WmdStore
  private let clock: any Clock<Duration>
  private let scope: TaskScope
  private let newPeer: @Sendable () -> UInt64

  init(store: WmdStore, clock: any Clock<Duration>, scope: TaskScope, newPeer: @escaping @Sendable () -> UInt64) {
    self.store = store
    self.clock = clock
    self.scope = scope
    self.newPeer = newPeer
  }

  /// Runs one node operation on the live node at `path`, on a fresh one when it retired first.
  func with<T>(_ group: GroupID, _ path: SpacePath, _ operation: (WmdNode) async throws -> T) async throws -> T {
    precondition(path.isWmd)
    while true {
      do { return try await operation(node(Key(group: group, path: path))) } catch is WmdNodeRetired {}
    }
  }

  /// Brings the file up to the document before a read: a live node's
  /// uncommitted edits, or a log left behind by a stop.
  func settle(_ group: GroupID, _ path: SpacePath) async throws {
    let live = nodes.withLock { $0[Key(group: group, path: path)] != nil }
    if !live { guard try await store.hasLog(group, path) else { return } }
    try await with(group, path) { try await $0.settle() }
  }

  func settle(under path: SpacePath, in group: GroupID) async throws {
    for key in live(under: path, in: group).keys { try await with(key.group, key.path) { try await $0.settle() } }
  }

  /// `rev` removed what was at `path` and under it: nodes that predate it close.
  func drop(under path: SpacePath, in group: GroupID, rev: Int64) async {
    for node in live(under: path, in: group).values { await node.removed(at: rev) }
  }

  /// Commits every live node's uncommitted edits, for a graceful stop.
  func checkpointAll() async {
    for node in nodes.withLock({ Array($0.values) }) { try? await node.settle() }
  }

  /// Every node a stop left with logged edits.
  func logged() async throws -> [(group: GroupID, path: SpacePath)] { try await store.logged() }

  private func live(under path: SpacePath, in group: GroupID) -> [Key: WmdNode] {
    nodes.withLock { nodes in
      nodes.filter { key, _ in
        key.group == group && (path.isRoot || key.path == path || key.path.rawValue.hasPrefix(path.rawValue + "/"))
      }
    }
  }

  private func node(_ key: Key) -> WmdNode {
    nodes.withLock { nodes in
      if let node = nodes[key] { return node }
      let node = WmdNode(
        group: key.group, path: key.path, store: store, clock: clock, scope: scope, newPeer: newPeer,
        retired: { [weak self] node in self?.remove(node, at: key) },
      )
      nodes[key] = node
      return node
    }
  }

  private func remove(_ node: WmdNode, at key: Key) {
    nodes.withLock { nodes in if nodes[key] === node { nodes[key] = nil } }
  }
}

extension Space {
  /// One client's connection to the live document at `path`, after its
  /// `hello` was authenticated: `frames` are its later frames, and the stream
  /// ends after an `error` or once `frames` end. A missing document is
  /// refused `notFound` unless `create` asks for it, empty. Whenever the
  /// space's groups or roles change, `reauthorize` answers the principal's
  /// access anew; a connection that lost what it holds closes.
  public func wmdChannel(
    _ group: GroupID, _ path: SpacePath, peer: String, name: String, access: WmdAccess, create: Bool,
    frames: AsyncStream<WmdInbound>, reauthorize: @escaping @Sendable () async -> WmdAccess?,
  ) async -> AsyncStream<WmdOutbound> {
    guard path.isWmd else { return Self.refused(.notWmd, "\(path.rawValue) does not end in .wmd") }
    let stored: SpacePath
    do { stored = try await MachineFolders.stored(path, mutating: false, in: writer) } catch {
      return Self.refused(.notFound, "\(path.rawValue) does not exist")
    }
    guard !stored.isReserved else { return Self.refused(.forbidden, "\(path.rawValue) is the space's own") }
    let node: WmdNode
    let id: String?
    let outbound: AsyncStream<WmdOutbound>
    do {
      (node, id, outbound) = try await wmd.with(group, stored) { node in
        let (id, outbound) = try await node.join(peer: peer, name: name, access: access, create: create)
        return (node, id, outbound)
      }
    } catch {
      return Self.refused(.internal, "\(error)")
    }
    guard let id else { return outbound }
    // Observed before the welcome can reach the client, so no access change slips past.
    let accessChanges = regionWakes([Table("groups"), Table("group_roles")], in: writer)
    do {
      _ = try taskScope.run("wmd-connection") {
        await withTaskGroup(of: Void.self) { tasks in
          tasks.addTask {
            for await message in frames {
              guard await node.receive(message, from: id) else { break }
            }
          }
          tasks.addTask {
            for await _ in accessChanges {
              guard await node.reauthorize(id, access: await reauthorize()) else { break }
            }
          }
          await tasks.next()
          tasks.cancelAll()
        }
        await node.leave(id)
      }
    } catch {
      await node.leave(id)
    }
    return outbound
  }

  /// Leaves no edit only in the log: a graceful stop's first step.
  func checkpointLiveDocuments() async {
    await uncancellable("A stop must not strand edits in memory") { [wmd] in await wmd.checkpointAll() }
  }

  /// Brings the files of documents a stop left with logged edits up to them.
  func recoverLiveDocuments() async {
    do {
      for (group, path) in try await wmd.logged() {
        do { try await wmd.settle(group, path) } catch {
          log.warning("Live document recovery failed", metadata: ["group": "\(group.rawValue)", "path": "\(path.rawValue)", "error": "\(error)"])
        }
      }
    } catch {
      log.warning("Live document recovery could not list logged documents", metadata: ["error": "\(error)"])
    }
  }

  private static func refused(_ code: WmdErrorCode, _ message: String) -> AsyncStream<WmdOutbound> {
    AsyncStream { continuation in
      continuation.yield(.control(.error(code: code, message: message)))
      continuation.finish()
    }
  }
}
