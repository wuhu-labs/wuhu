#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

public struct FileSystemObjectStore: ObjectStore {
  let root: URL
  let defaultMaxKeys: Int

  public init(root: URL, defaultMaxKeys: Int = 1000) {
    self.root = root
    self.defaultMaxKeys = defaultMaxKeys
  }

  public func put(_ key: ObjectKey, body: Body) async throws {
    let fileURL = self.fileURL(key)
    let data = try await body.bytes()
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  public func get(_ key: ObjectKey) async throws -> GetResult {
    let fileURL = self.fileURL(key)
    guard self.isRegularFile(fileURL.path) else { throw ObjectStoreError.notFound(key) }
    let data = try Data(contentsOf: fileURL)
    return GetResult(body: .bytes(data), metadata: ObjectMetadata(contentLength: Int64(data.count)))
  }

  public func head(_ key: ObjectKey) async throws -> ObjectMetadata? {
    guard let size = self.regularFileSize(self.fileURL(key).path) else { return nil }
    return ObjectMetadata(contentLength: size)
  }

  public func delete(_ key: ObjectKey) async throws {
    let fileURL = self.fileURL(key)
    guard self.isRegularFile(fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
    self.pruneEmptyDirectories(from: fileURL.deletingLastPathComponent())
  }

  public func list(_ query: ListQuery) async throws -> ObjectListing {
    let all = self.allKeys()
      .filter { $0.utf8.starts(with: query.prefix.utf8) }
      .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

    let start: Int
    if let token = query.continuationToken {
      start = all.firstIndex { token.utf8.lexicographicallyPrecedes($0.utf8) } ?? all.count
    } else {
      start = 0
    }

    let limit = query.maxKeys ?? self.defaultMaxKeys
    let end = min(start + limit, all.count)
    let page = Array(all[start ..< end])
    let entries = try page.map { raw -> ObjectListEntry in
      let key = try ObjectKey(raw)
      return ObjectListEntry(key: key, size: self.regularFileSize(self.fileURL(key).path) ?? 0)
    }
    let continuationToken = end < all.count ? page.last : nil
    return ObjectListing(entries: entries, continuationToken: continuationToken)
  }

  private func fileURL(_ key: ObjectKey) -> URL {
    var url = self.root
    for segment in key.raw.split(separator: "/") {
      url.appendPathComponent(String(segment))
    }
    return url
  }

  private func regularFileSize(_ path: String) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? UInt
    else { return nil }
    return Int64(size)
  }

  private func isRegularFile(_ path: String) -> Bool {
    self.regularFileSize(path) != nil
  }

  private func allKeys() -> [String] {
    let rootPath = self.root.path
    guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: rootPath) else { return [] }
    return subpaths.filter { self.isRegularFile(rootPath + "/" + $0) }
  }

  private func pruneEmptyDirectories(from directory: URL) {
    var current = directory.standardizedFileURL
    let rootStandardized = self.root.standardizedFileURL
    while current.pathComponents.count > rootStandardized.pathComponents.count {
      let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path)
      guard contents?.isEmpty == true else { return }
      try? FileManager.default.removeItem(at: current)
      current = current.deletingLastPathComponent().standardizedFileURL
    }
  }
}
