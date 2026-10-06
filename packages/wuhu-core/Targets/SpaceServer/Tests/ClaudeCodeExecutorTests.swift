import enum ClaudeStream.ClaudeCodeBlock
import Clocks
import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import struct InferenceKit.ModelsDocument
import JSONValue
import LoopCore
import Scratch
import Serve
import ServeTesting
import SessionDomain
import class SessionTools.Scripts
import enum SpaceContract.ImageMedia
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite struct ClaudeCodeExecutorTests {
  private static let spec = ClaudeCodeLaunchSpec(
    root: "/tmp/a",
    binary: "/home/dev/.wuhu/vendors/claude/2.1.280/claude",
    loopback: "http://127.0.0.1:4100",
    token: "cct_t",
    session: SessionID("oak-pine-elm"),
    claudeSessionID: "0b5f6a1e-7a39-4b1e-9d0e-5a2c8f7d3e11",
    resume: true,
    model: "claude-sonnet-5",
    effort: "high",
    systemPrompt: "PROMPT",
    oauthToken: "sk-ant-oat",
    inherited: ["HOME": "/home/dev", "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "leak", "SECRET": "leak"],
  )

  @Test func theLaunchIsTheRecordedCommand() throws {
    let plan = Self.spec.plan
    #expect(plan.executable == "/home/dev/.wuhu/vendors/claude/2.1.280/claude")
    #expect(plan.arguments == [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
      "--session-mirror", "--include-hook-events", "--include-partial-messages",
      "--model", "claude-sonnet-5", "--effort", "high",
      "--tools", "Read,Write,Edit,WebSearch", "--permission-mode", "dontAsk",
      "--setting-sources", "", "--settings", "/tmp/a/settings.json",
      "--strict-mcp-config", "--mcp-config", "/tmp/a/mcp.json",
      "--system-prompt", "PROMPT",
      "--resume", "0b5f6a1e-7a39-4b1e-9d0e-5a2c8f7d3e11",
    ])
    #expect(plan.environment == [
      "HOME": "/home/dev", "PATH": "/usr/bin",
      "CLAUDE_CONFIG_DIR": "/tmp/a/config", "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat", "DISABLE_AUTOUPDATER": "1",
      "CLAUDE_CODE_SILENT_TURN_REMINDER": "0", "MAX_MCP_OUTPUT_TOKENS": "100000",
    ])
    #expect(plan.workingFolder == "/tmp/a/work")
    #expect(plan.configDirectory == "/tmp/a/config")

    let hook: JSONValue = [[
      "hooks": [[
        "type": "http",
        "url": "http://127.0.0.1:4100/v1/session/oak-pine-elm/claude-code/hook",
        "headers": ["Authorization": "Bearer cct_t"],
        "timeout": 30,
      ]],
    ]]
    #expect(JSONValue.parse(try #require(plan.files["/tmp/a/settings.json"])) == [
      "hooks": ["PostToolUse": hook, "PostToolUseFailure": hook, "Stop": hook],
      "permissions": [
        "allow": [
          "mcp__wuhu", "WebSearch", "Read(//tmp/a/config/projects/**)",
          "Read(//tmp/a/work/**)", "Write(//tmp/a/work/**)", "Edit(//tmp/a/work/**)",
        ],
      ],
    ])
    #expect(JSONValue.parse(try #require(plan.files["/tmp/a/mcp.json"])) == ["mcpServers": ["wuhu": [
      "type": "http",
      "url": "http://127.0.0.1:4100/v1/session/oak-pine-elm/mcp",
      "headers": ["Authorization": "Bearer cct_t"],
      "timeout": 2_147_483_647,
    ]]])
  }

  @Test func aRelayActivationAuthenticatesWithItsOwnBaseURLAndKey() {
    var spec = Self.spec
    spec.oauthToken = nil
    spec.gateway = .init(baseURL: URL(string: "https://www.jiji.cc")!, key: "sk-relay")
    let environment = spec.plan.environment
    #expect(environment["ANTHROPIC_BASE_URL"] == "https://www.jiji.cc")
    #expect(environment["ANTHROPIC_AUTH_TOKEN"] == "sk-relay")
    #expect(environment["ANTHROPIC_API_KEY"] == "", "empty, so a saved login cannot take over")
    #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
    #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
  }

  @Test func aFirstActivationNamesItsSessionInsteadOfResuming() {
    var spec = Self.spec
    spec.resume = false
    #expect(spec.plan.arguments.suffix(2) == ["--session-id", "0b5f6a1e-7a39-4b1e-9d0e-5a2c8f7d3e11"])
  }

  @Test func theModelsAutocompactWindowIsClaudeCodesOwn() throws {
    #expect(!Self.spec.plan.arguments.contains("--autocompact"), "without one, Claude Code's default applies")
    var spec = Self.spec
    spec.autocompact = 233_000
    let arguments = spec.plan.arguments
    let flag = try #require(arguments.firstIndex(of: "--autocompact"))
    #expect(arguments[flag + 1] == "233000")
  }

  @Test func anAutocompactWindowClaudeCodeWouldRefuseFailsTheLaunch() throws {
    let specifier = ModelSpecifier(provider: "claude", model: "opus", effort: "high")
    func window(_ tokens: Int?) throws -> Int? {
      try ModelsDocument.Model(
        maxInput: 1_000_000, maxOutput: 32000, efforts: ["high"], defaultEffort: "high", autocompactWindow: tokens,
      ).claudeCodeAutocompact(specifier)
    }
    #expect(try window(nil) == nil)
    #expect(try window(100_000) == 100_000)
    #expect(try window(1_000_000) == 1_000_000)
    #expect(throws: ClaudeCodeLaunchError.self) { try window(99999) }
    #expect(throws: ClaudeCodeLaunchError.self) { try window(1_000_001) }
  }

  @Test func aTokenIsOpaqueAndLivesExactlyAsLongAsItsActivation() async {
    let tokens = ClaudeCodeTokens()
    let one = ClaudeCodeTokens.Holder(session: SessionID("a"), activation: UUID())
    let two = ClaudeCodeTokens.Holder(session: SessionID("b"), activation: UUID())
    let first = tokens.mint(one)
    let second = tokens.mint(two)
    #expect(first.hasPrefix("cct_") && first.count == 4 + 64)
    #expect(first != second)
    #expect(tokens.holder(ofBearer: first) == one)
    #expect(tokens.holder(ofBearer: second) == two)
    let forged = String(first.dropLast()) + (first.hasSuffix("0") ? "1" : "0")
    #expect(tokens.holder(ofBearer: forged) == nil)
    #expect(tokens.holder(ofBearer: "") == nil)
    await tokens.end(one.activation)
    #expect(tokens.holder(ofBearer: first) == nil)
    #expect(tokens.holder(ofBearer: second) == two)
  }

  @Test func anActivationsEndCutsOffTheCallsItLetIn() async throws {
    try await withSessionDeps {
      let tokens = ClaudeCodeTokens()
      let holder = ClaudeCodeTokens.Holder(session: SessionID("a"), activation: UUID())
      _ = tokens.mint(holder)
      let answered = try await tokens.run(holder.activation, { 7 }) { Issue.record("an answered call is not cut off") }
      #expect(answered == 7)

      let (started, start) = AsyncStream<Void>.makeStream()
      let cutOff = Mutex(false)
      async let parked: Void = tokens.run(holder.activation, {
        start.yield()
        try await ContinuousClock().sleep(for: .seconds(3600))
      }) { cutOff.withLock { $0 = true } }
      for await _ in started { break }
      await tokens.end(holder.activation)
      #expect(cutOff.withLock { $0 }, "the end returns once the cut-off has run")
      do {
        try await parked
        Issue.record("a cut-off call is cancelled")
      } catch {
        #expect(error is CancellationError)
      }
      await #expect(throws: CancellationError.self, "a call after the end is refused") {
        try await tokens.run(holder.activation, { 1 }) {}
      }
    }
  }

  @Test func aCallThatFinishesDespiteTheCutKeepsItsResult() async throws {
    try await withSessionDeps {
      let tokens = ClaudeCodeTokens()
      let holder = ClaudeCodeTokens.Holder(session: SessionID("a"), activation: UUID())
      _ = tokens.mint(holder)
      let (started, start) = AsyncStream<Void>.makeStream()
      let cutOff = Mutex(false)
      async let finished = tokens.run(holder.activation, {
        start.yield()
        try? await ContinuousClock().sleep(for: .seconds(3600))
        return 8
      }) { cutOff.withLock { $0 = true } }
      for await _ in started { break }
      await tokens.end(holder.activation)
      let value = try await finished
      #expect(value == 8)
      #expect(!cutOff.withLock { $0 }, "a call that answered has nothing left to stop")
    }
  }

  @Test func anEndGivesUpOnACallThatTakesNoCancellation() async throws {
    let clock = TestClock()
    try await withDependencies {
      $0.continuousClock = clock
    } operation: {
      let tokens = ClaudeCodeTokens()
      let holder = ClaudeCodeTokens.Holder(session: SessionID("a"), activation: UUID())
      _ = tokens.mint(holder)
      let (started, start) = AsyncStream<Void>.makeStream()
      let stuck = Mutex<CheckedContinuation<Void, Never>?>(nil)
      async let call: Void = tokens.run(holder.activation, {
        await withCheckedContinuation { waiter in
          stuck.withLock { $0 = waiter }
          start.yield()
        }
      }) {}
      for await _ in started { break }
      let ended = Mutex(false)
      async let ending: Void = {
        await tokens.end(holder.activation)
        ended.withLock { $0 = true }
      }()
      #expect(try await realPollUntil {
        await clock.advance(by: .seconds(10))
        return ended.withLock { $0 }
      }, "the end returns after its wind-down")
      await ending
      stuck.withLock { $0 }?.resume()
      try await call
    }
  }

  @Test func theLoopbackListenerTakesOnlyARunningActivationsTokenForItsOwnSession() async throws {
    try await withSessionDeps {
      let loopback = try await ClaudeCodeLoopback()
      defer { loopback.config.remove() }
      let mine = try await loopback.claudeSession()
      let theirs = try await loopback.claudeSession()
      let token = loopback.host.tokens.mint(.init(session: mine, activation: UUID()))
      let stop: JSONValue = ["hook_event_name": "Stop", "stop_hook_active": false]

      #expect(try await loopback.post("/v1/session/\(mine.rawValue)/claude-code/hook", stop).status == .unauthorized)
      #expect(try await loopback.post("/v1/session/\(mine.rawValue)/claude-code/hook", stop, bearer: "cct_forged").status == .unauthorized)
      #expect(try await loopback.post("/v1/session/\(theirs.rawValue)/claude-code/hook", stop, bearer: token).status == .forbidden)
      #expect(try await loopback.post("/v1/session/\(theirs.rawValue)/mcp", ["jsonrpc": "2.0", "id": 1, "method": "ping"], bearer: token).status == .forbidden)

      let hook = try await loopback.post("/v1/session/\(mine.rawValue)/claude-code/hook", stop, bearer: token)
      #expect(hook.status == .ok)
      #expect(JSONValue.parse(try await hook.text()) == [:], "no loaded session, nothing to hand over")
      let ping = try await loopback.post("/v1/session/\(mine.rawValue)/mcp", ["jsonrpc": "2.0", "id": 1, "method": "ping"], bearer: token)
      #expect(ping.status == .ok)
      #expect(try await loopback.post("/v1/session/\(mine.rawValue)/files", [:], bearer: token).status == .notFound, "tools and hooks only")
    }
  }

  @Test func aToolCallClaudeCodeRepeatsIsAnsweredFromItsReceipt() async throws {
    try await withSessionDeps {
      let loopback = try await ClaudeCodeLoopback()
      defer { loopback.config.remove() }
      let session = try await loopback.claudeSession()
      let token = loopback.host.tokens.mint(.init(session: session, activation: UUID()))
      let call: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": [
        "name": "send_message",
        "arguments": ["message": "only once"],
        "_meta": ["claudecode/toolUseId": "toolu_01A", "progressToken": 2],
      ]]
      let first = try await loopback.post("/v1/session/\(session.rawValue)/mcp", call, bearer: token)
      let second = try await loopback.post("/v1/session/\(session.rawValue)/mcp", call, bearer: token)
      let firstText = try await first.text()
      #expect(firstText.contains("posted "))
      #expect(try await second.text() == firstText)
      let posted = try await loopback.space.query(
        "SELECT COUNT(*) FROM messages WHERE conversation_id = '\(session.rawValue)'",
        as: .shared(.anonymous),
      )
      #expect(posted.rows == [[.integer(1)]])
      guard case .sendMessage? = try await loopback.space.sessions.receipt(session, toolCallID: ToolCallID("toolu_01A")) else {
        Issue.record("a Claude Code session's tool call records its receipt")
        return
      }
      let failing: JSONValue = ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [
        "name": "read", "arguments": ["path": "/nowhere.md"], "_meta": ["claudecode/toolUseId": "toolu_01B"],
      ]]
      _ = try await loopback.post("/v1/session/\(session.rawValue)/mcp", failing, bearer: token)
      #expect(try await loopback.space.sessions.receipt(session, toolCallID: ToolCallID("toolu_01B")) == nil, "a failure has no effect to record")
    }
  }

  @Test func anImageOverWhatTheModelTakesReachesStandardInputAsItsLineAlone() async throws {
    try await withSessionDeps {
      let loopback = try await ClaudeCodeLoopback()
      defer { loopback.config.remove() }
      let session = try await loopback.claudeSession()
      let small: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
      let big = small + [UInt8](repeating: 0, count: ImageMedia.maxBytes)
      let delivery = try await loopback.space.sessions.post(
        .box(session), messageID: MessageID("m1"), sender: .init(id: "morgan", timeZone: TimeZone(identifier: "UTC")!),
        content: .init(text: "two shots"),
        uploads: [AttachmentUpload(name: "small.png", bytes: small), AttachmentUpload(name: "big.png", bytes: big)],
      )
      let stored = delivery.message.content.attachments
      #expect(stored.count == 2 && stored.allSatisfy { if case .image = $0 { true } else { false } }, "both are stored as images")
      let inputs = try await loopback.space.sessions.undrainedInputs(session).map(\.input)
      let blocks = try await loopback.host.render(inputs, channel: .standardInput, session: session)
      #expect(blocks.count == 2)
      guard case let .text(text) = blocks.first else {
        Issue.record("the message goes first as text, got \(blocks)")
        return
      }
      #expect(text.contains("/big.png (image/png, \(big.count) bytes)"))
      #expect(blocks.last == .image(mediaType: "image/png", base64: Data(small).base64EncodedString()))
    }
  }
}

