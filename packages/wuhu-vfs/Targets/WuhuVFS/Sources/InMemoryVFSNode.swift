import Foundation

/// An in-memory `VFSNode` backed by a pure Swift tree. Used primarily in tests.
///
/// Public nodes are lightweight, sendable handles into a single actor-owned
/// tree. The mutable tree nodes themselves are private, non-`Sendable` state
/// that never escapes the storage actor.
public struct InMemoryVFSNode: VFSNode {
  private let storage: InMemoryVFSStorage
  private let id: InMemoryVFSNodeID

  public let isMutable: Bool

  public init(isMutable: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
    let storage = InMemoryVFSStorage(isMutable: isMutable, now: now)
    self.init(storage: storage, id: storage.rootID, isMutable: isMutable)
  }

  private init(storage: InMemoryVFSStorage, id: InMemoryVFSNodeID, isMutable: Bool) {
    self.storage = storage
    self.id = id
    self.isMutable = isMutable
  }

  // MARK: - Identity

  public var status: VFSNodeStatus? {
    get async {
      await storage.status(of: id)
    }
  }

  // MARK: - Navigation

  public func children() async throws -> [VFSDirectoryEntry] {
    try await storage.children(of: id)
  }

  public func childNode(_ name: String) async throws -> (any VFSNode)? {
    try VFSPathComponent.require(name)
    return try await storage.childNode(name, of: id).map {
      InMemoryVFSNode(storage: storage, id: $0, isMutable: isMutable)
    }
  }

  // MARK: - Data

  public func readData() async throws -> Data {
    try await storage.readData(from: id)
  }

  public func writeData(_ data: Data, append: Bool) async throws {
    try await storage.writeData(data, to: id, append: append)
  }

  // MARK: - Creation

  public func createFile(_ name: String, data: Data) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    return try await child(id: storage.createFile(name, data: data, in: id))
  }

  public func createDirectory(_ name: String) async throws -> any VFSNode {
    try VFSPathComponent.require(name)
    return try await child(id: storage.createDirectory(name, in: id))
  }

  // MARK: - Removal

  public func remove(recursive: Bool) async throws {
    try await storage.remove(id, recursive: recursive)
  }

  // MARK: - Fast-path operations

  public func rename(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    guard let source = source as? InMemoryVFSNode else { return false }

    if storage === source.storage {
      return try await storage.rename(source.id, as: name, into: id)
    }

    let snapshot = try await source.storage.snapshot(of: source.id)
    try await storage.install(snapshot, as: name, into: id)
    return true
  }

  public func copy(_ source: any VFSNode, as name: String) async throws -> Bool {
    try VFSPathComponent.require(name)
    guard let source = source as? InMemoryVFSNode else { return false }

    if storage === source.storage {
      return try await storage.copy(source.id, as: name, into: id)
    }

    let snapshot = try await source.storage.snapshot(of: source.id)
    try await storage.install(snapshot, as: name, into: id)
    return true
  }

  // MARK: - Test helpers

  /// Seed a file at the given path within this tree. Creates intermediate
  /// directories as needed.
  public func seedFile(at path: VFSPath, data: Data) async throws {
    try await storage.seedFile(path: path, data: data)
  }

  /// Seed a directory at the given path.
  public func seedDirectory(at path: VFSPath) async throws {
    try await storage.seedDirectory(path: path)
  }

  /// Read stored data for test assertions.
  public func storedData(at path: VFSPath) async -> Data? {
    await storage.storedData(path: path)
  }

  private func child(id: InMemoryVFSNodeID) -> InMemoryVFSNode {
    InMemoryVFSNode(storage: storage, id: id, isMutable: isMutable)
  }
}

private struct InMemoryVFSNodeID: Hashable, Sendable {
  var rawValue: Int
}

