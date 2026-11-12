import Foundation
import StructuredQueries
import Wuwei

@Table("allocations")
struct AllocationRow {
  @Column(primaryKey: true) var id: Int64
  var kind: String
  @Column("created_by") var createdBy: String
  @Column("created_at") var createdAt: String
}

@Table("allocation_freeze")
struct AllocationFreezeRow {
  @Column(primaryKey: true) var id: Int64
  @Column("vocab_sha256") var vocabSHA256: String
  var secret: [UInt8]
}

extension SpaceCell {
  /// Draws the next name of `kind` for `createdBy`, freezing the space's vocabulary with `candidate` on the first draw.
  mutating func draw(
    _ kind: AllocationKind, createdBy: String, created: String, candidate: [UInt8],
  ) throws -> (id: Int64, name: String) {
    let secret: [UInt8]
    if let frozen = db.rows(AllocationFreezeRow.all).first {
      guard frozen.vocabSHA256 == AllocationVocabulary.digest else { throw SpaceError.vocabularyFrozen(frozen.vocabSHA256) }
      secret = frozen.secret
    } else {
      try db.execute(AllocationFreezeRow.insert { AllocationFreezeRow(id: 1, vocabSHA256: AllocationVocabulary.digest, secret: candidate) })
      secret = candidate
    }
    try db.execute(AllocationRow.insert { AllocationRow.Draft(kind: kind.rawValue, createdBy: createdBy, createdAt: created) })
    let id = db.one("SELECT last_insert_rowid()")!.integer!
    return (id, AllocationNames.name(for: id, words: AllocationVocabulary.words, secret: secret))
  }
}

extension Space {
  @discardableResult
  public func allocate(_ kind: AllocationKind, createdBy: String) async throws -> Allocation {
    let createdAt = dateGen.now
    let created = SQLiteDateFormat.string(from: createdAt)
    let candidate = Allocations.mintSecretCandidate(rng)
    let drawn = try await worker.call(SpaceCell.ID("space")) {
      try $0.draw(kind, createdBy: createdBy, created: created, candidate: candidate)
    }
    return Allocation(id: drawn.id, name: drawn.name, kind: kind, createdBy: createdBy, createdAt: createdAt)
  }
}
