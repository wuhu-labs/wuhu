#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import SpaceFS
import Wuwei

// Machine notes are stored under /_/machines/<machine id>/ and presented under
// the machine's current name, the id also accepted, so a rename moves nothing.
// A group's tree lists the machines of that group, the ones whose notes it holds.
struct MachineFolders: SpaceVFS {
  let base: any SpaceVFS
  let runtime: SpaceRuntime
  let group: GroupID
  var listingLimit: Int?
  var listingByteLimit: Int?

  func read(_ path: String) async throws -> (VersionToken, Data) {
    try await base.read(stored(path))
  }

  func reader(_ path: String) async throws -> any SpaceFileReader {
    try await base.reader(stored(path))
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    try await base.write(stored(path, mutating: true), data, ifMatch: ifMatch)
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    try await base.delete(stored(path, mutating: true), ifMatch: ifMatch)
  }

  func move(_ path: String, to destination: String) async throws {
    try await base.move(stored(path, mutating: true), to: stored(destination, mutating: true))
  }

  func list(_ path: String, from: String, limit: Int) async throws -> (entries: [Entry], next: String?) {
    guard let p = try? SpacePath(validating: path), p.components.starts(with: Self.root) else {
      return try await base.list(path, from: from, limit: limit)
    }
    return try await listBySlicing(path, from: from, limit: limit)
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    guard let p = try? SpacePath(validating: path), p.components.starts(with: Self.root) else {
      return try await base.list(path)
    }
    if p.components == Self.root {
      let machines = try runtime.worker().cell(SpaceCell.ID("space")).machineFolders(group: group, limit: listingLimit, byteLimit: listingByteLimit)
      var entries: [Entry] = []
      for machine in machines {
        entries.append(try await folder(machine.id, named: machine.name ?? machine.id))
      }
      return (try await storedRoot().token, entries.sorted { $0.name < $1.name })
    }
    let target = try await stored(path)
    do {
      return try await base.list(target)
    } catch SpaceError.notFound where p.components.count == 3 {
      return (try await storedRoot().token, [])
    }
  }

  func stat(_ path: String) async throws -> Entry {
    guard let p = try? SpacePath(validating: path), p.components.starts(with: Self.root), p.components.count <= 3 else {
      return try await base.stat(stored(path))
    }
    guard let name = p.components.dropFirst(2).first else {
      do {
        return try await base.stat(path)
      } catch SpaceError.notFound {
        return Entry(name: "machines", kind: .directory, size: 0, lineCount: nil, token: try await storedRoot().token, mtime: .init(timeIntervalSince1970: 0))
      }
    }
    return try await folder(SpacePath(validating: stored(path)).components[2], named: name)
  }

  static func stored(_ path: SpacePath, mutating: Bool, in runtime: SpaceRuntime) async throws -> SpacePath {
    guard path.components.count >= 3, path.components.starts(with: root) else { return path }
    guard let machine = runtime.worker().cell(SpaceCell.ID("space")).machineFolder(path.components[2]) else {
      throw mutating ? SpaceError.alreadyExists(path.rawValue) : SpaceError.notFound(path.rawValue)
    }
    return try SpacePath(components: root + [machine] + path.components.dropFirst(3))
  }

  static let root = ["_", "machines"]

  static func stored(_ path: String, mutating: Bool, in runtime: SpaceRuntime) async throws -> String {
    guard let p = try? SpacePath(validating: path) else { return path }
    return try await stored(p, mutating: mutating, in: runtime).rawValue
  }

  private func stored(_ path: String, mutating: Bool = false) async throws -> String {
    try await Self.stored(path, mutating: mutating, in: runtime)
  }

  private func storedRoot() async throws -> (token: VersionToken, entries: [Entry]) {
    do {
      return try await base.list("/_/machines")
    } catch SpaceError.notFound {
      return (try await base.list("/").0, [])
    }
  }

  private func folder(_ id: String, named name: String) async throws -> Entry {
    var entry: Entry
    do {
      entry = try await base.stat("/_/machines/\(id)")
    } catch SpaceError.notFound {
      entry = Entry(name: name, kind: .directory, size: 0, lineCount: nil, token: try await storedRoot().token, mtime: .init(timeIntervalSince1970: 0))
    }
    entry.name = name
    return entry
  }
}
