/// A group of a space: a three-word id, or `shared`, the group every space has.
public struct GroupID: RawRepresentable, Hashable, Sendable, Codable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let shared: GroupID = GroupID(rawValue: "shared")
}

/// A `.localspace` host that names no valid group, the bare `localspace` included.
public struct InvalidGroupHost: Error, Equatable, Sendable {
  public let host: String
}

// The one parser of group addresses: the tools, the HTTP routes, scripts, the
// CLI and the client all go through it.
extension GroupID {
  /// The reserved host suffix of a group's files: `wuhu://<group>.localspace/…`.
  public static let hostSuffix: String = ".localspace"

  /// Lowercase letters, digits and inner hyphens.
  public static func isValid(_ id: some StringProtocol) -> Bool {
    !id.isEmpty && id.first != "-" && id.last != "-"
      && id.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
  }

  /// The group `host` names when it is `<group>.localspace`, compared lowercased like any
  /// host; nil for any other host. A `.localspace` host naming no valid group id throws.
  public static func named(byHost host: some StringProtocol) throws(InvalidGroupHost) -> GroupID? {
    let host = host.lowercased()
    guard host.hasSuffix(hostSuffix) || host == "localspace" else { return nil }
    let id = host.dropLast(hostSuffix.count)
    guard host != "localspace", isValid(id) else { throw InvalidGroupHost(host: host) }
    return GroupID(rawValue: String(id))
  }

  /// `wuhu://<group>.localspace/<path>` split into the group and the hostless path it names
  /// there (`/` when absent); nil for a hostless path or any other address. The address
  /// is a group of the space at hand, never a space to dial.
  public static func address(_ spelling: String) throws(InvalidGroupHost) -> (group: GroupID, path: String)? {
    let scheme = "wuhu://"
    guard spelling.count >= scheme.count, spelling.prefix(scheme.count).lowercased() == scheme else { return nil }
    let rest = spelling.dropFirst(scheme.count)
    let slash = rest.firstIndex(of: "/") ?? rest.endIndex
    guard let group = try named(byHost: rest[..<slash]) else { return nil }
    let path = rest[slash...]
    return (group, path.isEmpty ? "/" : String(path))
  }

  /// `path` in this group's files: `wuhu://<group>.localspace<path>`.
  public func address(_ path: String) -> String {
    "wuhu://\(rawValue)\(Self.hostSuffix)\(path)"
  }
}
