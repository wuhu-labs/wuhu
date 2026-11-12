import GRDB
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

extension MachineFolders {
  static func stored(_ path: SpacePath, mutating: Bool, in db: Database) throws -> SpacePath {
    guard path.components.count >= 3, path.components.starts(with: root) else { return path }
    let reference = path.components[2].lowercased().replacingOccurrences(of: "-", with: "_")
    let alias = try Aliases.target(reference, kind: .machine, in: db)
    let machine = try MachineRow.where { $0.id.eq(reference) }.fetchOne(db)
      ?? alias.flatMap { id in try MachineRow.where { $0.id.eq(id) }.fetchOne(db) }
    guard let machine else {
      throw mutating ? SpaceError.alreadyExists(path.rawValue) : SpaceError.notFound(path.rawValue)
    }
    return try SpacePath(components: root + [machine.id] + path.components.dropFirst(3))
  }

  static func requireStored(_ path: SpacePath, in db: Database) throws {
    guard try stored(path, mutating: true, in: db) == path else { throw SpaceError.alreadyExists(path.rawValue) }
  }
}
