import ClaudeStream
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Testing

// Captured with a dev Mac's ~/wuhu-probe/loop5/probe-fixture.py (run5): Claude Code
// 2.1.272 against a scripted endpoint. Turn 1 makes two tool calls, the
// second after a 2.5 s model call; turn 2 answers in text after 2.5 s. The
// capture's hook server handed text over at the second after-each-tool hook
// and at turn 2's first end-of-turn hook. Each turn's stdin message carried
// the uuid listed in `capturedStdinUUIDs`.
enum ClaudeCodeCapture {
  static let capturedStdinUUIDs = ["b3f8df45-a874-47f0-8e36-43c399f301af", "30864ce0-71a1-4e95-99a5-589680289ad8"]

  private static let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/claude-code")

  static func lines(_ name: String) -> [String] {
    let data = try! Data(contentsOf: folder.appendingPathComponent(name))
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
  }

  // Standard output cut after each result frame.
  static let turns: [[String]] = {
    var turns: [[String]] = [[]]
    for line in lines("stdout.jsonl") {
      turns[turns.count - 1].append(line)
      if JSONValue.parse(line)?.object?["type"] == "result" { turns.append([]) }
    }
    if turns.last!.isEmpty { turns.removeLast() }
    return turns
  }()

  static let hooks: [JSONValue] = lines("hooks.jsonl").map { JSONValue.parse($0)! }

