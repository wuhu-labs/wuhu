import struct MachineContract.MachineID
import SessionDomain
import struct SpaceContract.GroupID
import SpaceCore
import enum SpaceFS.FSResolveError
import struct SpaceFS.FSResolver
import SystemFiles

public enum Addressing {
  public static func machineHost(_ raw: String) -> String? {
    guard raw.hasPrefix("machines://") else { return nil }
    return String(raw.dropFirst("machines://".count).prefix { $0 != "/" })
  }

  /// A hostless path is the acting group's (`.space(_, in: nil)`); there is
  /// no fallback to another group.
  public static func parse(_ raw: String) throws -> Address {
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
      return .space(normalized, in: GroupID(rawValue: group))
    }
    try refuseRelative(raw)
    return .space(try normalize(raw), in: nil)
  }

  public static func refuseSystem(_ address: Address) throws(ToolProblem) {
    if case .system = address { throw systemReadOnly(address) }
  }

  public static func systemReadOnly(_ address: Address) -> ToolProblem {
    ToolProblem(
      "\(address.rendered) is read-only: wuhu://system/ ships with the server; a skill with the same name in the space or your home replaces a system one",
    )
  }

  /// A path with no scheme and no leading slash names nothing, anywhere.
  public static func refuseRelative(_ raw: String) throws(ToolProblem) {
    guard raw.hasPrefix("/") || raw.lowercased().hasPrefix("wuhu://") || machineHost(raw) != nil else {
      throw ToolProblem(
        "\(raw) is a relative path; start a path in this group with /, another group's with wuhu://<group>.localspace/, a machine path with machines://<machine>/ and a system path with wuhu://system/",
      )
    }
  }

  public static func normalize(_ path: String) throws(ToolProblem) -> String {
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
extension Hub {
  /// A group the session does not read has no files for it: the address
  /// fails exactly as a missing path does.
  nonisolated func resolve(_ raw: String, as principal: Principal) async throws -> Address {
    let acting = principal.group
    let address = try Addressing.parse(await naming(raw))
    if case let .space(path, group) = address, try await !space.sessions.readsFile(path, in: group ?? acting, as: principal) {
      throw SpaceError.notFound(path)
    }
    // A machine the session may not use is no machine.
    // (An id with no row names nothing the hub could reach either.)
    if case let .machine(id, _) = address, let record = try await space.machine(id),
       try await !space.canUse(record, from: acting)
    {
      throw ToolProblem("unknown machine: \(Addressing.machineHost(raw) ?? id.rawValue)")
    }
    return address
  }

  nonisolated private func naming(_ raw: String) async throws -> String {
    guard let host = Addressing.machineHost(raw), !host.isEmpty, !MachineID.isValid(host) else { return raw }
    guard let record = try await space.resolveMachine(host) else {
      throw ToolProblem("unknown machine: \(host)")
    }
    return "machines://" + record.id.rawValue + String(raw.dropFirst("machines://".count + host.count))
  }
}
