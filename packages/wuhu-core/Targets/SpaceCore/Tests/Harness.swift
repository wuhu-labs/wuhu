import Clocks
import Dependencies
import Foundation
import GRDB
import JSONValue
import Logging
@testable import SpaceCore
import SpaceFS
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

func makeSpace(date: Date = fixedDate, clock: (any Clock<Duration>)? = nil, log: Logger? = nil) throws -> Space {
  try withDependencies {
    $0.date = .constant(date)
    if let clock { $0.continuousClock = clock }
  } operation: {
    guard let log else { return try Space.inMemory() }
    return try Space.temporary(log: log)
  }
}

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

  func observeQuery(_ sql: String, throttle: Duration, viewer: String? = nil) -> AsyncThrowingStream<Rows, any Error> {
    observeQuery(sql, throttle: throttle, viewer: viewer, as: .shared(.anonymous))
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
  timeout: Duration = .seconds(5),
) async -> [Element] {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    let items = await collector.items
    if items.count >= count { return items }
    try? await clock.sleep(for: .milliseconds(1))
  }
  return await collector.items
}

// Give background observation work (GRDB region callbacks run on a dispatch
// queue, then hop back onto the cooperative pool) real wall-clock time to reach
// a settled state before asserting on it. The space under test uses its own
// injected clock, independent of this real-time poll.
func settle(_ duration: Duration = .milliseconds(80)) async {
  try? await ContinuousClock().sleep(for: duration)
}
