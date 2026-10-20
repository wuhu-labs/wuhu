import struct MachineContract.MachineID
import struct SpaceContract.GroupID
import struct SpaceFS.FSResolver
import SystemFiles

public enum Address: Hashable, Sendable {
  /// A group's file: hostless in the acting group, or named as
  /// `wuhu://<group>.localspace/<path>` (`qualified`).
  case space(String, in: GroupID, qualified: Bool)
  case machine(MachineID, String)
  /// `wuhu://system/<path>`: the read-only files built into the binary.
  case system(String)

  nonisolated public var rendered: String {
    switch self {
    case let .space(path, group, qualified): qualified ? FSResolver.address(path, inGroup: group.rawValue) : path
    case let .machine(id, path): "machines://\(id.rawValue)" + path
    case let .system(path): SystemFiles.address(path)
    }
  }

  nonisolated public var folder: Address {
    switch self {
    case let .space(path, group, qualified): .space(parent(of: path) ?? path, in: group, qualified: qualified)
    case let .machine(id, path): .machine(id, parent(of: path) ?? path)
    case let .system(path): .system(parent(of: path) ?? path)
    }
  }

  nonisolated public func appending(_ relative: String) -> Address {
    switch self {
    case let .space(path, group, qualified): .space(joined(path, relative), in: group, qualified: qualified)
    case let .machine(id, path): .machine(id, joined(path, relative))
    case let .system(path): .system(joined(path, relative))
    }
  }
}

func parent(of path: String) -> String? {
  guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
  return slash == path.startIndex ? "/" : String(path[..<slash])
}

func joined(_ directory: String, _ relative: String) -> String {
  directory == "/" ? "/" + relative : directory + "/" + relative
}
