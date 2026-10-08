import struct Foundation.Data
import JSONValue
import MachineContract
import SpaceContract
import SpaceCore
import SpaceFS
import SystemFiles

public struct SpaceToolContext: Sendable {
  public let space: Space
  let machines: MachineSeam?
  public let principal: Principal
  /// The page acting, by its path in `principal`'s group: its writes are the
  /// group's minus admin, and each revision records the viewer via the page.
  public let page: SpacePath?

  public init(space: Space, machines: MachineSeam? = nil, principal: Principal, page: SpacePath? = nil) {
    self.space = space
    self.machines = machines.map { Self.gated($0, space: space, acting: principal.group) }
    self.principal = principal
    self.page = page
  }

  var attribution: RevisionAttribution? {
    page.map { RevisionAttribution(actor: principal.member, via: $0.rawValue) }
  }

  /// A page writes as a non-admin member agent of its group: never a session
  /// home, and a layer only its own group's, never `shared`'s. Everyone else
  /// meets the layer rule as themselves.
  func refuseWrite(_ path: SpacePath, in group: GroupID) async throws {
    guard page != nil else {
      if case let .session(session) = principal.actor {
        try SessionHome.refuseForeignWrite(to: path, in: group, by: session, home: principal.group)
      }
      try await space.refuseLayerWrite(path, in: group, by: principal.actor)
      return
    }
    if let owner = path.homeOwner { throw SpaceError.foreignHome(path: path.rawValue, owner: owner) }
    if GroupLayer.covers(path, in: group), group == .shared || group != principal.group {
      throw SpaceError.layerForbidden(path: path.rawValue, group: group.rawValue)
    }
  }

  /// The seam as `acting` may use it: a machine of a group it does not read is
  /// no machine at all, on every route that builds a context. (An id with no
  /// row names nothing the hub could reach either.)
  static func gated(_ seam: MachineSeam, space: Space, acting: GroupID) -> MachineSeam {
    @Sendable func requireUsable(_ machine: MachineID) async throws {
      guard let record = try await space.machine(machine), try await !space.reads(acting).contains(record.group) else { return }
      throw ToolRunError.failed(code: .notFound, message: "unknown machine: \(machine.rawValue)", hint: nil)
    }
    return MachineSeam(
      vfs: { machine, op in
        try await requireUsable(machine)
        return try await seam.vfs(machine, op)
      },
      search: { machine, query in
        try await requireUsable(machine)
        return try await seam.search(machine, query)
      },
      attached: {
        var usable = Set<MachineID>()
        for machine in await seam.attached() where (try? await requireUsable(machine)) != nil {
          usable.insert(machine)
        }
        return usable
      },
    )
  }

  struct Target {
    let backend: any SpaceVFS
    let path: String
    let machine: MachineID?
    var system = false
    /// A space path's group; nil for a machine's or the system's.
    var group: GroupID?
    /// Named as `wuhu://<group>.localspace/…` rather than hostless.
    var qualified = false

    /// A revisioned space path: neither a machine's nor the system's.
    var isSpace: Bool { machine == nil && !system }

    /// `path` as the caller should see it: in the form it was named in.
    func rendered(_ path: String) -> String {
      guard let group, qualified else { return system ? SystemFiles.address(path) : path }
      return FSResolver.address(path, inGroup: group.rawValue)
    }
  }

  func resolve(_ address: String, rev: Int? = nil) throws -> Target {
    let space = space
    let seam = machines
    let acting = principal.group
    let actor = principal.actor
    let resolver = FSResolver(
      space: SpaceView(space: space, group: acting, acting: acting, actor: actor, rev: nil),
      spaceAt: { SpaceView(space: space, group: acting, acting: acting, actor: actor, rev: $0) },
      machine: { raw in
        guard MachineID.isValid(raw) else {
          throw ToolRunError.failed(code: .invalidPath, message: "invalid machine id: \(raw)", hint: nil)
        }
        guard let seam else {
          throw ToolRunError.failed(code: .unavailable, message: "machine backends are not available on this surface", hint: nil)
        }
        return MachineBackend(machine: MachineID(rawValue: raw), seam: seam)
      },
      system: SystemFiles.vfs,
      group: { id, rev in SpaceView(space: space, group: GroupID(rawValue: id), acting: acting, actor: actor, rev: rev) },
    )
    let resolution = try resolver.resolve(address)
    let machine = resolution.machine.map(MachineID.init(rawValue:))
    let group = resolution.machine == nil && !resolution.system ? resolution.group.map(GroupID.init(rawValue:)) ?? acting : nil
    if let rev {
      guard machine == nil else {
        throw ToolRunError.failed(code: .unsupported, message: "machine paths have no revisions: \(address)", hint: nil)
      }
      guard !resolution.system else {
        throw ToolRunError.failed(code: .unsupported, message: "wuhu://system/ has no revisions: \(address)", hint: nil)
      }
      return Target(
        backend: SpaceView(space: space, group: group!, acting: acting, actor: actor, rev: rev), path: resolution.path, machine: nil,
        group: group, qualified: resolution.group != nil,
      )
    }
    return Target(
      backend: resolution.backend, path: resolution.path, machine: machine, system: resolution.system,
      group: group, qualified: resolution.group != nil,
    )
  }

