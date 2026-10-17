#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FileSearch
import Synchronization

/// An in-memory tree: every path's parents are directories. Counts the bytes
/// its readers return and the children its listings return.
final class MemoryTree: SearchSource {
  enum Node: Sendable {
    case directory
    case file(Data)
    case other
    case unreadableDirectory
    case unreadableFile
    /// A file whose reads wait until their task is cancelled.
    case stalled
  }

  let nodes: [String: Node]
  private let read = Mutex(0)
  private let listed = Mutex(0)

  init(_ nodes: [String: Node]) {
    var all = nodes
    for path in nodes.keys {
      var parts = path.split(separator: "/").dropLast()
      while !parts.isEmpty {
        let parent = "/" + parts.joined(separator: "/")
        if all[parent] == nil { all[parent] = .directory }
        parts = parts.dropLast()
      }
    }
    all["/"] = all["/"] ?? .directory
    self.nodes = all
  }

  convenience init(files: [String: String]) {
    self.init(files.mapValues { .file(Data($0.utf8)) })
  }

  var bytesRead: Int { read.withLock { $0 } }
  var childrenListed: Int { listed.withLock { $0 } }

  func kind(_ path: String) async throws -> SearchEntryKind? {
    switch nodes[path] {
    case nil: nil
    case .directory?, .unreadableDirectory?: .directory
    case .file?, .unreadableFile?, .stalled?: .file
    case .other?: .other
    }
  }

  func children(of directory: String, from start: String, limit: Int) async throws -> SearchListing {
    if case .unreadableDirectory? = nodes[directory] { throw SearchUnreadable("denied") }
    let prefix = directory == "/" ? "/" : directory + "/"
    let all = try await nodes.keys.asyncCompactMap { path -> SearchChild? in
      let name = String(path.dropFirst(prefix.count))
      guard path.hasPrefix(prefix), !name.isEmpty, !name.contains("/"), !name.utf8.lexicographicallyPrecedes(start.utf8) else { return nil }
      return try await SearchChild(name: name, kind: self.kind(path)!)
    }.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    let page = Array(all.prefix(limit))
    listed.withLock { $0 += page.count }
    return SearchListing(children: page, next: all.count > limit ? all[limit].name : nil)
  }

  func open(_ file: String) async throws -> any SearchReader {
    switch nodes[file] {
    case let .file(data)?: Reader(data: data, read: { count in self.read.withLock { $0 += count } })
    case .stalled?: Stalled()
    default: throw SearchUnreadable("denied")
    }
  }

  func isHidden(_ path: String) -> Bool {
    path.split(separator: "/").last?.hasPrefix(".") ?? false
  }

  private struct Reader: SearchReader {
    let data: Data
    let read: @Sendable (Int) -> Void

    func read(at offset: Int, count: Int) async throws -> Data {
      let bytes = data.dropFirst(offset).prefix(count)
      read(bytes.count)
      return Data(bytes)
    }

    func close() async {}
  }

  private struct Stalled: SearchReader {
    func read(at _: Int, count _: Int) async throws -> Data {
      let (never, continuation) = AsyncStream<Never>.makeStream()
      defer { continuation.finish() }
      for await _ in never {}
      throw CancellationError()
    }

    func close() async {}
  }
}

extension Sequence {
  fileprivate func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async throws -> [T] {
    var result: [T] = []
    for element in self {
      if let value = try await transform(element) { result.append(value) }
    }
    return result
  }
}
