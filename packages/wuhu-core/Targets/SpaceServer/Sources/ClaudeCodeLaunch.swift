#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import struct InferenceKit.ModelsDocument
import JSONValue
import Logging
import SessionDomain
import Synchronization

// The loopback credential of one activation: 32 random bytes, held only here
// and in that activation's own settings and MCP config files, revoked when
// its process ends. The server both mints and checks it, so a lookup is all
// the proof there is; nothing about it is ever stored.
//
// A tool call lives no longer than the process that made it: the server never
// learns that a killed Claude Code stopped waiting for the answer, so `end`
// cuts off every call still running.
final class ClaudeCodeTokens: Sendable {
  struct Holder: Hashable, Sendable {
    var session: SessionID
    var activation: UUID
  }

  private struct Call {
    var cut: AsyncStream<Void>.Continuation
    var done: AsyncStream<Void>
  }

  private struct Held {
    var token: [UInt8]
    var holder: Holder
    var calls: [Int: Call] = [:]
    var nextCall = 0
  }

  private let held = Mutex<[UUID: Held]>([:])

  func mint(_ holder: Holder) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    let token = "cct_" + bytes.map { String($0, radix: 16).leftPadded(to: 2) }.joined()
    held.withLock { $0[holder.activation] = Held(token: Array(token.utf8), holder: holder) }
    return token
  }

  // Revokes the token, then cuts off the calls it let in and waits until each
  // has wound down, or `windDown` has passed: some calls (report, request, a
  // session-to-session message) wait out a peer's queue and take no
  // cancellation, and two sessions interrupted together can each be waiting
  // on the other.
  func end(_ activation: UUID, windDown: Duration = .seconds(10)) async {
    @Dependency(\.continuousClock) var clock
    let calls = held.withLock { $0.removeValue(forKey: activation).map { Array($0.calls.values) } ?? [] }
    for call in calls {
      call.cut.finish()
    }
    let wound = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      group.addTask {
        for call in calls {
          for await _ in call.done {}
        }
        return true
      }
      group.addTask { [clock] in
        _ = try? await clock.sleep(for: windDown)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !wound {
      Logger(label: "wuhu.claude-code").error(
        "tool calls outlived their Claude Code process",
        metadata: ["activation": "\(activation)", "after": "\(windDown)"],
      )
    }
  }

  // Runs one tool call of `activation` while it lasts. A call its end cuts off
  // is cancelled, and `cutOff` then stops what outlives the cancellation.
  func run<T: Sendable>(
    _ activation: UUID,
    _ call: @escaping @Sendable () async throws -> T,
    cutOff: () async -> Void,
  ) async throws -> T {
    let (cut, cutSink) = AsyncStream<Void>.makeStream()
    let (done, doneSink) = AsyncStream<Void>.makeStream()
    defer { doneSink.finish() }
    let key = held.withLock { held -> Int? in
      guard var entry = held[activation] else { return nil }
      let key = entry.nextCall
      entry.nextCall += 1
      entry.calls[key] = Call(cut: cutSink, done: done)
      held[activation] = entry
      return key
    }
    guard let key else { throw CancellationError() }
    defer { _ = held.withLock { $0[activation]?.calls.removeValue(forKey: key) } }
    let outcome = await withTaskGroup(of: Result<T, any Error>?.self, returning: Result<T, any Error>?.self) { group in
      group.addTask {
        do { return .success(try await call()) } catch { return .failure(error) }
      }
      group.addTask {
        for await _ in cut {}
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if let first { return first }
      return await group.next() ?? nil
    }
    // A call that finished despite the cut keeps its result.
    switch outcome {
    case let .success(value)?:
      return value
    case let .failure(error)? where !(error is CancellationError):
      throw error
    case .failure?, nil:
      if held.withLock({ $0[activation] == nil }) { await cutOff() }
      throw CancellationError()
    }
  }

  // Every held token is compared in full, so the time taken says nothing about
  // how much of a guess matched.
  func holder(ofBearer bearer: String) -> Holder? {
    let presented = Array(bearer.utf8)
    return held.withLock { held in
      var found: Holder?
      for entry in held.values where constantTimeEqual(entry.token, presented) {
        found = entry.holder
      }
      return found
    }
  }
}

private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
  guard lhs.count == rhs.count else { return false }
  var difference: UInt8 = 0
  for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
  return difference == 0
}

extension String {
  fileprivate func leftPadded(to width: Int) -> String {
    String(repeating: "0", count: max(0, width - count)) + self
  }
}

struct ClaudeCodeLaunchPlan: Equatable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var workingFolder: String
  var configDirectory: String
  var files: [String: String]
}

