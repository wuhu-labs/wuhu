import Clocks
import ControlledTime
import Crypto
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Machines
import MachinesContract
import struct OperationProtocol.OperationClock
import SpaceCore
import Synchronization

public let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

public let anchor = Date(timeIntervalSinceReferenceDate: 0)

public func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

public struct SeededRNG: RandomNumberGenerator, Sendable {
  private var state: UInt64
  public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  public mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A space whose worker hosts the machine kinds, with the dependencies a worker-driven machine cell reads.
public func makeMachineSpace(seed: UInt64 = 7) throws -> Space {
  try withDependencies {
    $0.date = DateGenerator { Date() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: seed))
  } operation: {
    let space = try Space.inMemory().registeringMachines()
    _ = space.worker
    return space
  }
}

public func withKernelDeps<R>(
  seed: UInt64 = 7,
  _ body: (TimeControl) async throws -> R,
) async throws -> R {
  try await withDependencies {
    $0.installTimeControl(anchor: anchor)
    $0.uuid = .incrementing
    $0.withRandomNumberGenerator = .init(SeededRNG(seed: seed))
  } operation: {
    @Dependency(\.timeControl) var timeControl
    return try await body(timeControl)
  }
}

extension TimeControl {
  // The microsecond of slack absorbs Double<->Duration rounding: a scheduled sleep must fire when a test advances by
  // its nominal delay.
  public func advance(by seconds: Double) async {
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds + 1e-6))
  }
}

public struct TimeoutError: Error {}

public struct UnexpectedCall: Error {
  public var what: String
  public init(_ what: String) { self.what = what }
}

public final class Box<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>
  public init(_ value: Value) { mutex = .init(value) }
  public var value: Value { mutex.withLock { $0 } }
  public func withLock<R: Sendable>(_ body: (inout sending Value) -> sending R) -> R { mutex.withLock(body) }
}

public func holds(
  _ description: String, for window: Duration = .milliseconds(80),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: window)
  while clock.now < deadline {
    if !(try await condition()) { return }
    try? await clock.sleep(for: .milliseconds(2))
  }
}

public func settle(_ duration: Duration = .milliseconds(80)) async {
  try? await ContinuousClock().sleep(for: duration)
}

public func outboxEventually(_ description: String, _ condition: () async throws -> Bool) async throws {
  for _ in 0 ..< 10000 {
    if try await condition() { return }
    await Task.yield()
  }
  throw TimeoutError()
}

public func realPollUntil(attempts: Int = 500, _ condition: @Sendable () async throws -> Bool) async throws -> Bool {
  for _ in 0 ..< attempts {
    if try await condition() { return true }
    try? await ContinuousClock().sleep(for: .milliseconds(2))
  }
  return false
}

public struct MachineRecoveryTestClock: Sendable {
  private let time: VirtualClock
  public let clock: OperationClock

  public init() {
    let time = VirtualClock(); let origin = time.now
    self.time = time
    clock = .init(now: { origin.duration(to: time.now) }, sleep: { try await time.sleep(for: $0) })
  }

  public func advance(_ duration: Duration) async { await time.advance(by: duration) }
}

public func withLiveDate<R>(_ body: () async throws -> R) async throws -> R {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
  } operation: {
    try await body()
  }
}

public func bytes(_ text: String) -> Data { Data(text.utf8) }

public func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

public struct MachineTestTimeout: Error {}

public func until(
  _ description: String,
  timeout: Duration = .seconds(10),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if try await condition() { return }
    try? await clock.sleep(for: .milliseconds(2))
  }
  throw MachineTestTimeout()
}