  // Where each turn's recorded hook requests start, so a replayed turn posts its own.
  static let firstHook: [Int] = turns.reduce(into: [0]) { offsets, turn in
    offsets.append(offsets.last! + turn.count { $0.contains(#""subtype":"hook_started""#) })
  }
}

enum FrameCue: Sendable {
  case proceed
  case exit(String)
}

// A Claude Code process replaying the capture: the k-th write releases turn
// k, with the capture's stdin uuid swapped for the one written (Claude Code
// logs the input uuid as given), and every hook_started frame posts the next
// recorded hook request to the session before replay goes on.
final class FakeClaudeCode: Sendable {
  let launches = Box<[ClaudeCodeLaunch]>([])
  let writes = Box<[JSONValue]>([])
  let hookReplies = Box<[JSONValue]>([])
  let service = Box<SessionService?>(nil)
  private let nextTurn = Box(0)
  private let turnsPerLaunch: [[Int]]?
  // Called before each replayed line; may pause (until the process is
  // killed, at the latest) or end the process.
  private let cue: @Sendable (Cue) async -> FrameCue
  private let rewrite: @Sendable (Int, String) -> String
  private let hookBody: @Sendable (Int, JSONValue) -> JSONValue
  // Lines held back until just before the turn's result, as a fast turn
  // flushes its whole log after the end-of-turn hook.
  private let deferred: @Sendable (Int, String) -> Bool
  // Or just after it, when the flush lands after the result.
  private let pastResult: Bool
  // The lines a written command answers with, replayed in place of a
  // captured turn; its cues carry turn -1.
  private let command: @Sendable (JSONValue) -> [String]?

  struct Cue: Sendable {
    var launch: Int
    var turn: Int
    var line: String
    var killed: @Sendable () -> Bool
  }

  init(
    turnsPerLaunch: [[Int]]? = nil,
    cue: @escaping @Sendable (Cue) async -> FrameCue = { _ in .proceed },
    rewrite: @escaping @Sendable (Int, String) -> String = { $1 },
    hookBody: @escaping @Sendable (Int, JSONValue) -> JSONValue = { $1 },
    deferred: @escaping @Sendable (Int, String) -> Bool = { _, _ in false },
    pastResult: Bool = false,
    command: @escaping @Sendable (JSONValue) -> [String]? = { _ in nil },
  ) {
    self.pastResult = pastResult
    self.command = command
    self.turnsPerLaunch = turnsPerLaunch
    self.cue = cue
    self.rewrite = rewrite
    self.hookBody = hookBody
    self.deferred = deferred
  }

  var seam: ClaudeCodeSeam {
    ClaudeCodeSeam(
      spawn: { launch in self.spawn(launch) },
      render: { _, inputs, channel in
        inputs.map { ClaudeCodeBlock.text("[\(channel)] " + $0.rendered(handles: [:], devices: [:])) }
      },
    )
  }

  var writtenTexts: [[String]] {
    writes.value.map { line in
      line.object?["message"]?.object?["content"]?.array?.compactMap { $0.object?["text"]?.stringValue } ?? []
    }
  }

  private func spawn(_ launch: ClaudeCodeLaunch) -> ClaudeCodeProcess {
    let index = launches.withLock { launches in
      launches.append(launch)
      return launches.count - 1
    }
    let (frames, frameSink) = AsyncStream<ClaudeStreamFrame>.makeStream()
    let (written, writeSink) = AsyncStream<JSONValue>.makeStream()
    let killed = Box(false)
    return ClaudeCodeProcess(
      run: {
        defer { frameSink.finish() }
        var reader = ClaudeStreamReader()
        var turnInLaunch = 0
        for await line in written {
          if let lines = self.command(line) {
            for raw in lines {
              if killed.value { return "signal 9" }
              if case let .exit(how) = await self.cue(Cue(launch: index, turn: -1, line: raw, killed: { killed.value })) {
                return how
              }
              for frame in reader.read(Array((raw + "\n").utf8)) { frameSink.yield(frame) }
            }
            continue
          }
          let turn = self.turnsPerLaunch.map { $0[index][turnInLaunch] } ?? self.nextTurn.withLock { turn in
            defer { turn += 1 }
            return turn
          }
          turnInLaunch += 1
          let uuid = line.object?["uuid"]?.stringValue ?? ""
          let captured = ClaudeCodeCapture.turns[turn]
          let held = captured.filter { self.deferred(turn, $0) }
          let resultAt = captured.firstIndex { JSONValue.parse($0)?.object?["type"] == "result" } ?? captured.count
          let before = captured[..<resultAt].filter { !self.deferred(turn, $0) }
          let result = Array(captured[resultAt ..< min(resultAt + 1, captured.count)])
          let after = Array(captured[min(resultAt + 1, captured.count)...])
          let ordered = self.pastResult ? before + result + held + after : before + held + result + after
          var hooksInTurn = 0
          for raw in ordered {
            if killed.value { return "signal 9" }
            if case let .exit(how) = await self.cue(Cue(launch: index, turn: turn, line: raw, killed: { killed.value })) {
              return how
            }
            if killed.value { return "signal 9" }
            let replayed = self.rewrite(turn, raw).replacingOccurrences(of: ClaudeCodeCapture.capturedStdinUUIDs[turn], with: uuid)
            for frame in reader.read(Array((replayed + "\n").utf8)) { frameSink.yield(frame) }
            if let fields = JSONValue.parse(raw)?.object, fields["subtype"] == "hook_started" {
              let body = self.hookBody(turn, ClaudeCodeCapture.hooks[ClaudeCodeCapture.firstHook[turn] + hooksInTurn])
              hooksInTurn += 1
              let reply = await self.service.value!.claudeCodeHook(launch.session, activation: launch.activation, body: body)
              self.hookReplies.withLock { $0.append(reply) }
            }
          }
        }
        return killed.value ? "signal 9" : "exit status 0"
      },
      frames: frames,
      write: { bytes in
        let line = JSONValue.parse(utf8: bytes.dropLast())!
        self.writes.withLock { $0.append(line) }
        writeSink.yield(line)
      },
      kill: {
        killed.withLock { $0 = true }
        writeSink.finish()
      },
    )
  }
}

// Resumed by the test when a cue waits on it.
final class Latch: Sendable {
  private let open = Box(false)

  func release() { open.withLock { $0 = true } }

  func wait(unless killed: @Sendable () -> Bool = { false }) async {
    while !open.value, !killed() {
      try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
  }
}

extension ModelSpecifier {
  static let claude = ModelSpecifier(provider: "claude", model: "claude-sonnet-5", effort: "high")
}

func makeClaudeCodeConfig(_ fake: FakeClaudeCode, eviction: EvictionPolicy = .init()) -> LoopConfig {
  LoopConfig(
    executeTool: { throw UnexpectedCall("executeTool(\($0.call.name))") },
    inference: { _ in throw UnexpectedCall("kernel inference for a Claude Code session") },
    compact: { _, _ in throw UnexpectedCall("compact") },
    budget: { _ in .init(maxInput: 1_001_000, maxOutput: 1000) },
    claudeCode: fake.seam,
    eviction: eviction,
  )
}

extension SessionService {
  // The store records a handover's flush before the session actor clears the
  // handover, and a hook in between hands over nothing: wait for both.
  func flushRecorded(_ sessions: SessionStore, _ sid: SessionID) async throws -> Bool {
    guard try await sessions.undrainedInputs(sid).isEmpty else { return false }
    guard let actor = await registry.sessions[sid] else { return true }
    return await actor.handoverSettled
  }
}

extension SessionActor {
  var handoverSettled: Bool {
    guard case let .claudeCode(claude)? = liveState?.engine else { return true }
    return claude.handover == nil
  }
}

extension SessionStore {
  func claudeCodeSession(kind: SessionKind = .agent) async throws -> SessionID {
    try await createSession(group: .shared, title: "c", kind: kind, createdBy: "morgan", executor: .claudeCode(.claude), snapshot: .init())
  }

  // A cron timer, a one-shot timer, an observation, and a request deadline
  // the listing leaves out.
  func armSubscriptions(_ sid: SessionID) async throws {
    let later = Date(timeIntervalSince1970: 1_790_000_000)
    try await armSubscription(sid, slot: .init(id: .init("timer.toolu_cron"), kind: .timer(.cron("*/40 * * * *"), message: "tick\nand tock")), nextFireAt: later)
    try await armSubscription(sid, slot: .init(id: .init("timer.toolu_once"), kind: .timer(.oneShot(later), message: "once")), nextFireAt: later)
    try await armSubscription(sid, slot: .init(id: .init("obs.toolu_obs"), kind: .observe(sql: "SELECT id FROM sessions", throttleSeconds: 30)))
    try await armSubscription(sid, slot: .init(id: .deadline(RequestID("r1")), kind: .requestDeadline(request: RequestID("r1"), task: sid)), nextFireAt: later)
  }

  func cancelSubscriptions(_ sid: SessionID) async throws {
    for id in ["timer.toolu_cron", "timer.toolu_once", "obs.toolu_obs"] {
      try await cancelSubscription(sid, subscriptionID: .init(id))
    }
  }
}

let armedSubscriptionsListing = """
Your active timers and observations; cancel_timer and cancel_observation take these ids:
- obs.toolu_obs: observation, "SELECT id FROM sessions"
- timer.toolu_cron: timer, cron */40 * * * *, message "tick and tock"
- timer.toolu_once: timer, fires 2026-09-21T14:13:20Z, message "once"
"""

extension JSONValue {
  var additionalContext: String? {
    object?["hookSpecificOutput"]?.object?["additionalContext"]?.stringValue
  }
}
