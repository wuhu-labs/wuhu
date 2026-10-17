#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// What a backend gives the engine: it walks and reads, nothing more. Paths
/// are absolute and `/`-separated.
public protocol SearchSource: Sendable {
  /// The entry at `path`, nil when there is none. The root is resolved like
  /// any path (a symlink root is followed); entries below it come from
  /// ``children(of:)``.
  func kind(_ path: String) async throws -> SearchEntryKind?
  /// At most `limit` children of `directory` named `start` or later, in UTF-8
  /// byte order of their names, and the name the following page starts at,
  /// nil when none remain. Throws ``SearchUnreadable`` when the directory
  /// cannot be listed.
  func children(of directory: String, from start: String, limit: Int) async throws -> SearchListing
  /// Throws ``SearchUnreadable`` when the file cannot be opened.
  func open(_ file: String) async throws -> any SearchReader
  /// Whether a walk passes over this entry unless asked to show hidden ones.
  func isHidden(_ path: String) -> Bool
}

public enum SearchEntryKind: Hashable, Sendable {
  case directory
  case file
  /// Anything else: a symlink below the root, a table, a device. Find lists
  /// it; grep does not read it.
  case other
}

public struct SearchChild: Hashable, Sendable {
  public var name: String
  public var kind: SearchEntryKind

  public init(name: String, kind: SearchEntryKind) {
    self.name = name
    self.kind = kind
  }
}

/// One page of a directory's children.
public struct SearchListing: Hashable, Sendable {
  public var children: [SearchChild]
  public var next: String?

  public init(children: [SearchChild], next: String?) {
    self.children = children
    self.next = next
  }
}

public protocol SearchReader: Sendable {
  /// At most `count` bytes from `offset`; fewer only at the end of the file.
  /// Throws ``SearchUnreadable`` when the file cannot be read.
  func read(at offset: Int, count: Int) async throws -> Data
  func close() async
}

/// An entry a backend cannot list or read: the walk skips it as unreadable.
/// Any other error a source throws ends the search.
public struct SearchUnreadable: Error, Hashable, Sendable {
  public var reason: String

  public init(_ reason: String) {
    self.reason = reason
  }
}
