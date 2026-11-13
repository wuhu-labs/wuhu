#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import StructuredQueries
import WuweiQueries

@Table("personas")
struct PersonaRow {
  @Column(primaryKey: true) var name: String
  var allocation: Int64
  var pubkey: String
  @Column("account_id") var accountID: String
  @Column("created_at") var createdAt: String

  var record: PersonaRecord { PersonaRecord(name: name, key: pubkey, account: AccountID(rawValue: accountID)) }
}

public struct PersonaRecord: Equatable, Sendable {
  public let name: String
  public let key: String
  public let account: AccountID
}

extension Space {
  public func adoptPersona(key: KeyRecord) async throws -> PersonaRecord {
    if let existing = worker.cell(PersonCell.ID(key.account.rawValue)).persona() { return existing }
    guard let account = cell.account(key.account), account.removedAt == nil else { throw SpaceError.notFound(key.account.rawValue) }
    if account.kind == .human { _ = try await ensurePersonalGroup(account: key.account) }
    let allocation: (id: Int64, name: String)
    if let reserved = cell.reservedPersona(key.account) { allocation = reserved }
    else {
      let drawn = try await allocate(.persona, createdBy: key.pubkey)
      allocation = (drawn.id, drawn.name)
    }
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(key.account.rawValue)) { try $0.adoptPersona(key: key, allocation: allocation.id, name: allocation.name, at: now) }
  }

  public func persona(named name: String) async throws -> PersonaRecord? { cell.persona(named: name) }
  public func persona(account: AccountID) async throws -> PersonaRecord? { worker.cell(PersonCell.ID(account.rawValue)).persona() }
  public func personas() async throws -> [PersonaRecord] { cell.personas() }
}

extension PersonCell {
  public func persona() -> PersonaRecord? {
    db.rows(PersonaRow.where { $0.accountID.eq(id.key) }.order { $0.allocation }.limit(1)).first?.record
  }

  mutating func adoptPersona(key: KeyRecord, allocation: Int64, name: String, at now: Date) throws -> PersonaRecord {
    if let existing = persona() { return existing }
    try requireAccount()
    let row = PersonaRow(name: name, allocation: allocation, pubkey: key.pubkey, accountID: id.key, createdAt: SQLiteDateFormat.string(from: now))
    try db.execute(PersonaRow.insert { row })
    return row.record
  }
}

extension SpaceCell {
  func persona(named name: String) -> PersonaRecord? { db.rows(PersonaRow.where { $0.name.eq(name) }).first?.record }
  func personas() -> [PersonaRecord] {
    var seen: Set<String> = []
    return db.rows(PersonaRow.order { $0.allocation }).filter { seen.insert($0.accountID).inserted }.map(\.record)
  }

  func reservedPersona(_ account: AccountID) -> (id: Int64, name: String)? {
    guard let allocation = db.rows(AllocationRow.where {
      $0.kind.eq(AllocationKind.persona.rawValue) && $0.createdBy.eq(account.rawValue) && !$0.id.in(PersonaRow.select { $0.allocation })
    }.order { $0.id }.limit(1)
      .join(AllocationFreezeRow.all) { _, _ in #sql("1", as: Bool.self) }
      .select { ReservedPersona.Columns(id: $0.id, secret: $1.secret) }).first else { return nil }
    return (allocation.id, AllocationNames.name(for: allocation.id, words: AllocationVocabulary.words, secret: Array(allocation.secret)))
  }
}

@Selection
private struct ReservedPersona {
  var id: Int64
  var secret: [UInt8]
}