// Everything about how one activation starts, as data. `root` is the fresh
// folder: Claude Code works in `root/work`, keeps its config and log under
// `root/config`, and reads its settings and MCP config from `root` itself,
// out of the working folder's reach.
struct ClaudeCodeLaunchSpec {
  var root: String
  var binary: String
  var loopback: String
  var token: String
  var session: SessionID
  var claudeSessionID: String
  var resume: Bool
  var model: String
  var effort: String
  var autocompact: Int?
  var systemPrompt: String
  var oauthToken: String
  var inherited: [String: String]

  static let tools = ["Read", "Write", "Edit", "WebSearch"]
  static let inheritedKeys = ["HOME", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"]
  // Milliseconds, Claude Code's own ceiling (about 24.8 days). Without it,
  // Claude Code cuts a call to an HTTP server that has not answered in 60 s
  // or has sent no progress in 5 min. exec's and run_script's timeout_seconds
  // go up to 1e9 s, past anything Claude Code takes, so the ceiling is as
  // close as it comes to leaving each tool's own timeout in charge.
  static let mcpToolTimeout = Int(Int32.max)

  var plan: ClaudeCodeLaunchPlan {
    let work = root + "/work"
    let config = root + "/config"
    let settings = root + "/settings.json"
    let mcp = root + "/mcp.json"
    let bearer = "Bearer \(token)"
    let hook: JSONValue = [[
      "hooks": [[
        "type": "http",
        "url": .string("\(loopback)/v1/session/\(session.rawValue)/claude-code/hook"),
        "headers": ["Authorization": .string(bearer)],
        "timeout": 30,
      ]],
    ]]
    // Permission rules take `//` for an absolute path.
    let settingsJSON: JSONValue = [
      "hooks": ["PostToolUse": hook, "PostToolUseFailure": hook, "Stop": hook],
      "permissions": [
        "allow": .array((
          ["mcp__wuhu", "WebSearch", "Read(/\(config)/projects/**)"]
            + ["Read", "Write", "Edit"].map { "\($0)(/\(work)/**)" }
        ).map(JSONValue.string)),
      ],
    ]
    let mcpJSON: JSONValue = ["mcpServers": ["wuhu": [
      "type": "http",
      "url": .string("\(loopback)/v1/session/\(session.rawValue)/mcp"),
      "headers": ["Authorization": .string(bearer)],
      "timeout": .integer(Self.mcpToolTimeout),
    ]]]
    var environment = inherited.filter { Self.inheritedKeys.contains($0.key) }
    environment["CLAUDE_CONFIG_DIR"] = config
    environment["CLAUDE_CODE_OAUTH_TOKEN"] = oauthToken
    environment["DISABLE_AUTOUPDATER"] = "1"
    // Claude Code counts a turn silent when it prints no assistant text, but a
    // session answers people through send_message, so its "the user hasn't
    // heard from you" reminder fires on sessions that did answer.
    environment["CLAUDE_CODE_SILENT_TURN_REMINDER"] = "0"
    // Claude Code truncates an MCP result past 25,000 tokens by default, below
    // what one wuhu tool result may carry.
    environment["MAX_MCP_OUTPUT_TOKENS"] = "100000"
    return ClaudeCodeLaunchPlan(
      executable: binary,
      arguments: [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--session-mirror", "--include-hook-events", "--include-partial-messages",
        "--model", model, "--effort", effort,
      ] + (autocompact.map { ["--autocompact", String($0)] } ?? []) + [
        "--tools", Self.tools.joined(separator: ","), "--permission-mode", "dontAsk",
        "--setting-sources", "", "--settings", settings,
        "--strict-mcp-config", "--mcp-config", mcp,
        "--system-prompt", systemPrompt,
        resume ? "--resume" : "--session-id", claudeSessionID,
      ],
      environment: environment,
      workingFolder: work,
      configDirectory: config,
      files: [settings: settingsJSON.jsonString(pretty: true), mcp: mcpJSON.jsonString(pretty: true)],
    )
  }
}

extension ModelsDocument.Model {
  // Claude Code refuses to start with a window outside 100k to 1M tokens.
  func claudeCodeAutocompact(_ specifier: ModelSpecifier) throws -> Int? {
    guard let window = autocompactWindow else { return nil }
    guard (100_000 ... 1_000_000).contains(window) else {
      throw ClaudeCodeLaunchError(
        "autocompactWindow of \(specifier.provider)/\(specifier.model) in \(ModelsDocument.spacePath) is \(window); Claude Code takes 100000 to 1000000",
      )
    }
    return window
  }
}
