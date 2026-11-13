#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import Wuwei

struct HistoricalFS: SpaceVFS {
  let group: GroupID
  let runtime: SpaceRuntime
  let bucket: Bucket
  let ceiling: Int64
  var listingLimit: Int?
  var listingByteLimit: Int?

  func read(_ path: String) async throws -> (VersionToken, Data) {
    let node = try runtime.worker().cell(FilesCell.ID(group.rawValue)).historicalFile(LiveFS.validated(path), at: ceiling)
    return (VersionToken(rev: Int(node.rev)), Data(try await bucket.bytes(node.blobHash!)))
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    let node = try runtime.worker().cell(FilesCell.ID(group.rawValue)).historicalFile(LiveFS.validated(path), at: ceiling)
    return BucketReader(bucket: bucket, hash: node.blobHash!)
  }

  func write(_ path: String, _: Data, ifMatch _: VersionToken?) async throws -> VersionToken { throw SpaceError.readOnlyView(path) }
  func delete(_ path: String, ifMatch _: VersionToken?) async throws { throw SpaceError.readOnlyView(path) }
  func move(_ path: String, to _: String) async throws { throw SpaceError.readOnlyView(path) }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    let (entries, _) = try await page(of: LiveFS.validated(path), from: "", limit: listingLimit ?? Int.max, budget: ListingBudget(limit: listingByteLimit))
    return (VersionToken(rev: Int(ceiling)), entries.sorted { $0.name < $1.name })
  }

  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    precondition(limit > 0)
    return try await page(of: LiveFS.validated(path), from: from, limit: limit, budget: ListingBudget(limit: nil))
  }

  private func page(of path: SpacePath, from: String, limit: Int, budget: ListingBudget) async throws -> ([Entry], String?) {
    let (nodes, next) = try runtime.worker().cell(FilesCell.ID(group.rawValue)).historicalPage(path, at: ceiling, from: from, limit: limit, budget: budget)
    var entries: [Entry] = []
    for node in nodes { entries.append(try await Self.entry(from: node, bucket: bucket)) }
    return (entries, next)
  }

  func stat(_ path: String) async throws -> Entry {
    let node = try runtime.worker().cell(FilesCell.ID(group.rawValue)).historical(LiveFS.validated(path), at: ceiling)
    return try await Self.entry(from: node, bucket: bucket)
  }

  static func entry(from node: HistoricalNode, bucket: Bucket) async throws -> Entry {
    var measure: (size: Int64, lineCount: Int64?)?
    if node.kind == "file", let hash = node.blobHash { measure = try await bucket.measure(hash) }
    return Entry(
      name: SpacePath.lastComponent(of: node.path),
      kind: Substrate.entryKind(node.kind!),
      size: Int(measure?.size ?? 0),
      lineCount: measure?.lineCount.map(Int.init),
      token: VersionToken(rev: Int(node.rev)),
      mtime: (try? SQLiteDateFormat.date(from: node.mtime)) ?? Date(timeIntervalSince1970: 0),
    )
  }
}
