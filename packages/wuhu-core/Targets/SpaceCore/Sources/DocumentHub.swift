#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import struct SpaceContract.GroupID
import enum SpaceContract.LiveAccess
import enum SpaceContract.LiveErrorCode
import SpaceFS
import Synchronization
import Wuwei

/// The host's way into the documents: a client's socket, the checkpoint a read or a move needs, an
/// agent's write, and the removals the fs tells the documents about. Nothing is kept in memory here.
struct DocumentHub: Sendable {
  let runtime: SpaceRuntime
  let rows: DocumentRows
  let peer: @Sendable () -> UInt64
  var merge: DocumentMerge = .live

  var worker: Worker { runtime.worker() }

  /// Gives a cold document the text of its file when the bytes live in the object store, which a step
  /// cannot read: the one case a seed is fetched, before the attach or the write that needs it, and only
  /// while the document's rows are not the file's own history — absent, or left over from one it replaced.
  func seed(_ group: GroupID, _ path: SpacePath) async throws {
    guard let file = try await rows.file(group, path) else { return }
    guard try await rows.fileRev(DocumentCell.key(group, path)) != file.rev else { return }
    guard file.text == nil else { return }
    let text = try await rows.text(of: file.hash)
    do { try await worker.call(DocumentCell.ID(group, path)) { try $0.seed(text, file.rev) } } catch is DocumentGone {
      // The file moved on between the probe and the step: the attach or the write that follows seeds itself.
    }
  }

  /// Whether the document holds edits its file lacks, which a read must commit first.
  func dirty(_ group: GroupID, _ path: SpacePath) async throws -> Bool {
    try await rows.dirty(DocumentCell.key(group, path))
  }

  /// Commits what the file lacks, so a read sees it. `Evicted` means a stop is draining the cell, or a
  /// rollover has it elsewhere: the read then sees the file as of its last checkpoint, and the agent's
  /// write merges at its base revision, so nothing is lost.
  func checkpoint(_ group: GroupID, _ path: SpacePath) async {
    await checkpoint(DocumentCell.ID(group, path))
  }

  /// Commits every document at or under `path` that a move or a checkout would carry along.
  func checkpoint(under path: SpacePath, in group: GroupID) async throws {
    for key in try await rows.dirty(group, under: path) {
      await checkpoint(DocumentCell.ID(key))
    }
  }

  private func checkpoint(_ id: DocumentCell.ID) async {
    _ = try? await worker.call(id) { $0.checkpoint() }
  }

  /// An agent's text as the document's next revision.
  func write(
    _ group: GroupID, _ path: SpacePath, _ data: Data, base: DocumentBase, createOnly: Bool, acting: GroupID,
    attribution: RevisionAttribution?, checkout: Int64? = nil,
  ) async throws -> Int64 {
    guard let text = String(validating: data, as: UTF8.self) else {
      throw SpaceError.liveSyntax(path: path.rawValue, line: nil, reason: "a .\(path.liveKind!.rawValue) file is UTF-8 text")
    }
    let request = DocumentWrite(
      base: base, createOnly: createOnly, acting: acting, attribution: attribution, checkout: checkout,
    )
    let id = DocumentCell.ID(group, path)
    for _ in 0 ..< 3 {
      let material = try await rows.material(group, path, base: base, createOnly: createOnly)
      let prepared = try await merge.prepare(material, path, text, base, checkout != nil, peer(), peer())
      switch try await worker.call(id, { try $0.write(prepared, request) }) {
      case let .wrote(rev): return rev
      case .stale: continue
      }
    }
    throw SpaceError.liveBusy(path.rawValue)
  }

  func removed(under path: SpacePath, in group: GroupID, rev: Int64, on db: GRDB.Database) throws {
    let range = DocumentRows.range(group, path)
    for key in try String.fetchAll(
      db, sql: "SELECT owner FROM document_state WHERE (owner = ? OR (owner >= ? AND owner < ?))",
      arguments: [range.exact, range.below, range.belowUpper],
    ) {
      let recipient = DocumentCell.ID(key).recipient
      try recipient.post(.removed(rev), on: db.sqliteConnection!)
      db.afterNextTransaction { _ in runtime.poke(recipient) }
    }
  }
}

extension Space {
  /// One client's connection to the live document at `path`, after its `hello` was authenticated:
  /// `frames` are its later frames, and the stream ends after an `error` or once `frames` end. A missing
  /// document is refused `notFound` unless `create` asks for it, empty. When the principal's access to
  /// the group weakens, the transport closes its end: the client reconnects, and its next `welcome`
  /// carries what it may do.
  public func liveChannel(
    _ group: GroupID, _ path: SpacePath, peer: String, name: String, access: LiveAccess, create: Bool,
    frames: AsyncStream<LiveInbound>, reauthorize: @escaping @Sendable () async -> LiveAccess?,
  ) async -> AsyncStream<LiveOutbound> {
    guard path.isLive else { return Self.refused(.notLive, "\(path.rawValue) is no live document: those end in .wmd or .canvas") }
    let stored: SpacePath
    do { stored = try await MachineFolders.stored(path, mutating: false, in: writer) } catch {
      return Self.refused(.notFound, "\(path.rawValue) does not exist")
    }
    guard !stored.isReserved else { return Self.refused(.forbidden, "\(path.rawValue) is the space's own") }
    do { try await documents.seed(group, stored) } catch { return Self.refused(.internal, "\(error)") }
    let (outbound, continuation) = AsyncStream.makeStream(of: LiveOutbound.self, bufferingPolicy: .bufferingOldest(256))
    let (ended, ends) = AsyncStream.makeStream(of: Void.self)
    let socket = Mutex<Peer<DocumentChannel>?>(nil)
    let id = DocumentCell.ID(group, stored)
    guard let attached = worker.attach(
      DocumentChannel.self, to: id,
      opening: .init(peer: peer, name: name, access: access, create: create),
      output: { output in
        switch output {
        case let .frame(outbound):
          // A client too slow to take its frames has lost some: it closes, to reconnect and sync anew.
          guard case .dropped = continuation.yield(outbound) else { return }
          continuation.finish()
          socket.withLock { $0?.close() }
        case .closed:
          continuation.finish()
          ends.yield(())
        }
      },
    )
    else {
      continuation.yield(.control(.error(code: .internal, message: "the space is not hosting \(stored.rawValue)")))
      continuation.finish()
      return outbound
    }
    socket.withLock { $0 = attached }
    let accessChanges = regionWakes([Table("groups"), Table("group_roles")], in: writer)
    do {
      _ = try taskScope.run("document-connection") {
        await withTaskGroup(of: Void.self) { tasks in
          tasks.addTask {
            for await message in frames { attached.send(message) }
          }
          tasks.addTask {
            for await _ in accessChanges {
              let next = await reauthorize()
              if next == nil || (access == .write && next == .read) {
                attached.send(.weakened(next == nil ? .forbidden : .readOnly))
                // The cell answers the weakened frame by refusing the socket, and that close ends the
                // client's stream: the refusal must reach it first, so this waits for the close.
                for await _ in ended { break }
                return
              }
            }
          }
          await tasks.next()
          tasks.cancelAll()
        }
        attached.close()
        continuation.finish()
      }
    } catch {
      attached.close()
      continuation.finish()
    }
    return outbound
  }

  private static func refused(_ code: LiveErrorCode, _ message: String) -> AsyncStream<LiveOutbound> {
    AsyncStream { continuation in
      continuation.yield(.control(.error(code: code, message: message)))
      continuation.finish()
    }
  }
}