  /// A space path and its group, hostless or `wuhu://<group>.localspace/…`;
  /// a group the actor does not read answers as a missing path.
  func spaceTarget(_ address: String) async throws -> (group: GroupID, path: SpacePath, qualified: Bool) {
    guard !address.contains("@") else {
      throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(address)", hint: nil)
    }
    let target = try resolve(address)
    guard let group = target.group else {
      throw ToolRunError.failed(code: .invalidPath, message: "not a space path: \(address)", hint: nil)
    }
    let path = try spacePath(target.path)
    try await SpaceView.requireReadable(group, by: principal.group, actor: principal.actor, path: path.rawValue, in: space)
    return (group, path, target.qualified)
  }

  func machineSearch(_ machine: MachineID, _ query: SearchQuery) async throws -> SearchResult {
    guard let machines else {
      throw ToolRunError.failed(code: .unavailable, message: "machine backends are not available on this surface", hint: nil)
    }
    return try await machines.search(machine, query)
  }

  func spacePath(_ raw: String) throws -> SpacePath {
    do {
      return try SpacePath(validating: raw)
    } catch {
      throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(raw)", hint: nil)
    }
  }
}

public enum ToolRunError: Error, Sendable, Equatable {
  case undecodableInput(String)
  /// `token` is a conflict's current version, when the verb knows it.
  case failed(code: ErrorCode, message: String, hint: String?, token: String? = nil)

  public var payload: JSONValue {
    switch self {
    case let .undecodableInput(message):
      Wire.toolError(code: .invalidArgument, message: message, hint: nil)
    case let .failed(code, message, hint, token):
      Wire.toolError(code: code, message: message, hint: hint, token: token)
    }
  }
}

public struct SpaceTool: Sendable {
  public let name: String
  public let inputSchema: JSONValue
  private let execute: @Sendable (SpaceToolContext, JSONValue) async throws(ToolRunError) -> JSONValue

  init<Input: Decodable>(
    _ name: String,
    schema: JSONValue,
    _ body: @escaping @Sendable (SpaceToolContext, Input) async throws -> JSONValue,
  ) {
    self.name = name
    self.inputSchema = schema
    self.execute = { context, json async throws(ToolRunError) in
      let input: Input
      do {
        if ["table.create", "table.schema", "table.alter", "table.mutate", "new"].contains(name) {
          try checkedFields(json, allowed: Set(schema.object?["properties"]?.object?.keys.map { $0 } ?? []))
          if let header = json.object?["header"] {
            try checkedFields(header, allowed: ["columns"])
            for column in header.object?["columns"]?.array ?? [] { try checkedFields(column, allowed: ["name", "type"]) }
          }
        }
        input = try JSONValueDecoder().decode(Input.self, from: json)
      } catch {
        throw ToolRunError.undecodableInput("\(name): input does not match the contract schema")
      }
      do {
        return try await body(context, input)
      } catch let error as ToolRunError {
        throw error
      } catch {
        throw Wire.failure(error)
      }
    }
  }

  public func run(_ context: SpaceToolContext, input: JSONValue) async throws(ToolRunError) -> JSONValue {
    try await execute(context, input)
  }
}

// One group's files as the actor sees them: a group it does not read has no
// files at all, so every answer is the one a missing path gets. A group's
// instruction layer takes writes only from those it admits.
struct SpaceView: SpaceVFS {
  let space: Space
  let group: GroupID
  let acting: GroupID
  let actor: Actor
  let rev: Int?

  // A conversation's member reads its attachments in whatever group homes it.
  static func requireReadable(_ group: GroupID, by acting: GroupID, actor: Actor, path: String, in space: Space) async throws {
    guard group != acting, try await !space.reads(acting).contains(group) else { return }
    if let member = Principal(actor: actor, group: acting).member,
       try await space.sessions.readsAttachment(path, in: group, member: member)
    { return }
    throw SpaceError.notFound(path)
  }

  private func view(_ path: String) async throws -> any SpaceVFS {
    try await Self.requireReadable(group, by: acting, actor: actor, path: path, in: space)
    return await space.fs(group, at: rev.map(Rev.init), acting: acting)
  }

  func read(_ path: String) async throws -> (VersionToken, Data) {
    try await view(path).read(path)
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    let fs = try await view(path)
    try await refuseLayer(path)
    return try await fs.write(path, data, ifMatch: ifMatch)
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    let fs = try await view(path)
    try await refuseLayer(path)
    try await fs.delete(path, ifMatch: ifMatch)
  }

  func move(_ path: String, to destination: String) async throws {
    let fs = try await view(path)
    try await refuseLayer(path)
    try await refuseLayer(destination)
    try await fs.move(path, to: destination)
  }

  private func refuseLayer(_ path: String) async throws {
    guard let p = try? SpacePath(validating: path) else { return }
    try await space.refuseLayerWrite(p, in: group, by: actor)
  }

  func list(_ path: String) async throws -> (VersionToken, [SpaceFS.Entry]) {
    try await view(path).list(path)
  }

  func stat(_ path: String) async throws -> SpaceFS.Entry {
    try await view(path).stat(path)
  }
}

private func checkedFields(_ input: JSONValue, allowed: Set<String>) throws {
  guard case let .object(fields) = input, Set(fields.keys).isSubset(of: allowed) else {
    throw ToolRunError.undecodableInput("unsupported fields")
  }
}