private actor InMemoryVFSStorage {
  nonisolated let rootID = InMemoryVFSNodeID(rawValue: 0)

  private let isMutable: Bool
  private let now: @Sendable () -> Date
  private var nextID = 1
  private var nodes: [InMemoryVFSNodeID: InMemoryVFSTreeNode]

  init(isMutable: Bool, now: @escaping @Sendable () -> Date) {
    self.isMutable = isMutable
    self.now = now
    let nowDate = now()
    nodes = [
      rootID: InMemoryVFSTreeNode(
        payload: .directory([:]),
        mode: 0o755,
        uid: 0,
        gid: 0,
        accessedAt: nowDate,
        createdAt: nowDate,
      ),
    ]
  }

  // MARK: - Identity

  func status(of id: InMemoryVFSNodeID) -> VFSNodeStatus? {
    guard let node = nodes[id] else { return nil }
    let size: Int64
    let modifiedAt: Date
    switch node.payload {
    case let .file(data, mtime):
      size = Int64(data.count)
      modifiedAt = mtime
    case .directory:
      size = 128
      modifiedAt = node.createdAt
    }
    return VFSNodeStatus(
      kind: node.kind,
      size: size,
      modifiedAt: modifiedAt,
      accessedAt: node.accessedAt,
      createdAt: node.createdAt,
      mode: node.mode,
      uid: node.uid,
      gid: node.gid,
    )
  }

  // MARK: - Navigation

  func children(of id: InMemoryVFSNodeID) throws -> [VFSDirectoryEntry] {
    let children = try node(id).directoryChildren()
    return try children.map { name, id in
      try VFSDirectoryEntry(name: name, kind: node(id).kind)
    }.sorted { $0.name < $1.name }
  }

  func childNode(_ name: String, of id: InMemoryVFSNodeID) throws -> InMemoryVFSNodeID? {
    try node(id).child(named: name)
  }

  // MARK: - Data

  func readData(from id: InMemoryVFSNodeID) throws -> Data {
    let node = try node(id)
    guard case let .file(data, _) = node.payload else {
      throw VFSNodeError.notAFile
    }
    node.accessedAt = now()
    return data
  }

  func writeData(_ data: Data, to id: InMemoryVFSNodeID, append: Bool) throws {
    try requireMutable()

    let node = try node(id)
    guard case let .file(existing, _) = node.payload else {
      throw VFSNodeError.notAFile
    }

    if append {
      var combined = existing
      combined.append(data)
      node.payload = .file(combined, mtime: now())
    } else {
      node.payload = .file(data, mtime: now())
    }
  }

  // MARK: - Creation

  func createFile(_ name: String, data: Data, in parentID: InMemoryVFSNodeID) throws -> InMemoryVFSNodeID {
    try createNode(.file(data, mtime: now()), named: name, in: parentID, mode: 0o644)
  }

  func createDirectory(_ name: String, in parentID: InMemoryVFSNodeID) throws -> InMemoryVFSNodeID {
    try createNode(.directory([:]), named: name, in: parentID, mode: 0o755)
  }

  // MARK: - Removal

  func remove(_ id: InMemoryVFSNodeID, recursive: Bool) throws {
    try requireMutable()

    let node = try node(id)
    if case let .directory(children) = node.payload, !recursive, !children.isEmpty {
      throw VFSError.directoryNotEmpty(path: "(in-memory)")
    }

    detach(id)
  }

  // MARK: - Fast-path operations

  func rename(_ sourceID: InMemoryVFSNodeID, as name: String, into destinationID: InMemoryVFSNodeID) throws -> Bool {
    try requireMutable()
    let source = try node(sourceID)
    let destination = try directoryNode(destinationID)
    try requireMissingChild(name, in: destination)

    detach(sourceID)
    try destination.setChild(sourceID, named: name)
    source.parent = destinationID
    source.name = name
    return true
  }

  func copy(_ sourceID: InMemoryVFSNodeID, as name: String, into destinationID: InMemoryVFSNodeID) throws -> Bool {
    try install(snapshot(of: sourceID), as: name, into: destinationID)
    return true
  }

  func snapshot(of id: InMemoryVFSNodeID) throws -> InMemoryVFSTreeSnapshot {
    let source = try node(id)
    let payload: InMemoryVFSTreeSnapshot.Payload = switch source.payload {
    case let .file(data, mtime):
      .file(data, mtime: mtime)
    case let .directory(children):
      .directory(Dictionary(uniqueKeysWithValues: try children.map { name, id in
        try (name, snapshot(of: id))
      }))
    }

    return InMemoryVFSTreeSnapshot(
      payload: payload,
      mode: source.mode,
      uid: source.uid,
      gid: source.gid,
    )
  }

  func install(
    _ snapshot: InMemoryVFSTreeSnapshot,
    as name: String,
    into destinationID: InMemoryVFSNodeID,
  ) throws {
    try requireMutable()
    let destination = try directoryNode(destinationID)
    try requireMissingChild(name, in: destination)
    try destination.setChild(clone(snapshot, parent: destinationID, name: name), named: name)
  }

  // MARK: - Test helpers

  func seedFile(path: VFSPath, data: Data) throws {
    guard let name = path.lastComponent else { return }
    let parent = try seedDirectory(path: path.parent ?? .root)
    _ = try createFile(name.rawValue, data: data, in: parent)
  }

  @discardableResult
  func seedDirectory(path: VFSPath) throws -> InMemoryVFSNodeID {
    var current = rootID
    for component in path.components {
      if let child = try childNode(component.rawValue, of: current) {
        current = child
      } else {
        current = try createDirectory(component.rawValue, in: current)
      }
    }
    return current
  }

  func storedData(path: VFSPath) -> Data? {
    do {
      var current = rootID
      for component in path.components {
        guard let child = try childNode(component.rawValue, of: current) else { return nil }
        current = child
      }
      return try readData(from: current)
    } catch {
      return nil
    }
  }

  // MARK: - Private

  private func requireMutable() throws {
    guard isMutable else { throw VFSNodeError.immutable }
  }

  private func node(_ id: InMemoryVFSNodeID) throws -> InMemoryVFSTreeNode {
    guard let node = nodes[id] else { throw VFSNodeError.notFound }
    return node
  }

  private func directoryNode(_ id: InMemoryVFSNodeID) throws -> InMemoryVFSTreeNode {
    let node = try node(id)
    guard case .directory = node.payload else { throw VFSNodeError.notADirectory }
    return node
  }

  private func requireMissingChild(_ name: String, in directory: InMemoryVFSTreeNode) throws {
    guard try directory.child(named: name) == nil else { throw VFSNodeError.forbidden }
  }

  private func createNode(
    _ payload: InMemoryVFSTreeNode.Payload,
    named name: String,
    in parentID: InMemoryVFSNodeID,
    mode: UInt16,
  ) throws -> InMemoryVFSNodeID {
    try requireMutable()

    let parent = try directoryNode(parentID)
    try requireMissingChild(name, in: parent)

    let id = nextNodeID()
    let nowDate = now()
    nodes[id] = InMemoryVFSTreeNode(
      payload: payload,
      mode: mode,
      uid: parent.uid,
      gid: parent.gid,
      accessedAt: nowDate,
      createdAt: nowDate,
      parent: parentID,
      name: name,
    )
    try parent.setChild(id, named: name)
    return id
  }

  private func nextNodeID() -> InMemoryVFSNodeID {
    defer { nextID += 1 }
    return InMemoryVFSNodeID(rawValue: nextID)
  }

  private func detach(_ id: InMemoryVFSNodeID) {
    guard let node = nodes[id], let parentID = node.parent, let name = node.name else { return }
    if let parent = nodes[parentID], (try? parent.child(named: name)) == id {
      try? parent.setChild(nil, named: name)
    }
    node.parent = nil
    node.name = nil
  }

  private func clone(
    _ snapshot: InMemoryVFSTreeSnapshot,
    parent: InMemoryVFSNodeID,
    name: String,
  ) -> InMemoryVFSNodeID {
    let id = nextNodeID()
    let nowDate = now()
    let payload: InMemoryVFSTreeNode.Payload = switch snapshot.payload {
    case let .file(data, mtime):
      .file(data, mtime: mtime)
    case .directory:
      .directory([:])
    }

    let node = InMemoryVFSTreeNode(
      payload: payload,
      mode: snapshot.mode,
      uid: snapshot.uid,
      gid: snapshot.gid,
      accessedAt: nowDate,
      createdAt: nowDate,
      parent: parent,
      name: name,
    )
    nodes[id] = node

    if case let .directory(children) = snapshot.payload {
      for (childName, child) in children {
        try! node.setChild(clone(child, parent: id, name: childName), named: childName)
      }
    }
    return id
  }
}