struct ClaudeCodeLoopback {
  let space: Space
  let host: ClaudeCodeHost
  let api: FetchClient
  let config: ScratchFolder

  init(
    space: Space? = nil, hub: MachineHub? = nil, scripts: Scripts? = nil, credentials: CredentialResolver = .unavailable,
  ) async throws {
    let space = try space ?? Space.inMemory()
    self.space = space
    config = try ScratchFolder("claude-config")
    _ = try await space.fs(.shared).write("/models.json", Data("""
    {"claude": {"dialect": "claude", "baseURL": "https://api.anthropic.com/v1",
      "models": {"opus": {"maxInput": 1000000, "maxOutput": 32000, "efforts": ["high"], "defaultEffort": "high"}}}}
    """.utf8), ifMatch: nil)
    host = ClaudeCodeHost(
      space: space, credentials: credentials, usage: UsageBoard(),
      configDirectory: config.url,
      origin: "https://space", spaceID: "spc_test",
    )
    let service = await SessionService(sessions: space.sessions, loopConfig: LoopConfig(
      executeTool: { _ in .failure(.init(message: "no tools")) },
      inference: { _ in throw CancellationError() },
      compact: { _, _ in CompactionResult(summary: "") },
      budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
      claudeCode: host.seam,
    ))
    api = ServeTesting.client(claudeCodeLoopbackHandler(
      space: space, hub: hub ?? MachineHub(space: space), credentials: .unavailable, version: "test",
      host: host, service: service, scripts: scripts,
    ))
  }

  func claudeSession() async throws -> SessionID {
    try await space.sessions.createSession(
      group: .shared,
      title: "c", kind: .agent, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")), snapshot: .init(),
    )
  }

  func post(_ path: String, _ body: JSONValue, bearer: String? = nil) async throws -> Response {
    var request = Request(url: URL(string: "http://127.0.0.1\(path)")!, method: .post)
    request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    if let bearer { request.headers[.authorization] = "Bearer " + bearer }
    return try await api(request)
  }
}
