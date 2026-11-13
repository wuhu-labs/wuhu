#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import enum SpaceContract.LiveAccess
import enum SpaceContract.LiveErrorCode
import SpaceFS
import Synchronization
import Wuwei

/// The host's way into document sockets, checkpoints and agent writes; no in-memory state.
struct DocumentHub: Sendable {
  let runtime: SpaceRuntime
  let bucket: Bucket
  let peer: @Sendable () -> UInt64
  var merge: DocumentMerge = .live

  var worker: Worker { runtime.worker() }

  /// Gives a cold document the text of its file when the bytes live in the object store, which a step
  /// cannot read: the one case a seed is fetched, before the attach or the write that needs it, and only
  /// while the document's rows are not the file's own history — absent, or left over from one it replaced.
  func seed(_ group: GroupID, _ path: SpacePath) async throws {
    let file = try worker.read { reader -> (rev: Int64, hash: String)? in
      guard let file = reader.cell(FilesCell.ID(group.rawValue)).file(path) else { return nil }
      guard file.kind == "file", let hash = file.blobHash else { throw SpaceError.notAFile(path.rawValue) }
      guard reader.cell(DocumentCell.ID(group, path)).fileRev() != file.rev else { return nil }
      guard reader.cell(SpaceCell.ID("space")).bucket(hash)!.objectKey != nil else { return nil }
      return (file.rev, hash)
    }
    guard let file else { return }
    let text = Data(try await bucket.bytes(file.hash))
    do { try await worker.call(DocumentCell.ID(group, path)) { try $0.seed(text, file.rev) } } catch is DocumentGone {
      // The file moved on between the probe and the step: the attach or the write that follows seeds itself.
    }
  }

  /// Whether the document holds edits its file lacks, which a read must commit first.
  func dirty(_ group: GroupID, _ path: SpacePath) -> Bool {
    worker.cell(DocumentCell.ID(group, path)).dirty()
  }

  /// Commits the latest document state after waiting out a draining holder; an `Evicted` call leaves the read at the last checkpoint.
  func checkpoint(_ group: GroupID, _ path: SpacePath) async {
    await checkpoint(DocumentCell.ID(group, path))
  }

  /// Commits every document at or under `path` that a move or a checkout would carry along.
  func checkpoint(under path: SpacePath, in group: GroupID) async throws {
    let dirty = try worker.read { reader in
      try reader.cell(FilesCell.ID(group.rawValue)).subtree(path).compactMap { head -> DocumentCell.ID? in
        let live = try SpacePath(validating: head.path)
        guard live.isLive else { return nil }
        let id = DocumentCell.ID(group, live)
        return reader.cell(id).dirty() ? id : nil
      }
    }
    for id in dirty {
      await checkpoint(id)
    }
  }

  private func checkpoint(_ id: DocumentCell.ID) async {
    do {
      if let checkpoint = try await worker.call(id, { $0.prepareCheckpoint() }) {
        _ = try await commit(checkpoint, id: id, attribution: nil, checkout: nil)
      }
    } catch is Evicted {} catch is DocumentGone {} catch {
      preconditionFailure("a document checkpoint failed: \(error)")
    }
  }

  private func commit(_ checkpoint: DocumentCheckpoint, id: DocumentCell.ID, attribution: RevisionAttribution?, checkout: Int64?) async throws -> Int64 {
    guard let result = try await worker.call(FilesCell.ID(id.group.rawValue), {
      try $0.applyCheckpoint(id.path, hash: checkpoint.hash, lineage: checkpoint.lineage, seq: checkpoint.seq, seedRev: checkpoint.seedRev, attribution: attribution, checkout: checkout)
    }) else { throw DocumentGone() }
    do {
      try await worker.call(id) { try $0.committed(checkpoint.lineage, result.seq, result.rev, result.previous) }
    } catch is Evicted {}
    return result.rev
  }

  func material(_ group: GroupID, _ path: SpacePath, base: DocumentBase, createOnly: Bool) async throws -> DocumentMaterial {
    var material = try worker.read { reader in
      let file = reader.cell(FilesCell.ID(group.rawValue)).documentFile(path)
      return try reader.cell(DocumentCell.ID(group, path)).material(file, base: base, createOnly: createOnly)
    }
    if let hash = material.hash { material.text = Data(try await bucket.bytes(hash)) }
    return material
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
      let material = try await material(group, path, base: base, createOnly: createOnly)
      let prepared = try await merge.prepare(material, path, text, base, checkout != nil, peer(), peer())
      switch try await worker.call(id, { try $0.write(prepared, request) }) {
      case let .wrote(checkpoint):
        do { return try await commit(checkpoint, id: id, attribution: attribution, checkout: checkout) } catch is DocumentGone { throw SpaceError.notFound(path.rawValue) }
      case .stale: continue
      }
    }
    throw SpaceError.liveBusy(path.rawValue)
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
    do { stored = try await MachineFolders.stored(path, mutating: false, in: runtime) } catch {
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
    let (accessChanges, changes) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let stopWatching = observations.regions(["groups", "group_roles"], changes)
    do {
      _ = try taskScope.run("document-connection") {
        defer { stopWatching() }
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
      stopWatching()
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
