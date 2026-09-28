import JSONValue
import struct SpaceContract.GroupID
import SpaceCore
import struct SpaceFS.Entry
import enum SpaceFS.FSResolveError
import struct SpaceFS.FSResolver

// A glob watches the acting group, or with a `wuhu://<group>.localspace`
// prefix a group the actor reads; its events then carry the same prefix.
public struct WatchedGlob: Sendable {
  public let group: GroupID
  public let pattern: String
  public let prefix: String

  public init(_ glob: String, as principal: Principal, in space: Space) async throws {
    guard glob.lowercased().hasPrefix("wuhu://") else {
      (group, pattern, prefix) = (principal.group, glob, "")
      return
    }
    let host = glob.dropFirst("wuhu://".count).prefix { $0 != "/" }
    guard let named = try FSResolver.group(ofHost: host) else {
      throw FSResolveError.unsupportedHost(glob)
    }
    group = GroupID(rawValue: named)
    prefix = "wuhu://" + host.lowercased()
    pattern = String(glob.dropFirst("wuhu://".count + host.count))
    let readable = try await space.reads(principal.group)
    guard readable.contains(group) else {
      throw SpaceError.notFound(glob)
    }
  }
}

extension Wire {
  /// A file event as watch streams carry it, its paths under `prefix`.
  public static func mutationJSON(_ event: SpaceCore.MutationEvent, prefix: String = "") -> JSONValue {
    let rev = JSONValue.integer(event.rev)
    let path = JSONValue.string(prefix + event.path)
    return switch event.kind {
    case .write:
      .object(["kind": "write", "path": path, "rev": rev, "entry": entryJSON(event.entry!)])
    case .delete:
      .object(["kind": "delete", "path": path, "rev": rev])
    case .move:
      .object([
        "kind": "move", "path": .string(prefix + (event.from ?? event.path)), "to": path,
        "rev": rev, "entry": entryJSON(event.entry!),
      ])
    }
  }
}

private func entryJSON(_ kind: Entry.Kind) -> JSONValue {
  switch kind {
  case .file: .string("file")
  case .directory: .string("directory")
  case .table: .string("table")
  case .symlink: .string("symlink")
  }
}
