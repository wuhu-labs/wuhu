import Dependencies
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import KeelObjectStore
import Logging
import struct SpaceContract.GroupID
import SpaceFS
import SpaceSQL

public actor Space {
  nonisolated let taskScope = TaskScope()
  let writer: any DatabaseWriter
  let reads: ReadPool
  let blobs: BlobStore
  let broadcast: FSBroadcast
  let workSignals = WorkSignals()
  let archiveReservations = ArchiveReservations()
  let dateGen: DateGenerator
  let clock: any Clock<Duration>
  let rng: WithRandomNumberGenerator
  let log: Logger
  var machineTraces: MachineTraceWriter?
  var identityCache: SpaceIdentity?
  var templateCloneFault: String?

  init(
    writer: any DatabaseWriter,
    identity: SpaceIdentity? = nil,
    objects: (any ObjectStore)? = nil,
    log: Logger = Logger(label: "wuhu.space"),
    catalog: ViewCatalog = .groups,
    trace: (@Sendable (String) -> Void)? = nil,
  ) throws {
    try SpaceMeta.prepare(writer, identity: identity)
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var rng
    self.writer = writer
    self.reads = ReadPool(path: writer.path, catalog: catalog, trace: trace)
    self.blobs = BlobStore(objects: objects)
    self.broadcast = FSBroadcast()
    self.dateGen = date
    self.clock = clock
    self.rng = rng
    self.log = log
  }

  public func close() async throws {
    await machineTraces?.close()
    broadcast.close()
    await taskScope.close()
    var failure: (any Error)?
    do { try await reads.close() } catch { failure = error }
    do { try writer.close() } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }

  public static func open(
    file: URL, identity: SpaceIdentity? = nil, objects: (any ObjectStore)? = nil, log: Logger = Logger(label: "wuhu.space"),
  ) throws -> Space {
    if let identity, !SpaceIdentity.isValid(identity.rawValue) {
      throw SpaceIdentityError.invalid(identity.rawValue)
    }
    var configuration = makeConfiguration()
    configuration.prepareDatabase { try $0.execute(sql: PageCache.pragmas(cacheKiB: PageCache.writerKiB)) }
    let queue = try DatabaseQueue(path: file.path, configuration: configuration)
    let store = objects ?? FileSystemObjectStore(root: file.deletingLastPathComponent().appending(path: "objects"))
    return try Space(writer: queue, identity: identity, objects: store, log: log)
  }

  public static func inMemory(objects: (any ObjectStore)? = nil) throws -> Space {
    try inMemory(configuration: makeConfiguration(journalMode: .default), objects: objects)
  }

  static func inMemory(
    configuration: Configuration,
    objects: (any ObjectStore)? = nil,
    log: Logger = Logger(label: "wuhu.space"),
    catalog: ViewCatalog = .groups,
    trace: (@Sendable (String) -> Void)? = nil,
  ) throws -> Space {
    let queue = try DatabaseQueue(path: "file:/space-\(UUID())?vfs=memdb", configuration: configuration)
    try SpaceMeta.memorySchema.get().backup(to: queue)
    return try Space(writer: queue, objects: objects, log: log, catalog: catalog, trace: trace)
  }

  static func makeConfiguration(journalMode: Configuration.JournalModeConfiguration = .wal) -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)
    config.journalMode = journalMode
    return config
  }

  /// `group`'s files, live or as of `rev`. A mutation's revision is recorded
  /// for `acting`, the actor's group, which is `group` unless it writes into
  /// another group it reads.
  /// `attribution` is recorded with each revision a live write mints.
  public func fs(
    _ group: GroupID, at rev: Rev? = nil, acting: GroupID? = nil, attribution: RevisionAttribution? = nil, listingLimit: Int? = nil, listingByteLimit: Int? = nil,
  ) -> any SpaceVFS {
    precondition(listingLimit == nil || listingLimit! > 0)
    precondition(listingByteLimit == nil || listingByteLimit! > 0)
    let base: any SpaceVFS = if let rev {
      HistoricalFS(group: group, writer: writer, blobs: blobs, ceiling: Int64(rev.value), listingLimit: listingLimit, listingByteLimit: listingByteLimit)
    } else {
      live(group, acting: acting ?? group, attribution: attribution, listingLimit: listingLimit, listingByteLimit: listingByteLimit)
    }
    return MachineFolders(base: base, writer: writer, group: group, listingLimit: listingLimit, listingByteLimit: listingByteLimit)
  }

  func live(_ group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, listingLimit: Int? = nil, listingByteLimit: Int? = nil) -> LiveFS {
    LiveFS(
      group: group, acting: acting, writer: writer, blobs: blobs, broadcast: broadcast, dateGen: dateGen, listingLimit: listingLimit, listingByteLimit: listingByteLimit, attribution: attribution,
    )
  }
}
