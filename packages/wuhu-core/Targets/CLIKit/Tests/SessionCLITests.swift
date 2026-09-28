@testable import CLIKit
import Dependencies
import Fetch
import Foundation
import InferenceKit
import JSONValue
import LoopCore
import Scratch
import ServeTesting
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
import SpaceServer
import Synchronization
import Testing
import WuhuAI

private let testModelsJSON = """
{
  "testing": {
    "dialect": "anthropic",
    "baseURL": "http://localhost:1",
    "models": {
      "test-model": {
        "maxInput": 100000,
        "maxOutput": 1000,
        "efforts": ["low", "high"],
        "defaultEffort": "high"
      }
    }
  }
}
"""

// The session stack resolves uuid/date/clock through swift-dependencies; the
// service must be constructed inside the same scope so its store inherits them.
private func withSessionDeps<R>(_ body: () async throws -> R) async rethrows -> R {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.uuid = UUIDGenerator { UUID() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
  } operation: {
    try await body()
  }
}

private func reply(_ content: [ContentBlock]) -> LoopCore.InferenceReply {
  LoopCore.InferenceReply(
    message: AssistantMessage(content: content),
    metadata: AssistantMessageMetadata(
      stopReason: .stop,
      usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10),
    ),
  )
}

private final class Steps: Sendable {
  typealias Step = @Sendable (LoopCore.InferenceRequest) async throws -> LoopCore.InferenceReply
  private let steps: Mutex<[Step]>

  init(_ steps: [Step]) {
    self.steps = Mutex(steps)
  }

  func next(_ request: LoopCore.InferenceRequest) async throws -> LoopCore.InferenceReply {
    let step = steps.withLock { steps -> Step? in
      steps.isEmpty ? nil : steps.removeFirst()
    }
    guard let step else { throw InferenceError.other(status: nil, body: "inference beyond the script") }
    return try await step(request)
  }
}

private final class SessionCLIHarness: Sendable {
  let scratch: ScratchFolder
  let root: URL
  let walletDirectory: URL
  let space: Space
  let store: SessionStore
  let stdout: Sink
  let stderr: Sink
  let fetch: FetchClient
  // Channel-post delivery wakes recipients through the work-signal bus, which
  // only a running service consumes — mirror serve's runtime here.
  private let serviceTask: Task<Void, Never>

  deinit {
    serviceTask.cancel()
  }

  init(models: Bool = true, inference: @escaping Steps.Step) async throws {
    scratch = try ScratchFolder("session-cli")
    root = scratch.url
    let home = root.appendingPathComponent("home", isDirectory: true)
    let cwd = root.appendingPathComponent("work", isDirectory: true)
    walletDirectory = cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: walletDirectory, withIntermediateDirectories: true)
    try JSONEncoder().encode(["space": "space"])
      .write(to: walletDirectory.appendingPathComponent("config.json"), options: .atomic)
    self.home = home
    self.cwd = cwd

