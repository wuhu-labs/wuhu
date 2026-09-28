import Dependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

private let testSecret: [UInt8] = Array(0 ..< 32)

private let tinyWords = [
  "apple", "bird", "cabin", "deer", "eagle", "frog", "goat", "hawk",
  "kite", "lion", "mule", "newt", "opal", "pony", "seal", "wolf",
]

private func roundTrip(_ id: Int64, words: [String]) -> (name: String, back: Int64?) {
  let name = AllocationNames.name(for: id, words: words, secret: testSecret)
  return (name, AllocationNames.id(for: name, words: words, secret: testSecret))
}

@Suite struct AllocationNameTests {
  @Test func tinyVocabularyWidthThreeIsExhaustivelyBijective() {
    let domain = Int64(tinyWords.count * tinyWords.count * tinyWords.count)
    var names = Set<String>()
    for id in 1 ... domain {
      let (name, back) = roundTrip(id, words: tinyWords)
      #expect(back == id)
      #expect(name.split(separator: "-").count == 3)
      names.insert(name)
    }
    #expect(names.count == Int(domain))
  }

  @Test func tinyVocabularyBoundarySweepHasNoCollisions() {
    let boundary = Int64(tinyWords.count * tinyWords.count * tinyWords.count)
    var names = Set<String>()
    for id in max(1, boundary - 400) ... boundary + 400 {
      let (name, back) = roundTrip(id, words: tinyWords)
      #expect(back == id)
      #expect(name.split(separator: "-").count == (id <= boundary ? 3 : 4))
      names.insert(name)
    }
    #expect(names.count == 801)
  }

  @Test func realVocabularyBoundarySweepHasNoCollisions() {
    let count = Int64(AllocationVocabulary.words.count)
    let boundary = count * count * count
    #expect(boundary == 16_777_216)
    #expect(roundTrip(16_777_216, words: AllocationVocabulary.words).name.split(separator: "-").count == 3)
    #expect(roundTrip(16_777_217, words: AllocationVocabulary.words).name.split(separator: "-").count == 4)
    var names = Set<String>()
    for id in boundary - 750 ... boundary + 750 {
      let (name, back) = roundTrip(id, words: AllocationVocabulary.words)
      #expect(back == id)
      #expect(name.split(separator: "-").count == (id <= boundary ? 3 : 4))
      names.insert(name)
    }
    #expect(names.count == 1501)
  }

  @Test(arguments: [3, 4, 5, 6]) func randomSamplesRoundTripPerWidth(width: Int) {
    let count = Int64(AllocationVocabulary.words.count)
    var base: Int64 = 0
    var size = count * count * count
    for _ in 3 ..< width {
      base += size
      size *= count
    }
    var rng = SeededRNG(seed: UInt64(width))
    for _ in 0 ..< 500 {
      let id = base + Int64.random(in: 0 ..< size, using: &rng) + 1
      let (name, back) = roundTrip(id, words: AllocationVocabulary.words)
      #expect(back == id)
      #expect(name.split(separator: "-").count == width)
    }
  }

  @Test func malformedNamesDecodeToNil() {
    let words = AllocationVocabulary.words
    #expect(AllocationNames.id(for: "", words: words, secret: testSecret) == nil)
    #expect(AllocationNames.id(for: "apple-bird", words: words, secret: testSecret) == nil)
    #expect(AllocationNames.id(for: "apple-bird-wuhu", words: words, secret: testSecret) == nil)
    #expect(AllocationNames.id(for: "apple--bird", words: words, secret: testSecret) == nil)
    let overlong = Array(repeating: "apple", count: 80).joined(separator: "-")
    #expect(AllocationNames.id(for: overlong, words: words, secret: testSecret) == nil)
  }