private final class InMemoryVFSTreeNode {
  enum Payload {
    case file(Data, mtime: Date)
    case directory([String: InMemoryVFSNodeID])
  }

  var payload: Payload
  var mode: UInt16
  var uid: UInt32
  var gid: UInt32
  var accessedAt: Date
  var createdAt: Date
  var parent: InMemoryVFSNodeID?
  var name: String?

  init(
    payload: Payload,
    mode: UInt16,
    uid: UInt32,
    gid: UInt32,
    accessedAt: Date,
    createdAt: Date,
    parent: InMemoryVFSNodeID? = nil,
    name: String? = nil,
  ) {
    self.payload = payload
    self.mode = mode
    self.uid = uid
    self.gid = gid
    self.accessedAt = accessedAt
    self.createdAt = createdAt
    self.parent = parent
    self.name = name
  }

  var kind: VFSNodeKind {
    switch payload {
    case .file:
      .file
    case .directory:
      .directory
    }
  }

  func directoryChildren() throws -> [String: InMemoryVFSNodeID] {
    guard case let .directory(children) = payload else { throw VFSNodeError.notADirectory }
    return children
  }

  func child(named name: String) throws -> InMemoryVFSNodeID? {
    try directoryChildren()[name]
  }

  func setChild(_ child: InMemoryVFSNodeID?, named name: String) throws {
    var children = try directoryChildren()
    children[name] = child
    payload = .directory(children)
  }
}

private struct InMemoryVFSTreeSnapshot: Sendable {
  indirect enum Payload: Sendable {
    case file(Data, mtime: Date)
    case directory([String: InMemoryVFSTreeSnapshot])
  }

  var payload: Payload
  var mode: UInt16
  var uid: UInt32
  var gid: UInt32
}
