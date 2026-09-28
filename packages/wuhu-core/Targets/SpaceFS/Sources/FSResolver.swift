import struct SpaceContract.GroupID

public struct FSResolution: Sendable {
  public let backend: any SpaceVFS
  public let path: String
  public let machine: String?
  /// A `wuhu://system/…` address: the read-only files built into the binary.
  public let system: Bool
  /// The group a `wuhu://<group>.localspace/…` address names; nil for a hostless path.
  public let group: String?

  public init(backend: any SpaceVFS, path: String, machine: String?, system: Bool = false, group: String? = nil) {
    self.backend = backend
    self.path = path
    self.machine = machine
    self.system = system
    self.group = group
  }
}

public struct FSResolver: Sendable {
  private let space: any SpaceVFS
  private let spaceAt: @Sendable (Int) -> any SpaceVFS
  private let machine: @Sendable (String) throws -> any SpaceVFS
  private let system: any SpaceVFS
  private let group: @Sendable (String, Int?) throws -> any SpaceVFS

  /// The host `wuhu://system/` names; reserved, since a real space host
  /// always has a dot or a port.
  public static let systemHost: String = "system"
  /// The group `host` names, when it is `<group>.localspace`; nil for any other host.
  /// A host ending in the reserved suffix that names no valid group id is invalid.
  /// This is `GroupID.named(byHost:)`, the one parser, with the resolver's error.
  public static func group(ofHost host: some StringProtocol) throws -> String? {
    do {
      return try GroupID.named(byHost: host)?.rawValue
    } catch {
      throw FSResolveError.invalidAddress("wuhu://\(error.host)/")
    }
  }

  /// `path` in `group`'s files: `wuhu://<group>.localspace<path>`.
  public static func address(_ path: String, inGroup group: String) -> String {
    GroupID(rawValue: group).address(path)
  }

  public init(
    space: any SpaceVFS,
    spaceAt: @escaping @Sendable (Int) -> any SpaceVFS,
    machine: @escaping @Sendable (String) throws -> any SpaceVFS,
    system: any SpaceVFS,
    group: @escaping @Sendable (String, Int?) throws -> any SpaceVFS,
  ) {
    self.space = space
    self.spaceAt = spaceAt
    self.machine = machine
    self.system = system
    self.group = group
  }

  public func resolve(_ address: String) throws -> FSResolution {
    if let rest = address.dropSchemePrefix("machines://") {
      return try resolveMachinePath(rest, address: address)
    }
    if let rest = address.dropSchemePrefix("wuhu://") {
      let (authority, path) = FSResolver.splitAuthority(rest)
      guard !authority.isEmpty else { throw FSResolveError.invalidAddress(address) }
      if authority.lowercased() == FSResolver.systemHost {
        return try resolveSystemPath(path, address: address)
      }
      do {
        guard let id = try FSResolver.group(ofHost: authority) else { throw FSResolveError.unsupportedHost(address) }
        return try resolveGroupPath(path, group: id)
      } catch FSResolveError.invalidAddress {
        throw FSResolveError.invalidAddress(address)
      }
    }
    guard address.hasPrefix("/") else { throw FSResolveError.invalidAddress(address) }
    return try resolveSpacePath(address)
  }

  private func resolveMachinePath(_ rest: String, address: String) throws -> FSResolution {
    let (id, path) = FSResolver.splitAuthority(rest)
    guard !id.isEmpty else { throw FSResolveError.invalidAddress(address) }
    if FSResolver.revisionSuffix(path) != nil {
      throw FSResolveError.machineRevision(address)
    }
    return FSResolution(backend: try machine(id), path: path, machine: id)
  }

  // System paths follow the space grammar and have no revisions: the "@" a
  // revision would need is not a path character.
  private func resolveSystemPath(_ raw: String, address: String) throws -> FSResolution {
    let path: SpacePath
    do {
      path = try SpacePath(validating: raw)
    } catch {
      throw FSResolveError.invalidAddress(address)
    }
    return FSResolution(backend: system, path: path.rawValue, machine: nil, system: true)
  }

  private func resolveSpacePath(_ raw: String) throws -> FSResolution {
    let (pathString, revision) = try FSResolver.splitRevision(raw)
    let path: SpacePath
    do {
      path = try SpacePath(validating: pathString)
    } catch {
      throw FSResolveError.invalidAddress(pathString)
    }
    return FSResolution(backend: revision.map(spaceAt) ?? space, path: path.rawValue, machine: nil)
  }

  private func resolveGroupPath(_ raw: String, group id: String) throws -> FSResolution {
    let (pathString, revision) = try FSResolver.splitRevision(raw)
    let path: SpacePath
    do {
      path = try SpacePath(validating: pathString)
    } catch {
      throw FSResolveError.invalidAddress(pathString)
    }
    return FSResolution(backend: try group(id, revision), path: path.rawValue, machine: nil, group: id)
  }

  private static func splitAuthority(_ rest: String) -> (authority: String, path: String) {
    guard let slash = rest.firstIndex(of: "/") else { return (rest, "/") }
    return (String(rest[..<slash]), String(rest[slash...]))
  }

  private static func splitRevision(_ raw: String) throws -> (path: String, revision: Int?) {
    guard let suffix = revisionSuffix(raw) else { return (raw, nil) }
    guard let revision = Int(suffix.digits) else { throw FSResolveError.invalidAddress(raw) }
    return (suffix.path, revision)
  }

  private static func revisionSuffix(_ raw: String) -> (path: String, digits: Substring)? {
    guard let at = raw.lastIndex(of: "@") else { return nil }
    let suffix = raw[raw.index(after: at)...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isASCIIDigit) else { return nil }
    return (String(raw[..<at]), suffix)
  }
}

public enum FSResolveError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidAddress(String)
  case machineRevision(String)
  /// A `wuhu://<host>/…` address whose host is not `system`: no other host
  /// names a file the file tools take.
  case unsupportedHost(String)

  public var description: String {
    switch self {
    case let .invalidAddress(address):
      "invalid address: \(address)"
    case let .machineRevision(address):
      "machine paths have no revisions: \(address)"
    case let .unsupportedHost(address):
      "not a file address: \(address); use /<path> for this group, wuhu://<group>.localspace/<path> for another group, machines://<machine>/<path> for a machine or wuhu://system/<path> for the system files"
    }
  }
}

private extension String {
  func dropSchemePrefix(_ prefix: String) -> String? {
    guard count >= prefix.count, self.prefix(prefix.count).lowercased() == prefix else { return nil }
    return String(dropFirst(prefix.count))
  }
}

private extension Character {
  var isASCIIDigit: Bool { isASCII && isNumber }
}