    space = try Space.inMemory()
    store = space.sessions
    if models {
      _ = try await space.fs(.shared).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
    }
    let hub = MachineHub(space: space)
    let attempts = AttemptHub()
    let executor = ToolExecutor(space: space)
    let config = LoopConfig(
      executeTool: { invocation in
        try await executor.execute(session: invocation.sessionID, call: invocation.call, state: invocation.state)
      },
      inference: { request in try await inference(request) },
      compact: { _, _ in CompactionResult(summary: "compacted") },
      budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
    )
    let service = await SessionService(sessions: store, loopConfig: config)
    serviceTask = Task {
      do {
        try await service.start()
      } catch is CancellationError {
      } catch {
        Issue.record("session service failed: \(error)")
      }
    }
    let runtime = SessionRuntime(space: space, service: service, attempts: attempts)
    let handler = SpaceServer.handler(space: space, hub: hub, sessions: runtime, dev: true, webApp: nil)
    fetch = ServeTesting.client(upgrading: handler)
    stdout = Sink()
    stderr = Sink()
  }

  private let home: URL
  private let cwd: URL

  func run(_ arguments: [String], stdin: String = "") async -> Int32 {
    let runner = CommandRunner(
      fetch: fetch,
      observeFetch: fetch,
      stdin: { stdin },
      stdout: { [stdout] text in await stdout.append(text) },
      stderr: { [stderr] text in await stderr.append(text) },
      environment: ["HOME": home.path],
      currentDirectory: cwd.path,
    )
    return await runner.run(arguments: arguments)
  }

  func createSession() async throws -> String {
    let before = await stdout.text
    let code = await run(["session", "create", "--kind", "agent", "--provider", "testing", "--model", "test-model", "worker"])
    let stderrText = await stderr.text
    #expect(code == 0, "session create failed: \(stderrText)")
    let after = await stdout.text
    let id = String(after.dropFirst(before.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = id.split(separator: "-")
    #expect(parts.count >= 3, "expected a word-name session id, got: \(id)")
    #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLowercase) }, "expected lowercase words, got: \(id)")
    return id
  }
}

private actor Sink {
  var text = ""

  func append(_ value: String) {
    text += value
  }
}

private func pendingMessageIDs(in transcript: Transcript) -> [String] {
  transcript.items.compactMap { item in
    guard case let .message(message) = item, message.owesReply else { return nil }
    return message.messageID.rawValue
  }.sorted()
}

private struct UntilTimeout: Error {}

private func until(
  _ description: String,
  timeout: Duration = .seconds(10),
  _ condition: () async throws -> Bool,
) async throws {
  let real = ContinuousClock()
  let deadline = real.now.advanced(by: timeout)
  while real.now < deadline {
    if try await condition() { return }
    try? await real.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(description)")
  throw UntilTimeout()
}

@Suite struct SessionCLITests {
  @Test func sendFromAnUnenrolledSeatPostsAsTheOwnerInItsZone() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let id = try await harness.createSession()

      #expect(await harness.run(["send", id, "please look"]) == 0)
      #expect(await harness.stdout.text.contains("posted "))
      let message = try #require(try await harness.store.messages(conversation: ConversationID(id)).last)
      #expect(message.sender.id == "owner")
      #expect(message.sender.timeZone.identifier == TimeZone.current.identifier)
    }
  }

  @Test func sendToATaskIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let parent = try await harness.createSession()
      let id = try await harness.store.createSession(
        group: .shared,
        title: "coder", kind: .task, parent: SessionID(parent), createdBy: parent,
        executor: .kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high")),
      ).rawValue

      #expect(await harness.run(["send", id, "please look"]) != 0)
      #expect(await harness.stderr.text.contains("takes no messages from people"))
      #expect(try await !harness.store.transcript(SessionID(id)).hasWork)
    }
  }

  @Test func createOfATaskIsRefused() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let args = ["session", "create", "--kind", "task", "--provider", "testing", "--model", "test-model", "worker"]
      #expect(await harness.run(args) != 0)
      #expect(await harness.stderr.text.contains("a person creates agents only"))
    }
  }

  @Test func sendAttachUploadsAnyFileAndTheServerKeepsTheCopy() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let id = try await harness.createSession()
      let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
      let pdf = Data("%PDF-1.7".utf8)
      let shot = harness.root.appendingPathComponent("shot.png")
      let report = harness.root.appendingPathComponent("report.pdf")
      try png.write(to: shot)
      try pdf.write(to: report)

      #expect(await harness.run(["send", "--attach", shot.path, "--attach", report.path, id, "look"]) == 0)
      let output = await harness.stdout.text
      let conversation = try #require(output.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
      let message = try #require(try await harness.store.messages(conversation: ConversationID(conversation)).last)
      let attachments = message.content.attachments
      let imagePath = try #require(attachments.first?.path)
      let filePath = try #require(attachments.last?.path)
      #expect(attachments == [
        .image(path: imagePath, mimeType: "image/png", size: png.count),
        .file(path: filePath, mimeType: "application/pdf", size: pdf.count),
      ])
      #expect(imagePath.hasPrefix("/_/conversations/\(conversation)/attachments/"))
      #expect(imagePath.hasSuffix("Z/shot.png"))
      #expect(try await harness.space.fs(.shared).read(imagePath).1 == png)
      #expect(try await harness.space.fs(.shared).read(filePath).1 == pdf)
    }
  }

  // Sparse files: the sizes are refused from the file system, before a byte
  // is read or uploaded.
  @Test func sendAttachRefusesOverLimitFilesBeforeUploading() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let id = try await harness.createSession()
      func sparse(_ name: String, _ size: Int) throws -> String {
        let url = harness.root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url.path
      }
      let small = try (1 ... 9).map { try sparse("small\($0).txt", 1) }
      let big = try sparse("big.bin", AttachmentLimits.maxFileBytes + 1)
      let full = try (1 ... 3).map { try sparse("full\($0).bin", AttachmentLimits.maxFileBytes) }
      let extra = try sparse("extra.bin", 1 << 20)
      let cases: [([String], String)] = [
        (small, "at most 8 attachments"),
        ([big], "big.bin is over 50 MiB"),
        (full + [extra], "attachments pass 150 MiB in total at \(extra)"),
      ]
      for (paths, refusal) in cases {
        let before = await harness.stderr.text
        #expect(await harness.run(["send"] + paths.flatMap { ["--attach", $0] } + [id, "look"]) != 0)
        let stderr = String(await harness.stderr.text.dropFirst(before.count))
        #expect(stderr.contains(refusal), "\(stderr)")
      }
    }
  }

  @Test func sessionLogNamesTheSenderTheMessageAndItsAttachments() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let id = try await harness.createSession()
      _ = try await harness.space.setUserProfile(principal: "owner", handle: "boss", displayName: nil)
      let shot = harness.root.appendingPathComponent("shot.png")
      let report = harness.root.appendingPathComponent("report.pdf")
      try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]).write(to: shot)
      try Data("%PDF-1.7".utf8).write(to: report)
      #expect(await harness.run(["send", "--attach", shot.path, "--attach", report.path, id, "look"]) == 0)
      let message = try #require(try await harness.store.messages(conversation: ConversationID(id)).last)
      let paths = message.content.attachments.map(\.path)
      #expect(paths.count == 2)

      let before = await harness.stdout.text
      #expect(await harness.run(["session", "log", id]) == 0)
      let log = String(await harness.stdout.text.dropFirst(before.count))
      #expect(log.contains("] boss (owner) · user · group shared · "))
      let attached = paths.map { "\nattached: \($0)" }.joined()
      #expect(log.contains(" · message · id \(message.id.rawValue)\nlook\(attached)\n"))
    }
  }

  @Test func sendWaitTerminatesOnTheSessionsPost() async throws {
    try await withSessionDeps {
      let steps = Steps([
        { request in
          let pending = pendingMessageIDs(in: request.transcript)
          return reply([.toolCall(ToolCall(
            id: "call_1",
            name: "send_message",
            arguments: .object([
              "message": .string("hello from the session"),
              "reply_target": pending.first.map(JSONValue.string) ?? .null,
            ]),
          ))])
        },
        { _ in reply([.text(.init(text: "done"))]) },
      ])
      let harness = try await SessionCLIHarness { try await steps.next($0) }
      let id = try await harness.createSession()

      let code = await harness.run(["send", id, "are you there?", "--wait", "--timeout", "30"])
      let output = await harness.stdout.text
      let errors = await harness.stderr.text
      #expect(code == 0, errors.isEmpty ? "" : "stderr: \(errors)")
      #expect(output.contains("hello from the session"))
    }
  }

  @Test func sendWaitExitsNonzeroWhenTheSessionErrors() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in
        throw InferenceError.other(status: 500, body: "provider exploded")
      }
      let id = try await harness.createSession()

      #expect(await harness.run(["send", id, "hi", "--wait", "--timeout", "30"]) == 1)
      let errors = await harness.stderr.text
      #expect(errors.contains("session errored"))
      #expect(errors.contains("provider exploded"))

      // Already parked errored: the subscribe-time state snapshot terminates
      // the wait without any new event.
      #expect(await harness.run(["send", id, "again", "--wait", "--timeout", "30"]) == 1)
    }
  }

  @Test func inboxPrintsAboveTheCursorAndAdvances() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in
        throw InferenceError.other(status: 500, body: "provider exploded")
      }
      let id = try await harness.createSession()

      #expect(await harness.run(["send", id, "go"]) == 0)
      try await until("errored notification") {
        try await harness.store.notifications(recipient: "owner").contains { $0.kind == .sessionErrored }
      }

      let before = await harness.stdout.text
      #expect(await harness.run(["inbox"]) == 0)
      let first = await harness.stdout.text
      #expect(String(first.dropFirst(before.count)).contains("errored"))
      #expect(String(first.dropFirst(before.count)).contains("provider exploded"))

      #expect(await harness.run(["inbox"]) == 0)
      let second = await harness.stdout.text
      #expect(second == first)
    }
  }

  @Test func sessionVerbsAndListRunAgainstTheRealServer() async throws {
    try await withSessionDeps {
      let harness = try await SessionCLIHarness { _ in reply([.text(.init(text: "ok"))]) }
      let id = try await harness.createSession()

      #expect(await harness.run(["session", "interrupt", id]) == 0)
      let interrupted = try await harness.store.record(SessionID(id))
      #expect(interrupted.hold == .interrupted)
      #expect(await harness.run(["session", "resume", id]) == 0)
      let beforeRename = await harness.stdout.text
      #expect(await harness.run(["session", "rename", id, "  renamed worker  "]) == 0)
      #expect(String(await harness.stdout.text.dropFirst(beforeRename.count)) == "renamed worker\n")
      #expect(try await harness.store.record(SessionID(id)).title == "renamed worker")
      #expect(await harness.run(["session", "rename", id, "  "]) == 1)
      #expect(try await harness.store.record(SessionID(id)).title == "renamed worker")
      let beforeTags = await harness.stdout.text
      #expect(await harness.run(["session", "tags", id, "wuhu:13", "gate"]) == 0)
      #expect(String(await harness.stdout.text.dropFirst(beforeTags.count)) == "wuhu:13\ngate\n")
      #expect(try await harness.store.record(SessionID(id)).tags == ["wuhu:13", "gate"])

      #expect(await harness.run(["session", "archive", id]) == 0)
      #expect(await harness.run(["session", "unarchive", id]) == 0)

      let second = try await harness.createSession()
      let beforeList = await harness.stdout.text
      #expect(await harness.run(["session", "list"]) == 0)
      let listing = String(await harness.stdout.text.dropFirst(beforeList.count))
      #expect(listing.contains("worker"))
      let firstAt = try #require(listing.range(of: id))
      let secondAt = try #require(listing.range(of: second))
      #expect(firstAt.lowerBound < secondAt.lowerBound, "session list is allocation-ordered")

      #expect(await harness.run(["session", "interrupt", "unknown-word-name"]) == 1)
      #expect(await harness.run(["session", "interrupt", UUID().uuidString]) == 64)
      #expect(await harness.run(["session", "interrupt", "solo"]) == 64)
    }
  }

  @Test func sessionLogDefaultsToTheConversationAndLevelsTheDirectView() async throws {
    try await withSessionDeps {
      let steps = Steps([
        { request in
          let pending = pendingMessageIDs(in: request.transcript)
          return reply([
            .text(.init(text: "thinking out loud")),
            .toolCall(ToolCall(
              id: "call_read",
              name: "read",
              arguments: .object(["path": .string("/models.json")]),
            )),
            .toolCall(ToolCall(
              id: "call_reply",
              name: "send_message",
              arguments: .object([
                "message": .string("forty-two"),
                "reply_target": pending.first.map(JSONValue.string) ?? .null,
              ]),
            )),
          ])
        },
        { _ in reply([.text(.init(text: "wrapping up"))]) },
      ])
      let harness = try await SessionCLIHarness { try await steps.next($0) }
      let id = try await harness.createSession()
      #expect(await harness.run(["send", id, "what is the answer?", "--wait", "--timeout", "30"]) == 0)

      let beforeConversation = await harness.stdout.text
      #expect(await harness.run(["session", "log", id]) == 0)
      let conversation = String(await harness.stdout.text.dropFirst(beforeConversation.count))
      #expect(conversation.contains("what is the answer?"))
      #expect(conversation.contains("forty-two"))
      #expect(!conversation.contains("thinking out loud"), "the conversation view never shows private monologue")

      let beforeNarrative = await harness.stdout.text
      #expect(await harness.run(["session", "log", "--direct", id]) == 0)
      let narrative = String(await harness.stdout.text.dropFirst(beforeNarrative.count))
      #expect(narrative.contains("thinking out loud"))
      #expect(narrative.contains("↩ forty-two"), "L1 shows what the session actually said")
      #expect(narrative.contains("← posted"), "send_message results are the narrative reply")
      #expect(!narrative.contains("→ read"))
      #expect(!narrative.contains("→ send_message"))
      #expect(!narrative.contains("ctx "))

      let beforeVerbose = await harness.stdout.text
      #expect(await harness.run(["session", "log", "-v", id]) == 0)
      let verbose = String(await harness.stdout.text.dropFirst(beforeVerbose.count))
      #expect(verbose.contains("→ read"))
      #expect(verbose.contains("→ send_message"))
      #expect(verbose.contains("ctx 10 tok"))
      #expect(!verbose.contains("dialect"), "tool results stay out of L2")

      let beforeEverything = await harness.stdout.text
      #expect(await harness.run(["session", "log", "-vv", id]) == 0)
      let everything = String(await harness.stdout.text.dropFirst(beforeEverything.count))
      #expect(everything.contains("dialect"), "L3 carries the read result")
    }
  }

  @Test func sessionEntryPrintsOneItemInFull() async throws {
    try await withSessionDeps {
      let steps = Steps([
        { request in
          let pending = pendingMessageIDs(in: request.transcript)
          return reply([
            .text(.init(text: "thinking out loud")),
            .toolCall(ToolCall(
              id: "call_reply",
              name: "send_message",
              arguments: .object([
                "message": .string("forty-two"),
                "reply_target": pending.first.map(JSONValue.string) ?? .null,
              ]),
            )),
          ])
        },
        { _ in reply([.text(.init(text: "wrapping up"))]) },
      ])
      let harness = try await SessionCLIHarness { try await steps.next($0) }
      let id = try await harness.createSession()
      #expect(await harness.run(["send", id, "what is the answer?", "--wait", "--timeout", "30"]) == 0)

      let beforeNarrative = await harness.stdout.text
      #expect(await harness.run(["session", "log", "--direct", id]) == 0)
      let narrative = String(await harness.stdout.text.dropFirst(beforeNarrative.count))
      let ref = try #require(narrative.firstMatch(of: /\[([0-9a-f]+:\d+:\d+)\] assistant/)?.1)

      let beforeEntry = await harness.stdout.text
      #expect(await harness.run(["session", "entry", id, String(ref)]) == 0)
      let entry = String(await harness.stdout.text.dropFirst(beforeEntry.count))
      #expect(entry.contains("thinking out loud"))
      #expect(entry.contains("→ send_message"), "the entry view is the full item, levels do not apply")

      #expect(await harness.run(["session", "entry", id, "99:0"]) == 1)
    }
  }
}

