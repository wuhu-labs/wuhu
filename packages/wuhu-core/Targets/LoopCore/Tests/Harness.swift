import Clocks
import ControlledTime
import Dependencies
import Foundation
import JSONValue
import Logging
@testable import LoopCore
import MainHub
import SessionDomain
import SessionTools
import enum SpaceContract.ScriptOutput
@testable import SpaceCore
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

/// Polls `condition` in real time. Drive the injected clock once, outside the poll, never inside: a poll every 2 ms lapses it
/// far past the workers' 10 s leases while their scans keep up only in real time, and the other worker then claims the session.
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

/// Polls `condition` while moving the injected clock between polls, for an effect only a wake the clock owes can start (a queued
/// input's due time). `attempts` bounds the clock, so it stays inside the workers' 10 s leases; it is not a poll count to raise.
func untilAdvancing(
  _ description: String,
  _ time: TimeControl,
  step: Double = 1,
  attempts: Int = 8,
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  for _ in 0 ..< attempts {
    if try await condition() { return }
    await time.advance(by: step)
    try? await clock.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(description)")
  throw TimeoutError()
}

func holds(
  _ description: String, for window: Duration = .milliseconds(80),
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

// A session row only an old space carries: created on a model, then stamped with an executor this build no longer has.
func createRetiredSession(
  in space: Space,
  title: String,
  kind: SessionKind = .agent,
  parent: SessionID? = nil,
  createdBy: String,
  executorKind: String = "contractor:retired",
) async throws -> SessionID {
  let id = try await space.sessions.createSession(
    group: .shared, title: title, kind: kind, parent: parent, createdBy: createdBy, executor: .kernel(.test),
  )
  let retired = SessionExecutor.retired(kind: executorKind)
  try await space.writer.write { db in
    try db.execute(
      sql: "UPDATE sessions SET executor = ?, executor_config = ? WHERE id = ?",
      arguments: [retired.kind, retired.configJSON, id.rawValue],
    )
  }
  return id
}

// A task whose parent never runs, so its requests and finals wake nothing else.
func createRequestedTask(in space: Space, title: String = "t") async throws -> SessionID {
  let requester = try await createRetiredSession(in: space, title: "requester", createdBy: "morgan")
  return try await space.sessions.createSession(group: .shared, title: title, kind: .task, parent: requester, createdBy: "morgan", executor: .kernel(.test))
}

extension SessionStore {
  @discardableResult
  func openParentRequest(on task: SessionID, _ id: String = "r1") async throws -> MessageDelivery {
    try await openRequest(on: task, from: .session(try #require(try await record(task).parent)), messageID: .init(id), text: "do it")
  }

  func reportFinal(_ task: SessionID, _ request: String = "r1") async throws -> ToolResultPayload {
    let posted = try await report(task, request: .init(request), kind: .final, messageID: .init("final-\(request)"), text: "done").message
    return .report(.init(messageID: posted.id, requestID: .init(request), conversationID: posted.conversation, kind: .final))
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
  _ space: Space,
  _ config: LoopConfig,
  body: (SessionExecution) async throws -> Void,
) async throws {
  try await runService(SessionExecution(space: space, loopConfig: config), body: body)
}

func runService(
  _ service: SessionExecution,
  body: (SessionExecution) async throws -> Void,
) async throws {
  service.start()
  do {
    try await body(service)
  } catch {
    await service.shutdown()
    throw error
  }
  await service.shutdown()
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
    var at: Date
    var itemCount: Int
    var idleTimeout: Duration
    var ping: Bool
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
        at: date.now,
        itemCount: request.lines.count,
        idleTimeout: request.idleTimeout,
        ping: request.ping,
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

func makeConfig(
  executeTool: @escaping @Sendable (ToolCall) async throws -> ToolResultPayload = { call in
    throw UnexpectedCall("executeTool(\(call.name))")
  },
  inference: @escaping @Sendable (InferenceRequest) async throws -> InferenceReply = { _ in
    throw UnexpectedCall("inference")
  },
  budget: ContextBudget = .init(maxInput: 1_001_000, maxOutput: 1000),
) -> LoopConfig {
  LoopConfig(
    executeTool: { ToolOutcome(payload: try await executeTool($0.call)) },
    inference: inference,
    budget: { _ in budget },
  )
}

// MARK: - Fixtures

enum Fix {
  static let sender = Sender(id: "morgan", timeZone: TimeZone(identifier: "UTC")!)

  static func message(_ text: String, message: String = "m1", conversation: String = "ch1", owesReply: Bool = false, sender: Sender = Fix.sender) -> QueueInput {
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

  static func reply(_ text: String, calls: [ToolCall] = [], tokens: Int = 100, warming: WarmingSchedule? = nil) -> InferenceReply {
    .init(
      message: .init(content: [.text(text)] + calls.map { ContentBlock.toolCall($0) }),
      metadata: .init(
        stopReason: .stop,
        usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: tokens),
      ),
      warming: warming,
    )
  }

  static func replying(_ text: String, calls: [ToolCall] = [], tokens: Int = 100, warming: WarmingSchedule? = nil) -> InferenceScript.Step {
    let reply = reply(text, calls: calls, tokens: tokens, warming: warming)
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
  /// Nothing to do, and no mail on its way to the session's cell.
  func settledWork(_ id: SessionID) async throws -> Bool {
    try await writer.read { db in
      try Sessions.record(id.rawValue, in: db).work == .noWork
        && Bool.fetchOne(db, sql: "SELECT NOT EXISTS (SELECT 1 FROM wuwei_mail WHERE recipient = ?)", arguments: ["\(SessionMail.kind)/\(id.rawValue)"])!
    }
  }
}

extension SessionStore {
  func lines(_ id: SessionID) async throws -> [TranscriptLine] {
    try await transcriptLines(id).map { try $0.line() }
  }
}

extension [TranscriptLine] {
  var assistantLines: [TranscriptLine] { filter { $0.role == .assistant } }
  var owedReplyReminders: [TranscriptLine] { filter { $0.key == "subscription:owed.reply" } }
}

extension ModelSpecifier {
  static let test = ModelSpecifier(provider: "deepseek", model: "deepseek-v4-pro", effort: "high")
}

// Sessions with no line to main: the tools are not under test here.
extension SessionExecution {
  init(space: Space, loopConfig: LoopConfig) {
    self.init(connection: MainConnection(), credential: { _ in throw MainUnavailable() }, space: space, loopConfig: { _ in loopConfig })
  }

  func enqueue(item: QueueInput, to session: SessionID) async throws {
    try await store.enqueue(session, input: item)
  }
}

// A tool's arm and cancel, as the gate makes them once main has checked the call.
extension Space {
  @discardableResult
  func arm(_ session: SessionID, _ slot: SubscriptionSlot, nextFireAt: Date? = nil, answering call: String) async throws -> ToolResultPayload {
    try await worker.call(SessionCell.ID(session.rawValue)) { try $0.arm(Arming(slot, nextFireAt: nextFireAt), answering: ToolCallID(call)) }
  }

  @discardableResult
  func disarm(_ session: SessionID, _ subscription: SubscriptionID, answering call: String) async throws -> ToolResultPayload? {
    try await worker.call(SessionCell.ID(session.rawValue)) { try $0.disarm(subscription, answering: ToolCallID(call)) }
  }
}

extension TranscriptLine {
  var text: String {
    let content = switch message {
    case let .user(value): value.content
    case let .assistant(value): value.content
    case let .toolResult(value): value.content
    }
    return content.compactMap { block in
      if case let .text(text) = block { text.text } else { nil }
    }.joined(separator: "\n")
  }
}
