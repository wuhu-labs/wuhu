import Dependencies
import Foundation
import GRDB
import KeelObjectStore
import Logging
import Scratch
import struct SpaceContract.GroupID
import SpaceFS
import SpaceSQL

public actor Space {
  let writer: any DatabaseWriter
  let reads: ReadPool
  let blobs: BlobStore
  let broadcast: FSBroadcast
  let workSignals = WorkSignals()
  let dateGen: DateGenerator
  let clock: any Clock<Duration>
  let rng: WithRandomNumberGenerator
  let log: Logger
  var identityCache: SpaceIdentity?
  var templateCloneFault: String?

  init(
    writer: any DatabaseWriter,
    blobs: BlobStore = BlobStore(objects: nil),
    log: Logger = Logger(label: "wuhu.space"),
    reads: ReadPool? = nil,
  ) {
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var rng
    self.writer = writer
    self.reads = reads ?? ReadPool(path: writer.path, catalog: .groups)
    self.blobs = blobs
    self.broadcast = FSBroadcast()
    self.dateGen = date
    self.clock = clock
    self.rng = rng
    self.log = log
  }

  public static func open(
    file: URL, objects: (any ObjectStore)? = nil, log: Logger = Logger(label: "wuhu.space"),
  ) throws -> Space {
    let queue = try DatabaseQueue(path: file.path, configuration: makeConfiguration())
    try queue.write { db in try SpaceMeta.prepare(db) }
    let store = objects ?? FileSystemObjectStore(root: file.deletingLastPathComponent().appending(path: "objects"))
    return Space(writer: queue, blobs: BlobStore(objects: store), log: log)
  }

  // A throwaway space: read connections attach the file by path, so it lives
  // in a scratch folder, removed once the writer is gone and at the latest
  // when the process exits. Every blob stays inline unless the caller
  // supplies a store.
  public static func inMemory(objects: (any ObjectStore)? = nil) throws -> Space {
    try temporary(objects: objects)
  }

  static func temporary(
    configuration: Configuration = makeConfiguration(),
    objects: (any ObjectStore)? = nil,
    log: Logger = Logger(label: "wuhu.space"),
    catalog: ViewCatalog = .groups,
    trace: (@Sendable (String) -> Void)? = nil,
  ) throws -> Space {
    let folder = try ScratchFolder("space")
    let path = folder.url.appending(path: "space.sqlite").path
    var configuration = configuration
    configuration.prepareDatabase { _ in withExtendedLifetime(folder) {} }
    let queue = try DatabaseQueue(path: path, configuration: configuration)
    try queue.write { db in try SpaceMeta.prepare(db) }
    return Space(
      writer: queue, blobs: BlobStore(objects: objects), log: log,
      reads: ReadPool(path: path, catalog: catalog, trace: trace),
    )
  }

  static func makeConfiguration() -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)
    config.journalMode = .wal
    return config
  }

  /// `group`'s files, live or as of `rev`. A mutation's revision is recorded
  /// for `acting`, the actor's group, which is `group` unless it writes into
  /// another group it reads.
  /// `attribution` is recorded with each revision a live write mints.
  public func fs(
    _ group: GroupID, at rev: Rev? = nil, acting: GroupID? = nil, attribution: RevisionAttribution? = nil,
  ) -> any SpaceVFS {
    let base: any SpaceVFS = if let rev {
      HistoricalFS(group: group, writer: writer, blobs: blobs, ceiling: Int64(rev.value))
    } else {
      live(group, acting: acting ?? group, attribution: attribution)
    }
    return MachineFolders(base: base, writer: writer, group: group)
  }

  func live(_ group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil) -> LiveFS {
    LiveFS(
      group: group, acting: acting, writer: writer, blobs: blobs, broadcast: broadcast, dateGen: dateGen, attribution: attribution,
    )
  }
}
