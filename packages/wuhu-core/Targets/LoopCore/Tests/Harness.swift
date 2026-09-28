import Clocks
import ControlledTime
import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

let anchor = Date(timeIntervalSinceReferenceDate: 0)

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

final class Box<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>
  init(_ value: Value) { mutex = .init(value) }
  var value: Value { mutex.withLock { $0 } }
  func withLock<R: Sendable>(_ body: (inout sending Value) -> sending R) -> R { mutex.withLock(body) }
}

struct TimeoutError: Error {}
struct UnexpectedCall: Error {
  var what: String
  init(_ what: String) { self.what = what }
}

func until(
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
  Issue.record("timed out waiting for \(description)")
  throw TimeoutError()
}

func holds(
  _ description: String,
  for window: Duration = .milliseconds(80),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: window)
  while clock.now < deadline {
    if !(try await condition()) {
      Issue.record("expected \(description) to hold, but it broke")
      return
    }
    try? await clock.sleep(for: .milliseconds(2))
  }
}

func withKernelDeps<R>(
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

func runService(
  _ sessions: SessionStore,
  _ config: LoopConfig,
  body: (SessionService) async throws -> Void,
) async throws {
  try await runService(await SessionService(sessions: sessions, loopConfig: config), body: body)
}

func runService(
  _ service: SessionService,
  body: (SessionService) async throws -> Void,
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await service.start() }
    var bodyError: (any Error)?
    do {
      try await body(service)
    } catch {
      bodyError = error
    }
    group.cancelAll()
    try await group.waitForAll()
    if let bodyError { throw bodyError }
  }
}

extension TimeControl {
  // The microsecond of slack absorbs Double<->Duration rounding: a scheduled
  // sleep must fire when we advance by its nominal delay.
  func advance(by seconds: Double) async {
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds + 1e-6))
  }
}

// The kernel's jitter stream: createSession's allocation draws the 32
// freeze-secret candidate bytes from the injected generator first.
func mirrorAllocationDraws(_ rng: inout any RandomNumberGenerator) {
  for _ in 0 ..< 32 { _ = UInt8.random(in: .min ... .max, using: &rng) }
}

// MARK: - Scripts

final class InferenceScript: Sendable {
  typealias Step = @Sendable (InferenceRequest) async throws -> InferenceReply

  struct Attempt: Sendable {
    var id: UUID
    var mode: InferenceMode
    var at: Date
    var itemCount: Int
    var idleTimeout: Duration
  }

  private let steps: Box<[Step]>
  let attempts = Box<[Attempt]>([])

  init(_ steps: [Step]) {
    self.steps = Box(steps)
  }

  func callAsFunction(_ request: InferenceRequest) async throws -> InferenceReply {
    @Dependency(\.date) var date
    attempts.withLock {
      $0.append(Attempt(
        id: request.attemptID,
        mode: request.mode,
        at: date.now,
        itemCount: request.transcript.items.count,
        idleTimeout: request.idleTimeout,
      ))
    }
    let step = steps.withLock { steps -> Step? in
      steps.isEmpty ? nil : steps.removeFirst()
    }
    guard let step else { throw UnexpectedCall("inference beyond the script") }
    return try await step(request)
  }

  var count: Int { attempts.value.count }
}

final class ExecScript: Sendable {
  let calls = Box<[ToolCall]>([])
  private let handler: @Sendable (ToolCall) async throws -> ToolResultPayload

  init(_ handler: @escaping @Sendable (ToolCall) async throws -> ToolResultPayload) {
    self.handler = handler
  }

  func callAsFunction(_ call: ToolCall) async throws -> ToolResultPayload {
    calls.withLock { $0.append(call) }
    return try await handler(call)
  }
}

final class CompactScript: Sendable {
  let count = Box<Int>(0)
  private let result: CompactionResult

  init(_ result: CompactionResult) {
    self.result = result
  }

  func callAsFunction(_ transcript: Transcript) async throws -> CompactionResult {
    count.withLock { $0 += 1 }
    return result
  }
}

func makeConfig(
  executeTool: @escaping @Sendable (ToolCall) async throws -> ToolResultPayload = { call in
    throw UnexpectedCall("executeTool(\(call.name))")
  },
  inference: @escaping @Sendable (InferenceRequest) async throws -> InferenceReply = { _ in
    throw UnexpectedCall("inference")
  },
  compact: @escaping @Sendable (Transcript) async throws -> CompactionResult = { _ in
    throw UnexpectedCall("compact")
  },
  budget: ContextBudget = .init(maxInput: 1_001_000, maxOutput: 1000),
  eviction: EvictionPolicy = .init(),
) -> LoopConfig {
  LoopConfig(
    executeTool: { try await executeTool($0.call) },
    inference: inference,
    compact: { _, transcript in try await compact(transcript) },
    budget: { _ in budget },
    eviction: eviction,
  )
}

// MARK: - Fixtures

enum Fix {
  static let sender = Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!)

  static func message(_ text: String, message: String = "m1", conversation: String = "ch1", owesReply: Bool = false) -> QueueInput {
    .message(.init(
      id: UUID(),
      messageID: .init(message),
      conversationID: .init(conversation),
      sender: sender,
      timestamp: anchor,
      owesReply: owesReply,
      content: .init(text: text),
    ))
  }

  static func reply(_ text: String, calls: [ToolCall] = [], tokens: Int = 100) -> InferenceReply {
    .init(
      message: .init(content: [.text(text)] + calls.map { ContentBlock.toolCall($0) }),
      metadata: .init(
        stopReason: .stop,
        usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: tokens),
      ),
    )
  }

  static func replying(_ text: String, calls: [ToolCall] = [], tokens: Int = 100) -> InferenceScript.Step {
    let reply = reply(text, calls: calls, tokens: tokens)
    return { _ in reply }
  }

  static func failing(_ error: InferenceError) -> InferenceScript.Step {
    { _ in throw error }
  }

  static func throwing(_ error: any Error) -> InferenceScript.Step {
    { _ in throw error }
  }

  static var hanging: InferenceScript.Step {
    { _ in
      @Dependency(\.continuousClock) var clock
      try await clock.sleep(for: .seconds(1_000_000))
      throw UnexpectedCall("hanging inference elapsed")
    }
  }
}

extension SessionStore {
  func settledWork(_ id: SessionID) async throws -> Bool {
    try await record(id).work == .noWork
  }
}

extension Transcript {
  var assistantEntries: [AssistantEntry] {
    items.compactMap { item in
      guard case let .assistant(entry) = item else { return nil }
      return entry
    }
  }

  var owedReplyReminders: [SystemNotification] {
    items.compactMap { item in
      guard case let .notification(notification) = item, notification.kind == .owedReply
      else { return nil }
      return notification
    }
  }
}

extension ModelSpecifier {
  static let test = ModelSpecifier(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")
}