  // The digest test cannot catch a Feistel change; these pin the construction
  // itself against post-freeze drift.
  @Test func constructionKnownAnswersArePinned() {
    let words = AllocationVocabulary.words
    #expect(AllocationNames.name(for: 1, words: words, secret: testSecret) == "candy-creek-cabin")
    #expect(AllocationNames.name(for: 2, words: words, secret: testSecret) == "yellow-quick-cream")
    #expect(AllocationNames.name(for: 1000, words: words, secret: testSecret) == "goose-pond-fish")
    #expect(AllocationNames.name(for: 16_777_216, words: words, secret: testSecret) == "wise-book-butter")
    #expect(AllocationNames.name(for: 16_777_217, words: words, secret: testSecret) == "fork-earth-clock-syrup")
    #expect(AllocationNames.name(for: 4_242_424_242, words: words, secret: testSecret) == "brown-wave-radar-hill")
  }

  @Test func vocabularyIsFrozen() {
    #expect(AllocationVocabulary.words.count == 256)
    #expect(Set(AllocationVocabulary.words).count == 256)
    #expect(Set(AllocationVocabulary.words.map { String($0.prefix(4)) }).count == 256)
    #expect(AllocationVocabulary.digest == "1ae56cdf9be6145148d00fb2305e7baf1f502a50c75ba25d230aa9e6c4bd6cd6")
  }
}

@Suite struct AllocationSpaceTests {
  private func makeAllocationSpace() throws -> Space {
    try withDependencies {
      $0.date = .constant(fixedDate)
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 7))
    } operation: {
      try Space.inMemory()
    }
  }

  @Test func concurrentAllocationsShareOneCounter() async throws {
    let space = try makeAllocationSpace()
    let allocations = try await withThrowingTaskGroup(of: Allocation.self) { group in
      for slot in 0 ..< 32 {
        let kind: AllocationKind = slot.isMultiple(of: 2) ? .persona : .session
        group.addTask { try await space.allocate(kind, createdBy: "tester") }
      }
      return try await group.reduce(into: [Allocation]()) { $0.append($1) }
    }
    #expect(allocations.map(\.id).sorted() == Array(1 ... 32))
    #expect(Set(allocations.map(\.name)).count == 32)
    let freezeCount = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allocation_freeze")!
    }
    #expect(freezeCount == 1)
  }

  @Test func namesDeriveFromTheFrozenSecret() async throws {
    let space = try makeAllocationSpace()
    let first = try await space.allocate(.persona, createdBy: "tester")
    let second = try await space.allocate(.session, createdBy: "tester")
    #expect(first.id == 1)
    #expect(second.id == 2)
    let secret = try await space.writer.read { db in
      Array(try Row.fetchOne(db, sql: "SELECT secret FROM allocation_freeze WHERE id = 1")!["secret"] as Data)
    }
    #expect(secret.count == 32)
    for allocation in [first, second] {
      #expect(allocation.name == AllocationNames.name(for: allocation.id, words: AllocationVocabulary.words, secret: secret))
      #expect(AllocationNames.id(for: allocation.name, words: AllocationVocabulary.words, secret: secret) == allocation.id)
    }
  }

  @Test func allocationRefusesAfterVocabularyDrift() async throws {
    let space = try makeAllocationSpace()
    _ = try await space.allocate(.persona, createdBy: "tester")
    try await space.writer.write { db in
      try db.execute(sql: "UPDATE allocation_freeze SET vocab_sha256 = 'stale-digest'")
    }
    await #expect(throws: SpaceError.vocabularyFrozen("stale-digest")) {
      _ = try await space.allocate(.session, createdBy: "tester")
    }
    let count = try await space.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allocations")!
    }
    #expect(count == 1)
  }

  @Test func allocationRowsRecordKindAndCreator() async throws {
    let space = try makeAllocationSpace()
    _ = try await space.allocate(.persona, createdBy: "alice")
    _ = try await space.allocate(.session, createdBy: "bob")
    let rows = try await space.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT id, kind, created_by FROM allocations ORDER BY id")
        .map { (id: $0["id"] as Int64, kind: $0["kind"] as String, createdBy: $0["created_by"] as String) }
    }
    #expect(rows.map(\.id) == [1, 2])
    #expect(rows.map(\.kind) == ["persona", "session"])
    #expect(rows.map(\.createdBy) == ["alice", "bob"])
  }
}
