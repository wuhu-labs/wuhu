import Dependencies
import TaskLifetime
import Wuwei
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
  nonisolated let taskScope: TaskScope
  let writer: any DatabaseWriter
  let reads: ReadPool
  let bucket: Bucket
  let observations: ObservationSources
  let runtime: SpaceRuntime
  let dateGen: DateGenerator
  let clock: any Clock<Duration>
  let documents: DocumentHub
  let rng: WithRandomNumberGenerator
  let log: Logger
  var identityCache: SpaceIdentity?
  var templateCloneFault: String?

  init(
    writer: any DatabaseWriter,
    identity: SpaceIdentity? = nil,
    objects: (any ObjectStore)? = nil,
    log: Logger = Logger(label: "wuhu.space"),
    catalog: ViewCatalog = .groups,
    trace: (@Sendable (String) -> Void)? = nil,
    regions: (@Sendable (@escaping RegionSource) -> RegionSource)? = nil,
    fileReads: @escaping @Sendable (Worker) -> FileWatchReads = { FileWatchReads(worker: $0) },
  ) throws {
    @Dependency(\.date) var date
    try SpaceMeta.prepare(writer, identity: identity, log: log, date: date)
    @Dependency(\.continuousClock) var clock
    @Dependency(\.withRandomNumberGenerator) var rng
    let taskScope = TaskScope()
    self.taskScope = taskScope
    self.writer = writer
    self.reads = ReadPool(path: writer.path, catalog: catalog, trace: trace, log: log)
    self.dateGen = date
    self.clock = clock
    let changes = ChangeSource()
    let subscribe: RegionSource = { tables, wakes in changes.subscribe(tables, wakes) }
    self.observations = ObservationSources(
      reads: reads, clock: clock,
      regions: regions.map { $0(subscribe) } ?? subscribe,
    )
    let replicas = DocumentReplicas()
    let peers = rng
    let peer: @Sendable () -> UInt64 = { peers { UInt64.random(in: 1 ... UInt64(Int64.max), using: &$0) } }
    let runtime = SpaceRuntime(
      writer: writer, changes: changes, observations: observations,
      documents: Documents(
        replicas: replicas,
        peer: peer,
        mtime: { SQLiteDateFormat.string(from: date.now) },
      ),
      log: log, fileReads: fileReads,
    )
    self.runtime = runtime
    let bucket = Bucket(runtime: runtime, objects: objects)
    self.bucket = bucket
    self.documents = DocumentHub(runtime: runtime, bucket: bucket, peer: peer)
    self.rng = rng
    self.log = log
  }

  public func close() async throws {
    runtime.beginClosing()
    await runtime.quiesce()
    await taskScope.close()
    var failure: (any Error)?
    do { try await reads.close() } catch { failure = error }
    await runtime.stop()
    runtime.close()
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
    configuration.prepareDatabase {
      try $0.execute(sql: PageCache.pragmas(cacheKiB: PageCache.writerKiB))
      SlowStatement.trace(on: $0.sqliteConnection!, connection: "writer", to: log)
    }
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
    regions: (@Sendable (@escaping RegionSource) -> RegionSource)? = nil,
    fileReads: @escaping @Sendable (Worker) -> FileWatchReads = { FileWatchReads(worker: $0) },
  ) throws -> Space {
    let queue = try DatabaseQueue(path: "file:/space-\(UUID())?vfs=memdb", configuration: configuration)
    try SpaceMeta.memorySchema.get().backup(to: queue)
    return try Space(writer: queue, objects: objects, log: log, catalog: catalog, trace: trace, regions: regions, fileReads: fileReads)
  }

  static func makeConfiguration(journalMode: Configuration.JournalModeConfiguration = .wal) -> Configuration {
    var config = Configuration()
    config.foreignKeysEnabled = true
    config.busyMode = .timeout(5)
    config.journalMode = journalMode
    config.prepareDatabase { try $0.execute(sql: "PRAGMA secure_delete = OFF") }
    return config
  }

  public func fs(
    _ group: GroupID, at rev: Rev? = nil, acting: GroupID? = nil, attribution: RevisionAttribution? = nil, listingLimit: Int? = nil, listingByteLimit: Int? = nil,
  ) -> any SpaceVFS {
    precondition(listingLimit == nil || listingLimit! > 0)
    precondition(listingByteLimit == nil || listingByteLimit! > 0)
    let base: any SpaceVFS = if let rev {
      HistoricalFS(group: group, runtime: runtime, bucket: bucket, ceiling: Int64(rev.value), listingLimit: listingLimit, listingByteLimit: listingByteLimit)
    } else {
      live(group, acting: acting ?? group, attribution: attribution, listingLimit: listingLimit, listingByteLimit: listingByteLimit)
    }
    return AttachmentFolders(
      base: MachineFolders(base: base, runtime: runtime, group: group, listingLimit: listingLimit, listingByteLimit: listingByteLimit),
      runtime: runtime, writer: writer, bucket: bucket, group: group,
    )
  }

  func live(_ group: GroupID, acting: GroupID, attribution: RevisionAttribution? = nil, listingLimit: Int? = nil, listingByteLimit: Int? = nil) -> LiveFS {
    LiveFS(
      group: group, acting: acting, runtime: runtime, bucket: bucket, dateGen: dateGen, documents: documents, listingLimit: listingLimit, listingByteLimit: listingByteLimit, attribution: attribution,
    )
  }
}
