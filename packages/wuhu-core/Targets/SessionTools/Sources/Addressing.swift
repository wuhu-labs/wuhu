import struct MachineContract.MachineID
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import enum SpaceFS.FSResolveError
import struct SpaceFS.FSResolver
import SystemFiles

enum Address: Hashable, Sendable {
  /// A group's file: hostless in the acting group, or named as
  /// `wuhu://<group>.localspace/<path>` (`qualified`).
  case space(String, in: GroupID, qualified: Bool)
  case machine(MachineID, String)
  /// `wuhu://system/<path>`: the read-only files built into the binary.
  case system(String)

  var rendered: String {
    switch self {
    case let .space(path, group, qualified): qualified ? FSResolver.address(path, inGroup: group.rawValue) : path
    case let .machine(id, path): "machines://\(id.rawValue)" + path
    case let .system(path): SystemFiles.address(path)
    }
  }

  var folder: Address {
    switch self {
    case let .space(path, group, qualified): .space(parent(of: path) ?? path, in: group, qualified: qualified)
    case let .machine(id, path): .machine(id, parent(of: path) ?? path)
    case let .system(path): .system(parent(of: path) ?? path)
    }
  }

  func appending(_ relative: String) -> Address {
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

enum Addressing {
  static func machineHost(_ raw: String) -> String? {
    guard raw.hasPrefix("machines://") else { return nil }
    return String(raw.dropFirst("machines://".count).prefix { $0 != "/" })
  }

  /// A hostless path is `acting`'s; there is no fallback to another group.
  static func parse(_ raw: String, acting: GroupID) throws -> Address {
    if let machine = machineHost(raw) {
      let rest = raw.dropFirst("machines://".count)
      let slash = rest.firstIndex(of: "/")
      guard MachineID.isValid(machine) else {
        throw ToolProblem("invalid machine id in \(raw)")
      }
      let path = slash.map { String(rest[$0...]) } ?? "/"
      return .machine(MachineID(rawValue: machine), try normalize(path))
    }
    if raw.lowercased().hasPrefix("wuhu://") {
      let rest = raw.dropFirst("wuhu://".count)
      let host = rest.prefix { $0 != "/" }
      let path = rest.dropFirst(host.count)
      let normalized = try normalize(path.isEmpty ? "/" : String(path))
      if host.lowercased() == FSResolver.systemHost { return .system(normalized) }
      let group: String?
      do {
        group = try FSResolver.group(ofHost: host)
      } catch {
        throw ToolProblem("invalid group host in \(raw): a group id is lowercase letters, digits and inner hyphens")
      }
      guard let group else { throw ToolProblem(FSResolveError.unsupportedHost(raw).description) }
      return .space(normalized, in: GroupID(rawValue: group), qualified: true)
    }
    guard raw.hasPrefix("/") else {
      throw ToolProblem(
        "\(raw) is a relative path; start a path in this group with /, another group's with wuhu://<group>.localspace/, a machine path with machines://<machine>/ and a system path with wuhu://system/",
      )
    }
    return .space(try normalize(raw), in: acting, qualified: false)
  }

  static func normalize(_ path: String) throws(ToolProblem) -> String {
    var stack: [Substring] = []
    for component in path.split(separator: "/") {
      switch component {
      case ".":
        continue
      case "..":
        guard stack.popLast() != nil else { throw ToolProblem("path escapes the root: \(path)") }
      default:
        stack.append(component)
      }
    }
    return "/" + stack.joined(separator: "/")
  }
}

// A machines:// host is either the id or the name a human gave the box; the
// name is substituted away here so every address downstream carries the id and
// survives a rename.
extension ToolExecutor {
  /// A group the session does not read has no files for it: the address
  /// fails exactly as a missing path does.
  func resolve(_ raw: String, as session: SessionID) async throws -> Address {
    let acting = try await space.principal(of: session).group
    let address = try Addressing.parse(await naming(raw), acting: acting)
    if case let .space(path, group, _) = address, group != acting, try await !space.reads(acting).contains(group),
       try await !space.sessions.readsAttachment(path, in: group, member: session.rawValue)
    {
      throw SpaceError.notFound(path)
    }
    // A machine of a group the session's group doesn't read is no machine.
    // (An id with no row names nothing the hub could reach either.)
    if case let .machine(id, _) = address, let record = try await space.machine(id),
       try await !space.reads(acting).contains(record.group)
    {
      throw ToolProblem("unknown machine: \(Addressing.machineHost(raw) ?? id.rawValue)")
    }
    return address
  }

  private func naming(_ raw: String) async throws -> String {
    guard let host = Addressing.machineHost(raw), !host.isEmpty, !MachineID.isValid(host) else { return raw }
    guard let record = try await space.resolveMachine(host) else {
      throw ToolProblem("unknown machine: \(host)")
    }
    return "machines://" + record.id.rawValue + String(raw.dropFirst("machines://".count + host.count))
  }
}
