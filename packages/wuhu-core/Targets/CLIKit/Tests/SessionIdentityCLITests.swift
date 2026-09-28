@testable import CLIKit
import Dependencies
import Fetch
import Foundation
import InferenceKit
import LoopCore
import MachineContract
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

private let identityModelsJSON = """
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

private func withIdentityDeps<R>(_ body: () async throws -> R) async rethrows -> R {
  try await withDependencies {
    $0.date = DateGenerator { Date() }
    $0.uuid = UUIDGenerator { UUID() }
    $0.continuousClock = ContinuousClock()
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
  } operation: {
    try await body()
  }
}

private final class HostLog: Sendable {
  let list = Mutex<[String]>([])
}

private actor Output {
  var text = ""
  func append(_ value: String) { self.text += value }
  func take() -> String {
    defer { self.text = "" }
    return self.text
  }
}

// The CLI as a session's exec runs it: WUHU_EXEC=1 and a token the real
// handler minted, with the cwd's wallet pinned to another space so that any
// read of it shows up as traffic to the wrong host.
private final class IdentityHarness: Sendable {
  static let sessionSpace = "https://space.test:5530"

  let space: Space
  let store: SessionStore
  let scratch: ScratchFolder
  let home: URL
  let cwd: URL
  let wallet: URL
  let fetch: FetchClient
  let hosts = HostLog()
  let stdout = Output()
  let stderr = Output()
  let parent: SessionID
  let child: SessionID
  let stranger: SessionID
  let token: String
  private let serviceTask: Task<Void, Never>

  deinit { self.serviceTask.cancel() }

  init() async throws {
    self.scratch = try ScratchFolder("identity")
    let root = self.scratch.url
    self.home = root.appendingPathComponent("home", isDirectory: true)
    self.cwd = root.appendingPathComponent("work", isDirectory: true)
    self.wallet = self.cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: self.wallet, withIntermediateDirectories: true)
    try JSONEncoder().encode(["space": "elsewhere.test"])
      .write(to: self.wallet.appendingPathComponent("config.json"), options: .atomic)

    let space = try Space.inMemory()
    self.space = space
    self.store = space.sessions
    _ = try await space.fs(.shared).write("/models.json", Data(identityModelsJSON.utf8), ifMatch: nil)
    let tokens = ExecTokens(spaceURL: Self.sessionSpace)
    let hub = MachineHub(space: space, tokens: tokens)
    let executor = ToolExecutor(space: space)
    let config = LoopConfig(
      executeTool: { invocation in
        try await executor.execute(session: invocation.sessionID, call: invocation.call, state: invocation.state)
      },
      inference: { _ in
        LoopCore.InferenceReply(
          message: AssistantMessage(content: [.text(.init(text: "ok"))]),
          metadata: AssistantMessageMetadata(stopReason: .stop, usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10)),
        )
      },
      compact: { _, _ in CompactionResult(summary: "compacted") },
      budget: { _ in ContextBudget(maxInput: 1_000_000, maxOutput: 1000) },
    )
    let service = await SessionService(sessions: self.store, loopConfig: config)
    self.serviceTask = Task { try? await service.start() }
    let runtime = SessionRuntime(space: space, service: service, attempts: AttemptHub())
    let handler = SpaceServer.configuredHandler(space: space, hub: hub, sessions: runtime, dev: true, webApp: nil, execTokens: tokens)
    let inner = ServeTesting.client(upgrading: handler)
    let hosts = self.hosts
    self.fetch = FetchClient { request in
      hosts.list.withLock { $0.append([request.url.host, request.url.port.map(String.init)].compactMap(\.self).joined(separator: ":")) }
      return try await inner(request)
    }

    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    self.parent = try await self.store.createSession(group: .shared, title: "orchestrator", kind: .agent, createdBy: "owner", executor: model)
    self.child = try await self.store.createSession(
      group: .shared,
      title: "coder", kind: .task, parent: self.parent, createdBy: self.parent.rawValue, executor: model,
    )
    self.stranger = try await self.store.createSession(group: .shared, title: "stranger", kind: .agent, createdBy: "owner", executor: model)
    let machine = try await space.addMachine(name: "box")
    let exec = try await space.mintExec(machine: machine.id, caller: self.parent.rawValue)
    self.token = tokens.credential(session: self.parent, exec: exec.id, timeout: nil, now: Date()).token
  }

  var sessionEnvironment: [String: String] {
    [
      "HOME": self.home.path,
      "WUHU_EXEC": "1",
      "WUHU_TOKEN": self.token,
      "WUHU_SPACE_URL": Self.sessionSpace,
    ]
  }

  func run(_ arguments: [String], environment: [String: String]) async -> (code: Int32, stdout: String, stderr: String, hosts: [String]) {
    self.hosts.list.withLock { $0 = [] }
    let runner = CommandRunner(
      fetch: self.fetch,
      observeFetch: self.fetch,
      stdin: { "" },
      stdout: { [stdout] text in await stdout.append(text) },
      stderr: { [stderr] text in await stderr.append(text) },
      environment: environment.merging(["TMPDIR": self.scratch.path]) { old, _ in old },
      currentDirectory: self.cwd.path,
    )
    let code = await runner.run(arguments: arguments)
    return (code, await self.stdout.take(), await self.stderr.take(), self.hosts.list.withLock { $0 })
  }

  func asSession(_ arguments: [String]) async -> (code: Int32, stdout: String, stderr: String, hosts: [String]) {
    await self.run(arguments, environment: self.sessionEnvironment)
  }
}

@Suite struct SessionIdentityCLITests {
  // Archive also admits an admin of the session's group, which this top-level
  // parent is; interrupt keeps the self-and-descendants rule.
  @Test func anUnrelatedInterruptIsRefusedWithTheReasonAndItsOwnChildsTagsWork() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let interrupt = await h.asSession(["session", "interrupt", h.stranger.rawValue])
      #expect(interrupt.code == 1)
      #expect(interrupt.stderr.contains(
        "\(h.parent.rawValue) may not change session \(h.stranger.rawValue): only the session itself, its ancestors and humans may",
      ))
      #expect(try await h.store.record(h.stranger).hold == .normal)

      let tags = await h.asSession(["session", "tags", h.child.rawValue, "wuhu:37"])
      #expect(tags.code == 0, "\(tags.stderr)")
      #expect(tags.stdout == "wuhu:37\n")
      #expect(tags.hosts.allSatisfy { $0 == "space.test:5530" })
    }
  }

  @Test func userListIsRefusedToTheSessionAndTheWalletOptInIsRefusedToo() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let refused = await h.asSession(["user", "list"])
      #expect(refused.code == 1)
      #expect(refused.stderr == sessionRefusal + "\n")
      #expect(refused.hosts.isEmpty, "a refused verb reaches no server")

      var environment = h.sessionEnvironment
      environment["WUHU_IDENTITY"] = "wallet"
      let wallet = await h.run(["user", "list"], environment: environment)
      #expect(wallet.code == 1)
      #expect(wallet.stderr.contains("WUHU_IDENTITY=wallet is refused"), "\(wallet.stderr)")
      #expect(wallet.hosts.isEmpty, "the cwd's wallet is never opened")
    }
  }

  @Test func aCwdPinnedToAnotherSpaceStillActsOnTheSessionsSpace() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let notes = "/_/sessions/\(h.parent.rawValue)/notes.md"
      let write = await h.asSession(["write", "--body", "mine", notes])
      #expect(write.code == 0, "\(write.stderr)")
      #expect(write.hosts.allSatisfy { $0 == "space.test:5530" })
      #expect(try await h.space.fs(.shared).read(notes).1 == Data("mine".utf8))
      let edit = await h.asSession(["edit", notes, "mine", "ours"])
      #expect(edit.code == 0, "read-before-write state carries across the exec's calls: \(edit.stderr)")
      #expect(!FileManager.default.fileExists(atPath: h.wallet.appendingPathComponent("etags.json").path))

      let foreign = await h.asSession(["write", "--body", "x", "/_/sessions/\(h.stranger.rawValue)/notes.md"])
      #expect(foreign.code == 1)

      let elsewhere = await h.asSession(["read", "wuhu://elsewhere.test/notes.md"])
      #expect(elsewhere.code == 1)
      #expect(elsewhere.stderr.contains("elsewhere.test is not this session's space"))
      #expect(elsewhere.hosts.isEmpty)
      let same = await h.asSession(["read", "wuhu://space.test:5530\(notes)"])
      #expect(same.stdout == "ours")
    }
  }

  @Test func newWorksAsTheSessionButNeverIntoAnotherHome() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let home = "/_/sessions/\(h.parent.rawValue)"
      let template = "---\ntemplate:\n  strategy: incr\n  prefix: J\n---\nhi"
      #expect(await h.asSession(["write", "--body", template, "\(home)/j.md"]).code == 0)
      let made = await h.asSession(["new", "\(home)/j.md"])
      #expect(made.code == 0, "\(made.stderr)")
      #expect(made.stdout == "\(home)/J-1.md\n")
      #expect(made.hosts.allSatisfy { $0 == "space.test:5530" })

      let foreign = await h.asSession(["new", "\(home)/j.md", "/_/sessions/\(h.stranger.rawValue)"])
      #expect(foreign.code == 1)
      #expect((try? await h.space.fs(.shared).read("/_/sessions/\(h.stranger.rawValue)/J-1.md")) == nil)
    }
  }

  @Test func aMissingOrRejectedTokenIsAnErrorThatSaysWhyAndNeverTheWallet() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      var missing = h.sessionEnvironment
      missing["WUHU_TOKEN"] = nil
      let unset = await h.run(["ls", "/"], environment: missing)
      #expect(unset.code == 1)
      #expect(unset.stderr.contains("WUHU_TOKEN is unset"))
      #expect(unset.hosts.isEmpty)

      var bogus = h.sessionEnvironment
      bogus["WUHU_TOKEN"] = "wst_" + String(repeating: "0", count: 64)
      let rejected = await h.run(["ls", "/"], environment: bogus)
      #expect(rejected.code == 1)
      #expect(rejected.stderr.contains("this session token is not valid"))
      #expect(rejected.hosts == ["space.test:5530"])

      var noURL = h.sessionEnvironment
      noURL["WUHU_SPACE_URL"] = nil
      let unaddressed = await h.run(["ls", "/"], environment: noURL)
      #expect(unaddressed.code == 1)
      #expect(unaddressed.stderr.contains("WUHU_SPACE_URL is unset"))
      #expect(!unaddressed.stderr.contains(h.token))

      var odd = h.sessionEnvironment
      odd["WUHU_IDENTITY"] = "owner"
      #expect(await h.run(["ls", "/"], environment: odd).code == 64)
    }
  }

  @Test func withoutWuhuExecNothingChanges() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      var terminal = h.sessionEnvironment
      terminal["WUHU_EXEC"] = nil
      terminal["WUHU_IDENTITY"] = "wallet"
      let listed = await h.run(["ls", "/"], environment: terminal)
      #expect(listed.code == 0, "\(listed.stderr)")
      #expect(listed.stderr.isEmpty, "no announcement outside a session's exec")
      #expect(!listed.hosts.isEmpty && listed.hosts.allSatisfy { $0 == "elsewhere.test" })
      let user = await h.run(["user", "list"], environment: ["HOME": h.home.path])
      #expect(user.code == 0, "\(user.stderr)")
    }
  }

  @Test func aSessionCreatesAChildTaskOpensARequestAndSendsAsItself() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      let created = await h.asSession(["session", "create", "helper"])
      #expect(created.code == 0, "\(created.stderr)")
      let id = SessionID(created.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
      let record = try await h.store.record(id)
      #expect(record.kind == .task)
      #expect(record.parent == h.parent)

      let requested = await h.asSession(["session", "request", "--deadline", "600", id.rawValue, "do the thing"])
      #expect(requested.code == 0, "\(requested.stderr)")
      #expect(requested.stdout.hasPrefix("requested "))
      let stranger = await h.asSession(["session", "request", h.stranger.rawValue, "do the thing"])
      #expect(stranger.code == 1)

      let top = await h.asSession(["session", "create", "--kind", "agent", "--top-level", "peer"])
      #expect(top.code == 0, "\(top.stderr)")
      let peer = try await h.store.record(SessionID(top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
      #expect(peer.parent == nil)

      let sent = await h.asSession(["send", h.child.rawValue, "hello"])
      #expect(sent.code == 0, "\(sent.stderr)")
      let conversation = try #require(sent.stdout.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
      let message = try #require(try await h.store.messages(conversation: ConversationID(conversation)).last)
      #expect(message.sender.id == h.parent.rawValue)

      let wait = await h.asSession(["send", "--wait", h.child.rawValue, "hello"])
      #expect(wait.code == 1)
      #expect(wait.stderr == "send --wait: \(sessionRefusal)\n")
      #expect(wait.hosts.isEmpty)

      let wallet = await h.run(["session", "request", id.rawValue, "x"], environment: ["HOME": h.home.path])
      #expect(wallet.code == 64)
    }
  }

  @Test func localOnlyVerbsAreRefusedBeforeAnyTraffic() async throws {
    try await withIdentityDeps {
      let h = try await IdentityHarness()
      for arguments in [["models", "update"], ["use", "elsewhere.test"], ["login"], ["machine", "add"], ["auth", "list"], ["key", "list"]] {
        let refused = await h.asSession(arguments)
        #expect(refused.code == 1, "\(arguments)")
        #expect(refused.stderr == sessionRefusal + "\n", "\(arguments)")
        #expect(refused.hosts.isEmpty, "\(arguments)")
      }
      let server = await h.asSession(["secret", "list"])
      #expect(server.code == 1)
      #expect(server.stderr.contains(sessionRefusal))
    }
  }
}
