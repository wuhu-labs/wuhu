#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import OrderedCollections
import struct SpaceContract.GroupID
import enum SpaceContract.WmdAccess
import enum SpaceContract.WmdErrorCode
import enum SpaceContract.WmdFrame
import struct SpaceContract.WmdPeer
import enum SpaceContract.WmdServerControl
import SpaceFS
import TaskLifetime
import WmdDocument

public enum WmdOutbound: Sendable, Equatable {
  case control(WmdServerControl)
  case frame(WmdFrame)
}

public enum WmdInbound: Sendable, Equatable {
  case binary([UInt8])
  case text(String)
}

private struct WmdRefusal: Error {
  let code: WmdErrorCode
  let message: String
}

/// The node left its hub before the operation began; the hub retries on a fresh one.
struct WmdNodeRetired: Error {}

/// What an agent's markdown is merged as.
enum WmdBase: Sendable, Equatable {
  /// Edits made at the latest checkpoint.
  case latest
  /// Edits made at the checkpoint that wrote this revision, the one the agent read.
  case read(Int64)
  /// Edits made at the latest checkpoint, which must have written this revision.
  case current(Int64)
}

/// One open `.wmd` node: the only writer of its file, its Loro document, its
/// log and its checkpoints, and the relay between its connections. Nothing
/// reaches a connection or an agent before it is durable. It retires once
/// nothing uses it, and drops its connections when its file is gone.
actor WmdNode {
  let group: GroupID
  let path: SpacePath
  private let store: WmdStore
  private let clock: any Clock<Duration>
  private let scope: TaskScope
  private let newPeer: @Sendable () -> UInt64
  private let retired: @Sendable (WmdNode) -> Void
  private var life = Life.unloaded
  private var busy = 0
  private var connections: OrderedDictionary<String, Connection> = [:]
  private var connectionCount = 0
  private var idle: Task<Void, Never>?
  private var lastWrite: (@Sendable () async -> Void)?
  private var pendingWrites = 0
  /// The newest space revision the node's state reflects.
  private var seen: Int64 = 0
  /// The newest revision that removed the node's file: state read before it is stale.
  private var removedAt: Int64 = 0

  static let idleCheckpoint = Duration.seconds(5)
  static let outboundLimit = 256

  private enum Life {
    case unloaded
    case loaded(Doc)
    case retired
  }

  private final class Doc {
    let replica: WmdReplica
    /// The file revision the node last committed or read; nil while there is no file.
    var fileRev: Int64?
    /// The frontiers of the checkpoint that wrote `fileRev`; nil before the first.
    var frontiers: Data?
    /// Why the file's text is no document; only a write replaces it.
    var foreign: String?
    var lineage = WmdLineage.continues
    var nextSeq: Int64
    var edits = 0
    var committed = 0
    var dirty: Bool { edits != committed }

    init(_ replica: WmdReplica, fileRev: Int64?, frontiers: Data?, nextSeq: Int64) {
      self.replica = replica
      self.fileRev = fileRev
      self.frontiers = frontiers
      self.nextSeq = nextSeq
    }
  }

  private struct Connection {
    let peer: WmdPeer
    let outbound: AsyncStream<WmdOutbound>.Continuation
    var synced = false
    var presence: [UInt8]?
  }

  init(
    group: GroupID, path: SpacePath, store: WmdStore, clock: any Clock<Duration>, scope: TaskScope,
    newPeer: @escaping @Sendable () -> UInt64, retired: @escaping @Sendable (WmdNode) -> Void,
  ) {
    self.group = group
    self.path = path
    self.store = store
    self.clock = clock
    self.scope = scope
    self.newPeer = newPeer
    self.retired = retired
  }

  // MARK: Connections

  /// nil with a stream holding only the refusal when the node cannot be opened.
  func join(peer: String, name: String, access: WmdAccess, create: Bool) async throws -> (id: String?, outbound: AsyncStream<WmdOutbound>) {
    try await operation {
      let (outbound, continuation) = AsyncStream.makeStream(of: WmdOutbound.self, bufferingPolicy: .bufferingNewest(Self.outboundLimit))
      do {
        let doc = try await refusing { try await self.loaded() }
        if let foreign = doc.foreign { throw WmdRefusal(code: .notWmd, message: "\(path.rawValue): \(foreign)") }
        if doc.fileRev == nil {
          guard create, access == .write else { throw WmdRefusal(code: .notFound, message: "\(path.rawValue) does not exist") }
          doc.edits += 1
          _ = try await refusing { try await self.commit(acting: self.group, attribution: nil) }
        }
        connectionCount += 1
        let id = String(connectionCount)
        connections[id] = Connection(peer: WmdPeer(connection: id, peer: peer, name: name, access: access), outbound: continuation)
        deliver(.control(.welcome(connection: id, name: name, access: access, peers: roster, rev: doc.fileRev.map { Int($0) })), to: id)
        send(.control(.peers(peers: roster)), except: id)
        return (id, outbound)
      } catch {
        let refusal = error as? WmdRefusal ?? WmdRefusal(code: .internal, message: "\(error)")
        continuation.yield(.control(.error(code: refusal.code, message: refusal.message)))
        continuation.finish()
        return (nil, outbound)
      }
    }
  }

  /// Whether the connection is still open after `message`.
  func receive(_ message: WmdInbound, from id: String) async -> Bool {
    let open = try? await operation { () async -> Bool in
      guard connections[id] != nil, case let .loaded(doc) = life else { return false }
      do {
        guard case let .binary(bytes) = message else {
          throw WmdRefusal(code: .protocolViolation, message: "after hello, every client frame is binary")
        }
        let frame: WmdFrame
        do throws(WmdFrame.Malformed) { frame = try WmdFrame(bytes: bytes) } catch {
          throw WmdRefusal(code: .protocolViolation, message: "unknown frame tag \(error.tag.map(String.init) ?? "(empty frame)")")
        }
        try await receive(frame, from: id, doc: doc)
      } catch {
        close(id, error as? WmdRefusal ?? WmdRefusal(code: .internal, message: "\(error)"))
      }
      return connections[id] != nil
    }
    return open ?? false
  }

  private func receive(_ frame: WmdFrame, from id: String, doc: Doc) async throws {
    switch frame {
    case let .sync(versionVector):
      // The catch-up must hold only what is logged.
      while pendingWrites > 0 { await lastWrite?() }
      guard connections[id] != nil, case .loaded = life else { return }
      let missing: Data?
      do { missing = try doc.replica.updates(since: Data(versionVector)) } catch {
        throw WmdRefusal(code: .protocolViolation, message: "the sync frame holds no version vector")
      }
      if let missing { deliver(.frame(.update(Array(missing))), to: id) }
      deliver(.frame(.synced(versionVector: Array(doc.replica.versionVector))), to: id)
      connections[id]?.synced = true
      for (other, connection) in connections where other != id {
        if let presence = connection.presence { deliver(.frame(.presence(presence)), to: id) }
      }
    case let .update(bytes):
      guard connections[id]!.synced else { throw WmdRefusal(code: .protocolViolation, message: "an update before synced") }
      guard connections[id]!.peer.access == .write else {
        throw WmdRefusal(code: .readOnly, message: "this connection reads \(path.rawValue) only")
      }
      let changed: Bool
      do throws(WmdError) { changed = try doc.replica.importUpdate(Data(bytes)) } catch {
        switch error {
        case .missingDependencies:
          throw WmdRefusal(code: .missingDependencies, message: "the update depends on operations the server lacks")
        default:
          throw WmdRefusal(code: .invalidUpdate, message: "\(error)")
        }
      }
      if changed {
        let seq = doc.nextSeq
        doc.nextSeq += 1
        doc.edits += 1
        do { try await serialized { node in try await node.appendLog(seq, bytes) } } catch {
          return drop(Self.failure(error, at: path))
        }
        send(.frame(.update(bytes)), except: id)
        scheduleIdleCheckpoint()
      }
      deliver(.control(.ack(count: 1)), to: id)
    case let .presence(bytes):
      connections[id]!.presence = bytes
      send(.frame(.presence(bytes)), except: id)
    case .synced:
      throw WmdRefusal(code: .protocolViolation, message: "synced is the server's frame")
    }
  }

  /// Whether the connection stays open under the principal's `access` now; nil when it may no longer read.
  func reauthorize(_ id: String, access: WmdAccess?) async -> Bool {
    let open = try? await operation { () -> Bool in
      guard let connection = connections[id] else { return false }
      switch (connection.peer.access, access) {
      case (_, nil):
        close(id, WmdRefusal(code: .forbidden, message: "\(path.rawValue) is no longer readable from here"))
      case (.write, .read):
        close(id, WmdRefusal(code: .readOnly, message: "this connection may no longer write \(path.rawValue)"))
      case (.read, _), (.write, .write):
        break
      }
      return connections[id] != nil
    }
    return open ?? false
  }

  func leave(_ id: String) async {
    _ = try? await operation {
      guard let connection = connections.removeValue(forKey: id) else { return }
      connection.outbound.finish()
      send(.control(.peers(peers: roster)))
    }
  }

  private func close(_ id: String, _ refusal: WmdRefusal) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    connection.outbound.yield(.control(.error(code: refusal.code, message: refusal.message)))
    connection.outbound.finish()
    send(.control(.peers(peers: roster)))
  }

  private var roster: [WmdPeer] { connections.values.map(\.peer) }

  private func send(_ outbound: WmdOutbound, except skipped: String? = nil) {
    for (id, connection) in connections where id != skipped && (connection.synced || !Self.awaitsSync(outbound)) {
      deliver(outbound, to: id)
    }
  }

  /// A connection too slow to take its frames has lost some: it closes, to reconnect and sync anew.
  private func deliver(_ outbound: WmdOutbound, to id: String) {
    guard let connection = connections[id], case .dropped = connection.outbound.yield(outbound) else { return }
    connections[id] = nil
    connection.outbound.finish()
    send(.control(.peers(peers: roster)))
  }

  /// Document bytes reach a connection only after its sync, whose catch-up holds everything before.
  private static func awaitsSync(_ outbound: WmdOutbound) -> Bool {
    if case .frame = outbound { true } else { false }
  }

  // MARK: Agent view

  /// Commits what the connections changed since the last checkpoint.
  func settle() async throws {
    try await operation {
      let doc = try await loaded()
      if doc.dirty { try await commit(acting: group, attribution: nil) }
    }
  }

  /// An agent's markdown, merged as edits made at `base`. A file whose text is
  /// no document is replaced. With `checkout`, the commit journals as that
  /// revision's checkout.
  func write(
    _ data: Data, base: WmdBase, createOnly: Bool, acting: GroupID, attribution: RevisionAttribution?, checkout: Int64? = nil,
  ) async throws -> Int64 {
    guard let markdown = String(validating: data, as: UTF8.self) else {
      throw SpaceError.wmdSyntax(path: path.rawValue, line: nil, reason: Self.notUTF8)
    }
    return try await operation {
      let doc = try await loaded()
      if createOnly, doc.fileRev != nil { throw SpaceError.alreadyExists(path.rawValue) }
      let from = try await frontiers(for: base, of: doc)
      let update = try merge(markdown, at: from, into: doc)
      if let update {
        doc.edits += 1
        do throws(WmdError) { try doc.replica.importUpdate(update) } catch {
          try abandon(error)
        }
      } else if doc.fileRev == nil || doc.foreign != nil {
        doc.edits += 1
      } else if !doc.dirty, let rev = doc.fileRev {
        return rev
      }
      return try await commit(acting: acting, attribution: attribution, checkout: checkout, relaying: update)
    }
  }

  private func frontiers(for base: WmdBase, of doc: Doc) async throws -> Data? {
    switch base {
    case .latest:
      return doc.frontiers
    case let .current(rev):
      guard doc.fileRev == rev else { throw SpaceError.versionMismatch(path.rawValue) }
      return doc.frontiers
    case let .read(rev):
      if rev == doc.fileRev { return doc.frontiers }
      guard doc.foreign == nil, let frontiers = try await store.frontiers(group, path, at: rev) else {
        throw SpaceError.versionMismatch(path.rawValue)
      }
      return frontiers
    }
  }

  // MARK: Life

  /// Every entry point runs through here: a retired node refuses, and the last
  /// operation out of a node no connection holds checkpoints and retires it,
  /// however its last connection went.
  private func operation<T>(_ body: () async throws -> T) async throws -> T {
    if case .retired = life { throw WmdNodeRetired() }
    busy += 1
    defer {
      busy -= 1
      if busy == 0, connections.isEmpty { retire() }
    }
    do {
      let result = try await body()
      await checkpointIfUnheld()
      return result
    } catch {
      await checkpointIfUnheld()
      throw error
    }
  }

  private func checkpointIfUnheld() async {
    guard busy == 1, connections.isEmpty, case let .loaded(doc) = life, doc.dirty else { return }
    _ = try? await commit(acting: group, attribution: nil)
  }

  private func retire() {
    if case .retired = life { return }
    life = .retired
    idle?.cancel()
    retired(self)
  }

  /// The node can no longer stand for its file: its connections close and it retires.
  private func drop(_ refusal: WmdRefusal) {
    for id in connections.keys { close(id, refusal) }
    retire()
  }

  /// `rev` deleted, moved or replaced the node's file.
  func removed(at rev: Int64) {
    removedAt = max(removedAt, rev)
    guard case .loaded = life, seen < rev else { return }
    drop(WmdRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted"))
  }

  // MARK: Checkpoints

  private func loaded() async throws -> Doc {
    while true {
      switch life {
      case let .loaded(doc): return doc
      case .retired: throw SpaceError.notFound(path.rawValue)
      case .unloaded: break
      }
      let stored = try await store.load(group, path)
      switch life {
      case let .loaded(doc): return doc
      case .retired: throw SpaceError.notFound(path.rawValue)
      case .unloaded: break
      }
      guard stored.seen >= removedAt else { continue }
      seen = stored.seen
      let doc = try build(stored)
      life = .loaded(doc)
      if doc.dirty { try await commit(acting: group, attribution: nil) }
      return doc
    }
  }

  /// The document the rows hold when the latest checkpoint wrote the file;
  /// otherwise the file's text as a document of its own, starting history over.
  private func build(_ stored: WmdStored) throws -> Doc {
    switch (stored.file, stored.checkpoint, stored.snapshot) {
    case let (file?, checkpoint?, snapshot?) where checkpoint.rev == file.rev:
      let doc = try Doc(
        WmdReplica(snapshot: snapshot, updates: stored.updates), fileRev: file.rev, frontiers: checkpoint.frontiers,
        nextSeq: stored.nextSeq,
      )
      if !stored.updates.isEmpty { doc.edits += 1 }
      return doc
    case let (file?, _, _):
      let doc = Doc(WmdReplica(), fileRev: file.rev, frontiers: nil, nextSeq: stored.nextSeq)
      do {
        guard let markdown = String(validating: file.content, as: UTF8.self) else {
          throw SpaceError.wmdSyntax(path: path.rawValue, line: nil, reason: Self.notUTF8)
        }
        if let update = try merge(markdown, at: nil, into: doc) { try doc.replica.importUpdate(update) }
        doc.lineage = .restarts(seed: file.rev)
        doc.edits += 1
      } catch let SpaceError.wmdSyntax(_, line, reason) {
        doc.foreign = line.map { "line \($0): \(reason)" } ?? reason
        doc.lineage = .restarts(seed: nil)
      }
      return doc
    case (nil, _, _):
      let doc = Doc(WmdReplica(), fileRev: nil, frontiers: nil, nextSeq: stored.nextSeq)
      doc.lineage = .restarts(seed: nil)
      return doc
    }
  }

  /// The update that makes the document read `markdown`, as edits made at `base`; nil when it already does.
  private func merge(_ markdown: String, at base: Data?, into doc: Doc) throws -> Data? {
    do throws(WmdError) { return try doc.replica.merge(markdown: markdown, base: base, peer: newPeer()) } catch {
      if case let .syntax(syntax) = error { throw SpaceError.wmdSyntax(path: path.rawValue, line: syntax.line, reason: "\(syntax.problem)") }
      throw error
    }
  }

  private func appendLog(_ seq: Int64, _ bytes: [UInt8]) async throws {
    guard case let .loaded(doc) = life else { throw WmdFileGone() }
    try await store.append(group, path, seq: seq, Data(bytes), expecting: doc.fileRev)
  }

  /// A commit that fails leaves the document ahead of anything durable, so the node drops.
  @discardableResult
  private func commit(
    acting: GroupID, attribution: RevisionAttribution?, checkout: Int64? = nil, relaying update: Data? = nil,
  ) async throws -> Int64 {
    do {
      return try await serialized { node in
        try await node.commitNow(acting: acting, attribution: attribution, checkout: checkout, relaying: update)
      }
    } catch {
      try abandon(error)
    }
  }

  private func abandon(_ error: any Error) throws -> Never {
    let refusal = Self.failure(error, at: path)
    drop(refusal)
    throw refusal.code == .notFound ? SpaceError.notFound(path.rawValue) : error
  }

  private static func failure(_ error: any Error, at path: SpacePath) -> WmdRefusal {
    error is WmdFileGone
      ? WmdRefusal(code: .notFound, message: "\(path.rawValue) was moved or deleted")
      : WmdRefusal(code: .internal, message: "\(error)")
  }

  /// The node's store writes run one at a time, in the order they were asked for.
  private func serialized<T: Sendable>(_ write: @escaping @Sendable (isolated WmdNode) async throws -> T) async throws -> T {
    let previous = lastWrite
    pendingWrites += 1
    let task: Task<T, any Error>
    do {
      task = try scope.run("wmd-write") {
        await previous?()
        return try await Self.counted(write, on: self)
      }
    } catch {
      pendingWrites -= 1
      throw error
    }
    lastWrite = { _ = await task.result }
    return try await task.value
  }

  private static func counted<T: Sendable>(
    _ write: @Sendable (isolated WmdNode) async throws -> T, on node: isolated WmdNode,
  ) async throws -> T {
    defer { node.pendingWrites -= 1 }
    return try await write(node)
  }

  private func commitNow(acting: GroupID, attribution: RevisionAttribution?, checkout: Int64?, relaying update: Data?) async throws -> Int64 {
    guard case let .loaded(doc) = life else { throw WmdFileGone() }
    let announced = doc.fileRev
    let edits = doc.edits
    let commit = try WmdCommit(
      markdown: doc.replica.markdown, snapshot: doc.replica.snapshot(), frontiers: doc.replica.frontiers, through: doc.nextSeq - 1,
      expecting: doc.fileRev, lineage: doc.lineage, checkout: checkout, acting: acting, attribution: attribution,
    )
    let rev = try await store.commit(group, path, commit)
    doc.fileRev = rev
    doc.frontiers = commit.frontiers
    doc.foreign = nil
    doc.lineage = .continues
    doc.committed = edits
    seen = max(seen, rev)
    if let update { send(.frame(.update(Array(update)))) }
    if rev != announced { send(.control(.checkpoint(rev: Int(rev)))) }
    return rev
  }

  private func scheduleIdleCheckpoint() {
    idle?.cancel()
    let clock = clock
    idle = try? scope.run("wmd-idle-checkpoint") {
      guard (try? await clock.sleep(for: Self.idleCheckpoint)) != nil else { return }
      _ = try? await self.operation {
        guard case let .loaded(doc) = self.life, doc.dirty else { return }
        try await self.commit(acting: self.group, attribution: nil)
      }
    }
  }

  private func refusing<T>(_ body: () async throws -> T) async throws -> T {
    do { return try await body() } catch let error as SpaceError {
      switch error {
      case .notAFile, .pathIsDirectory: throw WmdRefusal(code: .notWmd, message: "\(path.rawValue) is not a .wmd file")
      case .notFound: throw WmdRefusal(code: .notFound, message: "\(path.rawValue) does not exist")
      default: throw error
      }
    }
  }

  private static let notUTF8 = "a .wmd file is UTF-8 text"
}
