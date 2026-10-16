#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Testing

// Hundreds of live session fixtures otherwise contend with one another and
// their worker children inside the same test executable's short waits.
actor SessionFixtureAdmission {
  struct Timeout: Error, CustomStringConvertible {
    let waiter: String
    let bound: Duration
    let holders: [(name: String, held: Duration)]

    var description: String {
      "\(waiter) waited longer than \(bound) for a session fixture slot; holding: " + holders.map { "\($0.name) for \($0.held)" }.joined(separator: ", ")
    }
  }

  @TaskLocal static var isAdmitted = false

  let capacity: Int
  private var holders: [UUID: (name: String, since: ContinuousClock.Instant)] = [:]
  private var waiting: [(id: UUID, name: String, continuation: AsyncStream<Void>.Continuation)] = []
  var available: Int { capacity - holders.count }
  var waitingCount: Int { waiting.count }

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func acquire(_ name: String, within bound: Duration) async throws -> UUID {
    try Task.checkCancellation()
    let id = UUID()
    if holders.count < capacity {
      holders[id] = (name, .now)
      return id
    }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    waiting.append((id, name, continuation))
    await withTaskGroup(of: Void.self) { group in
      group.addTask { for await _ in stream {} }
      group.addTask { try? await ContinuousClock().sleep(for: bound) }
      _ = await group.next()
      group.cancelAll()
    }
    if let index = waiting.firstIndex(where: { $0.id == id }) {
      waiting.remove(at: index)
      try Task.checkCancellation()
      let now = ContinuousClock.now
      throw Timeout(waiter: name, bound: bound, holders: holders.values.sorted { $0.since < $1.since }.map { ($0.name, now - $0.since) })
    }
    if Task.isCancelled {
      release(id)
      throw CancellationError()
    }
    return id
  }

  func release(_ id: UUID) {
    precondition(holders.removeValue(forKey: id) != nil)
    guard !waiting.isEmpty else { return }
    let next = waiting.removeFirst()
    holders[next.id] = (next.name, .now)
    next.continuation.finish()
  }

  nonisolated func admit<R>(_ name: String, within bound: Duration, _ body: () async throws -> R) async throws -> R {
    let id = try await acquire(name, within: bound)
    do {
      let result = try await Self.$isAdmitted.withValue(true) { try await body() }
      await release(id)
      return result
    } catch {
      await release(id)
      throw error
    }
  }
}

/// Admits each test case to a session fixture slot before starting its time
/// limit, so queueing behind other suites' fixtures never spends a test's own
/// budget. Use it instead of `.timeLimit` on suites that use `withSessionDeps`.
/// Nested scopes share the outermost one's slot; the innermost time limit wins.
struct SessionFixtureTrait: SuiteTrait, TestTrait, TestScoping {
  let timeLimit: Duration
  let admission: SessionFixtureAdmission
  let bound: Duration
  var isRecursive: Bool { true }

  func provideScope(for test: Test, testCase _: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
    if SessionFixtureAdmission.isAdmitted { return try await function() }
    let timeLimit = test.traits.lazy.compactMap { $0 as? SessionFixtureTrait }.last?.timeLimit ?? self.timeLimit
    try await admission.admit(test.name, within: bound) {
      // The group awaits both children before it returns, so `function` never outlives this call.
      try await withoutActuallyEscaping(function) { function in
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await function() }
          group.addTask { [timeLimit] in
            try await ContinuousClock().sleep(for: timeLimit)
            Issue.record("Time limit was exceeded after admission: \(timeLimit)", sourceLocation: test.sourceLocation)
          }
          try await group.next()
          group.cancelAll()
        }
      }
    }
  }
}

extension Trait where Self == SessionFixtureTrait {
  static func sessionFixtures(timeLimit: TimeLimitTrait.Duration, admission: SessionFixtureAdmission = sessionFixtureAdmission, bound: Duration = sessionFixtureAdmissionBound) -> Self {
    Self(timeLimit: TimeLimitTrait.timeLimit(timeLimit).timeLimit, admission: admission, bound: bound)
  }
}

let sessionFixtureAdmission = SessionFixtureAdmission(capacity: 8)
// Clean pool runs queue for up to ~45 s; the bound only turns a leaked slot into a named failure.
let sessionFixtureAdmissionBound = Duration.seconds(300)
