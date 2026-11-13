import Clocks
import ControlledTime
import Dependencies
import Foundation
import GRDB
import JSONValue
import Logging
import LoopCore
import SessionTools
import struct SpaceContract.GroupID
@testable import SpaceCore
import SpaceFS
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

func makeSpace(
  date: Date = fixedDate, clock: (any NonsendingClock<Duration>)? = nil, log: Logger? = nil,
  regions: (@Sendable (any DatabaseWriter) -> RegionSource)? = nil,
) throws -> Space {
  try withDependencies {
    $0.installTimeControl(anchor: date)
    $0.date = .constant(date)
    if let clock { $0.continuousClock = clock }
  } operation: {
    guard log != nil || regions != nil else { return registerSessionExecution(try Space.inMemory(), clock: clock) }
    return registerSessionExecution(try Space.inMemory(
      configuration: Space.makeConfiguration(journalMode: .default), log: log ?? Logger(label: "wuhu.space"), regions: regions,
    ), clock: clock)
  }
}

@discardableResult
func registerSessionExecution(_ space: Space, clock: (any NonsendingClock<Duration>)? = nil) -> Space {
  withDependencies {
    if let clock {
      $0.continuousClock = clock
    } else {
      let date = $0.date
      $0.installTimeControl(anchor: date.now)
      $0.date = date
    }
  } operation: {
    _ = SessionExecution(
      connection: MainConnection(), credential: { _ in throw MainUnavailable() }, space: space,
      observerRun: { _, _, _ in try await sessionFixtureWait() },
      loopConfig: { _ in
        LoopConfig(
          executeTool: { _ in throw SessionFixtureUnexpectedWork() },
          inference: { _ in try await sessionFixtureWait() },
          budget: { _ in .init(maxInput: 1_001_000, maxOutput: 1000) },
        )
      },
    )
    return space
  }
}

private func sessionFixtureWait<Value>() async throws -> Value {
  let waiting = AsyncStream<Void> { _ in }
  for await _ in waiting {}
  throw CancellationError()
}

private struct SessionFixtureUnexpectedWork: Error {}

// Tests read as nobody in particular, in the shared group.
extension Space {
  func query(
    _ sql: String,
    arguments: [JSONValue] = [],
    byteLimit: Int? = nil,
    viewer: String? = nil,
  ) async throws -> Rows {
    try await query(sql, arguments: arguments, byteLimit: byteLimit, viewer: viewer, as: .shared(.anonymous))
  }

  nonisolated func observeRows(_ sql: String, throttle: Duration, viewer: String? = nil) throws -> AsyncThrowingStream<Rows, any Error> {
    try observeRows(sql, throttle: throttle, viewer: viewer, as: .shared(.anonymous))
  }

  func observeFS(glob: String, from: Rev? = nil, group: GroupID) async throws -> AsyncStream<FSCommit> {
    try await observeFS(glob: glob, from: from, group: group, as: .shared(.anonymous))
  }
}

func path(_ raw: String) throws -> SpacePath { try SpacePath(validating: raw) }

func bytes(_ text: String) -> Data { Data(text.utf8) }

func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

extension Space {
  func writeText(_ path: String, _ content: String, ifMatch: VersionToken? = nil) async throws -> VersionToken {
    try await fs(.shared).write(path, bytes(content), ifMatch: ifMatch)
  }

  func readText(_ path: String, at rev: Rev? = nil) async throws -> String {
    text(try await fs(.shared, at: rev).read(path).1)
  }
}

struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

actor Collector<Element: Sendable> {
  private(set) var items: [Element] = []
  func append(_ element: Element) { items.append(element) }
}

func awaitItems<Element>(
  _ collector: Collector<Element>,
  atLeast count: Int,
  timeout: Duration = .seconds(30),
) async throws -> [Element] {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  var items = await collector.items
  while items.count < count, clock.now < deadline {
    try? await clock.sleep(for: .milliseconds(1))
    items = await collector.items
  }
  try #require(items.count >= count, "expected at least \(count) emission(s) within \(timeout), got \(items.count)")
  return items
}

/// The first element `matching` waits to arrive, however many come before it; nil at the deadline.
func awaitItem<Element>(
  _ collector: Collector<Element>,
  timeout: Duration = .seconds(30),
  matching: @Sendable (Element) -> Bool,
) async -> Element? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if let found = await collector.items.first(where: matching) { return found }
    try? await clock.sleep(for: .milliseconds(1))
  }
  return nil
}

// Give background observation work (GRDB region callbacks run on a dispatch
// queue, then hop back onto the cooperative pool) real wall-clock time to reach
// a settled state before asserting on it. The space under test uses its own
// injected clock, independent of this real-time poll.
func settle(_ duration: Duration = .milliseconds(80)) async {
  try? await ContinuousClock().sleep(for: duration)
}

extension Space {
  /// Rows the program never wrote, as old data is: put there on a connection of their own, which the owner guard on the space's writer does not see.
  func plant(_ sql: String, arguments: StatementArguments = StatementArguments()) async throws {
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    try await DatabaseQueue(path: writer.path, configuration: configuration).write { try $0.execute(sql: sql, arguments: arguments) }
  }

  func registerPerson(_ id: String) async throws {
    if cell.persona(named: id) != nil { return }
    let account = try await addAccount(kind: .human, name: nil)
    let key = try await addKey(testPubkey(id), account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let allocation = cell.reservedPersona(account.id)!
    let now = fixedDate
    _ = try await worker.call(PersonCell.ID(account.id.rawValue)) { try $0.adoptPersona(key: key, allocation: allocation.id, name: id, at: now) }
  }

  func registerPeople(_ ids: [String]) async throws {
    for id in ids where id != "owner" {
      try await registerPerson(id)
      _ = try await setUserProfile(principal: id, handle: "person_" + id.replacingOccurrences(of: "-", with: "_"), displayName: nil)
    }
  }
}