@Suite struct SessionVerbParserTests {
  @Test func parsesSend() throws {
    #expect(try Command.parse(["send", "abc", "hi"]) == .send(SendCommand(
      session: "abc", text: "hi", wait: false, timeout: nil,
    )))
    #expect(try Command.parse(["send", "--wait", "--timeout", "5", "abc", "hi"]) == .send(SendCommand(
      session: "abc", text: "hi", wait: true, timeout: 5,
    )))
    #expect(try Command.parse(["send", "--attach", "a.mp4", "--attach", "b.pdf", "abc", "hi"]) == .send(SendCommand(
      session: "abc", text: "hi", wait: false, timeout: nil, attachments: ["a.mp4", "b.pdf"],
    )))
    #expect(throws: (any Error).self) { try Command.parse(["send", "--image", "a.png", "abc", "hi"]) }
    #expect(throws: (any Error).self) { try Command.parse(["send", "--direct", "abc", "hi"]) }
    #expect(throws: (any Error).self) { try Command.parse(["send", "--timeout", "5", "abc", "hi"]) }
    #expect(throws: (any Error).self) { try Command.parse(["send", "abc"]) }
  }

  @Test func parsesSessionSubcommands() throws {
    #expect(try Command.parse([
      "session", "create", "--provider", "p", "--model", "m", "--effort", "low", "--tag", "a", "--tag", "b", "title",
    ]) == .sessionCreate(SessionCreateCommand(
      title: "title", provider: "p", model: "m", effort: "low", tags: ["a", "b"],
    )))
    #expect(try Command.parse([
      "session", "create", "--model", "m", "--template", "night", "title",
    ]) == .sessionCreate(SessionCreateCommand(title: "title", model: "m", tags: [], template: "night")))
    #expect(try Command.parse([
      "session", "create", "--top-level", "--home-group", "alice", "title",
    ]) == .sessionCreate(SessionCreateCommand(title: "title", tags: [], topLevel: true, homeGroup: "alice")))
    #expect(try Command.parse(["group", "set", "--space-layer", "off", "alice"]) == .groupSet(id: "alice", spaceLayer: false))
    #expect(try Command.parse(["group", "set", "--space-layer", "on", "alice"]) == .groupSet(id: "alice", spaceLayer: true))
    #expect(throws: (any Error).self) { try Command.parse(["group", "set", "--space-layer", "maybe", "alice"]) }
    #expect(throws: (any Error).self) {
      try Command.parse(["session", "create", "--executor", "kernel", "title"])
    }
    #expect(try Command.parse(["session", "interrupt", "abc"]) == .sessionAction(.interrupt, id: "abc"))
    #expect(try Command.parse(["session", "compact", "abc"]) == .sessionCompact(id: "abc", instructions: nil))
    #expect(
      try Command.parse(["session", "compact", "abc", "--instructions", "keep the notes"])
        == .sessionCompact(id: "abc", instructions: "keep the notes"),
    )
    #expect(
      try Command.parse(["session", "compact", "--instructions", "keep the notes", "abc"])
        == .sessionCompact(id: "abc", instructions: "keep the notes"),
    )
    #expect(try Command.parse(["session", "rename", "abc", "New title"]) == .sessionRename(id: "abc", title: "New title"))
    #expect(throws: (any Error).self) { try Command.parse(["session", "rename", "abc"]) }
    #expect(try Command.parse(["session", "tags", "abc", "wuhu:13", "gate"]) == .sessionTags(id: "abc", tags: ["wuhu:13", "gate"]))
    #expect(try Command.parse(["session", "tags", "abc"]) == .sessionTags(id: "abc", tags: []))
    #expect(try Command.parse(["session", "tags", "abc", "--", "--odd"]) == .sessionTags(id: "abc", tags: ["--odd"]))
    #expect(throws: (any Error).self) { try Command.parse(["session", "tags"]) }
    #expect(try Command.parse(["session", "unarchive", "abc"]) == .sessionAction(.unarchive, id: "abc"))
    #expect(try Command.parse(["session", "log", "abc"]) == .sessionLog(id: "abc", view: .conversation(limit: nil, before: nil)))
    #expect(
      try Command.parse(["session", "log", "--direct", "abc"])
        == .sessionLog(id: "abc", view: .direct(level: 1, limit: nil, before: nil)),
    )
    #expect(
      try Command.parse(["session", "log", "-v", "abc"])
        == .sessionLog(id: "abc", view: .direct(level: 2, limit: nil, before: nil)),
    )
    #expect(
      try Command.parse(["session", "log", "-vv", "--limit", "10", "--before", "3:41", "abc"])
        == .sessionLog(id: "abc", view: .direct(level: 3, limit: 10, before: "3:41")),
    )
    #expect(
      try Command.parse(["session", "log", "--limit", "5", "abc"])
        == .sessionLog(id: "abc", view: .conversation(limit: 5, before: nil)),
    )
    #expect(
      try Command.parse(["session", "log", "--before", "12", "abc"])
        == .sessionLog(id: "abc", view: .conversation(limit: nil, before: 12)),
    )
    #expect(throws: (any Error).self) { try Command.parse(["session", "log", "--before", "3:41", "abc"]) }
    #expect(throws: (any Error).self) { try Command.parse(["session", "log", "--all", "abc"]) }
    #expect(try Command.parse(["session", "entry", "abc", "1:2"]) == .sessionEntry(session: "abc", ref: "1:2"))
    #expect(throws: (any Error).self) { try Command.parse(["session", "entry", "abc"]) }
    #expect(try Command.parse(["session", "list"]) == .sessionList)
    #expect(try Command.parse(["inbox"]) == .inbox)
    #expect(throws: (any Error).self) { try Command.parse(["session", "steer", "abc"]) }
  }

  @Test func personaCacheRoundTripsPerSpaceAndFailsLoudlyWhenMalformed() throws {
    let scratch = try ScratchFolder("persona")
    defer { scratch.remove() }
    let directory = scratch.url
    var wallet = Wallet(directory: directory)
    #expect(try wallet.persona(space: "a") == nil)
    try wallet.recordPersona("amber-fox-creek", space: "a")
    try wallet.recordPersona("blue-pond-otter", space: "b")
    #expect(try wallet.persona(space: "a") == "amber-fox-creek")
    var rebuilt = Wallet(directory: directory)
    #expect(try rebuilt.persona(space: "b") == "blue-pond-otter")
    try Data("not json".utf8).write(to: directory.appendingPathComponent("personas.json"))
    var corrupted = Wallet(directory: directory)
    #expect(throws: (any Error).self) { try corrupted.persona(space: "a") }
  }
}
