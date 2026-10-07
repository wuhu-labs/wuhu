#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Clocks
import Dependencies
import Fetch
import JSONValue
import protocol MachineChannel.FrameTransport
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import Scratch
import struct SpaceClient.ExecSession
import struct SpaceClient.SpaceClient
import Testing

@Suite struct GroupSelectionTests {
  @Test func noSelectionSendsTheSameRequestAsBefore() async throws {
    let h = try GroupHarness(features: nil)
    let result = await h.run(["ls", "/"])
    #expect(result.code == 0, "\(result.stderr)")
    let requests = await h.recorder.requests
    #expect(requests.count == 1, "no /v1/server probe without a selection")
    let sent = try #require(requests.first)
    #expect(sent.headers["wuhu-group"] == nil)

    let baseline = Recorder { _ in try Response.json(listing) }
    let bare = SpaceClient(space: "127.0.0.1:5530", fetch: FetchClient { try await baseline.fetch($0) })
    let _: JSONValue = try await bare.tool("ls", ["path": "/"])
    let expected = try #require(await baseline.requests.first)
    #expect(sent.method == expected.method)
    #expect(sent.url == expected.url)
    #expect(sent.headers.values == expected.headers.values)
    #expect(sent.headers.sensitiveValues == expected.headers.sensitiveValues)
    #expect(sent.body?.contentType == expected.body?.contentType)
    #expect(try await (sent.body ?? .empty).text() == (expected.body ?? .empty).text())
  }

  enum Source: CaseIterable {
    case flag, environment, config
  }

  @Test(arguments: Source.allCases)
  func aSelectionActsInItsGroup(source: Source) async throws {
    let h = try GroupHarness(features: ["groups"], configGroup: source == .config ? "alice" : nil)
    let result = switch source {
    case .flag: await h.run(["--group", "alice", "ls", "/"])
    case .environment: await h.run(["ls", "/"], environment: ["WUHU_GROUP": "alice"])
    case .config: await h.run(["ls", "/"])
    }
    #expect(result.code == 0, "\(result.stderr)")
    let requests = await h.recorder.requests
    #expect(requests.map(\.url.path) == ["/v1/server", "/v1/tools/ls"])
    #expect(requests.first?.headers["wuhu-group"] == nil, "the feature probe acts in no group")
    #expect(requests.last?.headers["wuhu-group"] == "alice")
    let hosts = Set(requests.map { "\($0.url.host ?? ""):\($0.url.port ?? 0)" })
    #expect(hosts == ["127.0.0.1:5530"], "the group never enters the host")
  }

  @Test func theFlagBeatsTheEnvironmentWhichBeatsTheConfig() throws {
    let config = "carol"
    let both = ["WUHU_GROUP": "bob"]
    let flag = try GroupSelection.resolve(flag: "alice", environment: both, config: config)
    #expect(flag.group == "alice" && flag.source == .flag)
    let environment = try GroupSelection.resolve(flag: nil, environment: both, config: config)
    #expect(environment.group == "bob" && environment.source == .environment)
    let configured = try GroupSelection.resolve(flag: nil, environment: [:], config: config)
    #expect(configured.group == "carol" && configured.source == .config)
    #expect(try GroupSelection.resolve(flag: nil, environment: ["WUHU_GROUP": ""], config: nil) == .none)
    #expect(throws: UsageError.self) { try GroupSelection.resolve(flag: "Alice", environment: [:], config: nil) }
    #expect(throws: UsageError.self) { try GroupSelection.resolve(flag: "a--b", environment: [:], config: nil) }
  }

  @Test(arguments: [nil, [String]()] as [[String]?])
  func aSelectionAgainstAServerWithoutGroupsIsRefused(features: [String]?) async throws {
    let h = try GroupHarness(features: features)
    let result = await h.run(["--group", "alice", "ls", "/"])
    #expect(result.code == 1)
    #expect(result.stderr.contains("this server has no groups; alice comes from --group"), "\(result.stderr)")
    #expect(await h.recorder.requests.map(\.url.path) == ["/v1/server"])
  }

  @Test func aFailedProbeIsReportedAsItself() async throws {
    let h = try GroupHarness(features: ["groups"], serverFails: true)
    let result = await h.run(["ls", "/"], environment: ["WUHU_GROUP": "alice"])
    #expect(result.code == 1)
    #expect(result.stderr.contains("HTTP 502"), "\(result.stderr)")
    #expect(!result.stderr.contains("no groups"))
    #expect(await h.recorder.requests.map(\.url.path) == ["/v1/server"])
  }

  @Test(arguments: ["1", "0", "true"])
  func anyNonEmptyWuhuExecIsAnExec(value: String) async throws {
    let h = try GroupHarness(features: ["groups"])
    var environment = h.execEnvironment
    environment["WUHU_EXEC"] = value
    let refused = await h.run(["--group", "alice", "ls", "/"], environment: environment)
    #expect(refused.code == 1)
    #expect(refused.stderr.contains("--group is refused in a session's exec"), "\(refused.stderr)")

    let empty = await h.run(["--group", "alice", "ls", "/"], environment: ["WUHU_EXEC": ""])
    #expect(empty.code == 0, "an empty WUHU_EXEC is unset: \(empty.stderr)")
  }

  @Test func serveAndUserRunInAnExec() async throws {
    let h = try GroupHarness(features: ["groups"])
    let served = await h.run(["serve", "/tmp/space"], environment: h.execEnvironment)
    #expect(served.code == 0, "\(served.stderr)")
    #expect(await h.local.calls == ["serve /tmp/space"])
    let user = await h.run(["user", "add", "--space", "/tmp/space"], environment: h.execEnvironment)
    #expect(user.code == 0, "\(user.stderr)")
    #expect(await h.local.calls == ["serve /tmp/space", "user"])
    #expect(await h.recorder.requests.isEmpty)

    let refused = await h.run(["user", "list"], environment: h.execEnvironment)
    #expect(refused.stderr == sessionRefusal + "\n")
  }

  @Test func rePinningTheSameSpaceKeepsItsGroup() async throws {
    let h = try GroupHarness(features: ["groups"], configGroup: "alice")
    let same = await h.run(["use", "127.0.0.1:5530"])
    #expect(same.code == 0, "\(same.stderr)")
    #expect(same.stdout.hasPrefix("pinned 127.0.0.1:5530 -> \(h.wallet.path) in group alice"))
    #expect(try h.configJSON() == ["space": "127.0.0.1:5530", "group": "alice"])

    let respelled = await h.run(["use", "https://127.0.0.1:5530/"])
    #expect(respelled.code == 0, "\(respelled.stderr)")
    #expect(respelled.stderr.isEmpty)
    #expect(try h.configJSON()["group"] == "alice", "the same server, spelled differently, keeps its group")

    let other = await h.run(["use", "127.0.0.1:6000"])
    #expect(other.code == 0, "\(other.stderr)")
    #expect(other.stderr == "note: cleared the group alice: it belongs to https://127.0.0.1:5530/\n")
    #expect(try h.configJSON() == ["space": "127.0.0.1:6000"])
  }

  @Test func anInvalidConfiguredGroupBlocksOnlyTheVerbsThatUseIt() async throws {
    let h = try GroupHarness(features: ["groups"], configGroup: "Not A Group")
    let blocked = await h.run(["ls", "/"])
    #expect(blocked.code == 64)
    #expect(blocked.stderr.contains("Not A Group (from .wuhu/config.json) is not a group id"), "\(blocked.stderr)")

    let clear = await h.run(["group", "use", "--clear"])
    #expect(clear.code == 0, "\(clear.stderr)")
    #expect(try h.configJSON() == ["space": "127.0.0.1:5530"])

    let broken = try GroupHarness(features: ["groups"], configGroup: "Not A Group")
    let chosen = await broken.run(["group", "use", "alice"])
    #expect(chosen.code == 0, "\(chosen.stderr)")
    #expect(try broken.configJSON()["group"] == "alice")

    let repinned = try GroupHarness(features: ["groups"], configGroup: "Not A Group")
    let use = await repinned.run(["use", "127.0.0.1:5530"])
    #expect(use.code == 0, "\(use.stderr)")
    #expect(try repinned.configJSON() == ["space": "127.0.0.1:5530"], "use drops the invalid group")
    #expect(use.stderr == "note: cleared the group Not A Group: not a group id\n")
  }

  enum ExecAttempt: CaseIterable {
    case flag, environment
  }

  @Test(arguments: ExecAttempt.allCases)
  func aSessionExecCannotOverrideItsGroup(attempt: ExecAttempt) async throws {
    let h = try GroupHarness(features: ["groups"])
    var environment = h.execEnvironment
    var arguments = ["ls", "/"]
    let message: String
    switch attempt {
    case .flag:
      arguments = ["--group", "alice"] + arguments
      message = "--group is refused in a session's exec"
    case .environment:
      environment["WUHU_GROUP"] = "alice"
      message = "WUHU_GROUP is refused in a session's exec"
    }
    let result = await h.run(arguments, environment: environment)
    #expect(result.code == 1)
    #expect(result.stderr.contains(message), "\(result.stderr)")
    #expect(await h.recorder.requests.isEmpty)
  }

  @Test(arguments: Source.allCases)
  func aWalletOptInUsesTheNormalGroupSelection(source: Source) async throws {
    let h = try GroupHarness(features: ["groups"], configGroup: "carol")
    var environment = h.execEnvironment
    environment["WUHU_IDENTITY"] = "wallet"
    var arguments = ["ls", "/"]
    switch source {
    case .flag:
      arguments = ["--group", "alice"] + arguments
      environment["WUHU_GROUP"] = "bob"
    case .environment:
      environment["WUHU_GROUP"] = "alice"
    case .config:
      break
    }
    let result = await h.run(arguments, environment: environment)
    #expect(result.code == 0, "\(result.stderr)")
    #expect(result.stderr == "acting as anonymous (wallet)\n")
    let requests = await h.recorder.requests
    #expect(requests.map(\.url.path) == ["/v1/server", "/v1/tools/ls"])
    #expect(requests.last?.headers["wuhu-group"] == (source == .config ? "carol" : "alice"))
    #expect(requests.allSatisfy { $0.headers["authorization"] == nil })
  }

  @Test func aWalletOptInDoesNotDropAnUnsupportedOrInvalidGroup() async throws {
    let h = try GroupHarness(features: nil)
    let environment = h.execEnvironment.merging(["WUHU_IDENTITY": "wallet"]) { $1 }
    let unsupported = await h.run(["--group", "alice", "ls", "/"], environment: environment)
    #expect(unsupported.code == 1)
    #expect(unsupported.stderr.contains("this server has no groups"))
    #expect(await h.recorder.requests.map(\.url.path) == ["/v1/server"])
    let invalid = await h.run(["--group", "Alice", "ls", "/"], environment: environment)
    #expect(invalid.code == 64)
    #expect(invalid.stderr.contains("is not a group id"))
  }

  @Test func anExecIgnoresTheConfiguredGroup() async throws {
    let h = try GroupHarness(features: ["groups"], configGroup: "alice")
    let result = await h.run(["ls", "/"], environment: h.execEnvironment)
    #expect(result.code == 0, "\(result.stderr)")
    let requests = await h.recorder.requests
    #expect(requests.map(\.url.path) == ["/v1/tools/ls"])
    #expect(requests.first?.headers["wuhu-group"] == nil)
  }

  @Test func tokensAndCursorsKeepTheirKeysWithoutAGroup() throws {
    let directory = try scratchURL("wallet")
    defer { try? FileManager.default.removeItem(at: directory) }
    var plain = Wallet(directory: directory)
    try plain.record(token: "t1", space: "127.0.0.1:5530", path: "/a")
    try plain.advanceInboxCursor(3, space: "127.0.0.1:5530")
    var grouped = Wallet(directory: directory)
    grouped.group = "alice"
    try grouped.record(token: "t2", space: "127.0.0.1:5530", path: "/a")
    try grouped.advanceInboxCursor(5, space: "127.0.0.1:5530")

    let etags = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("etags.json")))
    #expect(etags == ["127.0.0.1:5530|/a": "t1", "127.0.0.1:5530|alice|/a": "t2"])
    let inbox = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("inbox.json")))
    #expect(inbox == ["127.0.0.1:5530": 5], "one inbox cursor per space, whatever the group")
    #expect(plain.inboxCursor(space: "127.0.0.1:5530") == 5)
    #expect(try plain.token(space: "127.0.0.1:5530", path: "/a") == "t1")
    #expect(try grouped.token(space: "127.0.0.1:5530", path: "/a") == "t2")
    #expect(plain.observationState(space: "127.0.0.1:5530", mode: .glob("/**")) != grouped.observationState(space: "127.0.0.1:5530", mode: .glob("/**")))
  }

  @Test func aPerGroupCursorAnOlderCLIKeptStillCountsAndFoldsIntoOne() throws {
    let directory = try scratchURL("wallet")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacy = ["127.0.0.1:5530": 3, "127.0.0.1:5530|alice": 7, "other:5530|bob": 9]
    try JSONEncoder().encode(legacy).write(to: directory.appendingPathComponent("inbox.json"))
    var wallet = Wallet(directory: directory)
    #expect(wallet.inboxCursor(space: "127.0.0.1:5530") == 7)
    try wallet.advanceInboxCursor(8, space: "127.0.0.1:5530")
    let inbox = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: directory.appendingPathComponent("inbox.json")))
    #expect(inbox == ["127.0.0.1:5530": 8, "other:5530|bob": 9])
  }

  @Test func oneInboxSpansTheGroupsAndSwitchingGroupReplaysNothing() async throws {
    let h = try GroupHarness(features: ["groups"], groups: ["alice"], notifications: [
      [
        "n": 1, "recipient": "prs_me", "source": "dm_1", "kind": "conversation_message", "createdAt": 0, "group": "shared",
        "payload": ["messageID": "m1", "conversationID": "dm_1", "sender": "prs_bob", "senderGroup": "alice", "text": "hi"],
      ],
      [
        "n": 2, "recipient": "prs_me", "source": "s1", "kind": "session_errored", "createdAt": 0, "group": "alice",
        "payload": ["sessionID": "s1", "error": "boom"],
      ],
    ])
    let first = await h.run(["inbox"])
    #expect(first.code == 0, "\(first.stderr)")
    #expect(first.stdout == """
    [1] group shared · message from prs_bob (group alice) in dm_1: hi
    [2] group alice · session s1 errored: boom

    """)

    let switched = await h.run(["--group", "alice", "inbox"])
    #expect(switched.code == 0, "\(switched.stderr)")
    #expect(switched.stdout == "", "the read position is the person's, not the group's")
    let asked = await h.recorder.requests.filter { $0.url.path == "/v1/notifications" }.map { $0.url.query ?? "" }
    #expect(asked == ["after=0", "after=2"])
  }

  @Test func groupUseWritesTheConfigAndClearDropsTheKey() async throws {
    let h = try GroupHarness(features: ["groups"], groups: ["alice", "bob"])
    let use = await h.run(["group", "use", "bob"])
    #expect(use.code == 0, "\(use.stderr)")
    #expect(use.stdout == "group bob -> \(h.config.path)\n")
    #expect(try h.configJSON() == ["space": "127.0.0.1:5530", "group": "bob"])
    #expect(await h.recorder.requests.last?.headers["wuhu-group"] == nil, "the group list is read in no group")

    let current = await h.run(["group", "current"])
    #expect(current.stdout == "bob (.wuhu/config.json)\n")

    let overridden = await h.run(["group", "use", "alice"], environment: ["WUHU_GROUP": "bob"])
    #expect(overridden.code == 0, "\(overridden.stderr)")
    #expect(overridden.stderr == "note: WUHU_GROUP still overrides it\n")

    let missing = await h.run(["group", "use", "carol"])
    #expect(missing.code == 1)
    #expect(missing.stderr.contains("127.0.0.1:5530 has no group carol"))
    #expect(try h.configJSON()["group"] == "alice")

    let clear = await h.run(["group", "use", "--clear"])
    #expect(clear.code == 0, "\(clear.stderr)")
    #expect(clear.stdout == "cleared the group -> \(h.config.path)\n")
    #expect(try h.configJSON() == ["space": "127.0.0.1:5530"])
  }

  @Test func groupListAndCurrentWithoutASelection() async throws {
    let h = try GroupHarness(features: ["groups"], groups: ["alice", "bob"], serverGroup: "alice")
    let list = await h.run(["group", "list"])
    #expect(list.code == 0, "\(list.stderr)")
    #expect(list.stdout == "alice\nbob\n")
    let current = await h.run(["group", "current"])
    #expect(current.stdout == "alice (the server's default)\n")

    let plain = try GroupHarness(features: nil)
    let none = await plain.run(["group", "current"])
    #expect(none.stdout == "none (this server has no groups)\n")
  }

  @Test func useRecordsTheGroupItChecked() async throws {
    let h = try GroupHarness(features: ["groups"], groups: ["alice"], configGroup: nil, pinned: false)
    let pinned = await h.run(["use", "127.0.0.1:5530", "--group", "alice"])
    #expect(pinned.code == 0, "\(pinned.stderr)")
    #expect(pinned.stdout.hasPrefix("pinned 127.0.0.1:5530 -> \(h.wallet.path) in group alice"))
    #expect(try h.configJSON() == ["space": "127.0.0.1:5530", "group": "alice"])

    let unknown = await h.run(["use", "127.0.0.1:5530", "--group", "bob"])
    #expect(unknown.code == 1)
    #expect(try h.configJSON()["group"] == "alice", "a refused group pins nothing")

    let noGroups = try GroupHarness(features: nil, pinned: false)
    let refused = await noGroups.run(["use", "127.0.0.1:5530", "--group", "alice"])
    #expect(refused.code == 1)
    #expect(refused.stderr.contains("this server has no groups"))
  }

  @Test func theGlobalFlagParsesBeforeTheVerb() throws {
    #expect(try Invocation.parse(["--group", "alice", "ls", "/"]).group == "alice")
    #expect(try Invocation.parse(["ls", "/"]).group == nil)
    #expect(throws: UsageError.self) { try Invocation.parse(["--group"]) }
    #expect(throws: UsageError.self) { try Invocation.parse(["--group", "a", "--group", "b", "ls"]) }
    #expect(throws: UsageError.self) { try Invocation.parse(["--group", "a", "use", "h:1"]) }
    #expect(try Command.parse(["use", "h:1", "--group", "alice"]) == .use("h:1", pin: false, group: "alice"))
    #expect(try Command.parse(["group", "list"]) == .groupList)
    #expect(try Command.parse(["group", "use", "alice"]) == .groupUse("alice"))
    #expect(try Command.parse(["group", "use", "--clear"]) == .groupUse(nil))
    #expect(try Command.parse(["group", "current"]) == .groupCurrent)
    #expect(throws: UsageError.self) { try Command.parse(["group", "use"]) }
  }

  @Test func theGroupReachesEveryTransport() async throws {
    let fetched = Recorder { _ in try Response.json(JSONValue.object([:])) }
    let observed = Recorder { _ in throw Unreachable() }
    let dialed = DialRecorder()
    let client = SpaceClient(
      space: "127.0.0.1:5530",
      fetch: FetchClient { try await fetched.fetch($0) },
      observeFetch: FetchClient { try await observed.fetch($0) },
      dial: { url, headers in try await dialed.dial(url, headers) },
      group: "alice",
    )
    let _: JSONValue = try await client.api(.get, "/v1/server")
    _ = try? await client.sse("/v1/observe")
    let start = ExecStart(id: ExecID(rawValue: "ex_abcdefgh"), cwd: "/", command: ["true"], env: nil, secrets: nil, window: nil, maxOutput: nil, timeout: nil)
    _ = try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      try await ExecSession(client: client, start: start).run(input: nil) { _, _ in }
    }
    #expect(await fetched.requests.first?.headers["wuhu-group"] == "alice")
    #expect(await observed.requests.first?.headers["wuhu-group"] == "alice")
    let dials = await dialed.headers
    #expect(!dials.isEmpty)
    let groups: [[String]] = dials.map { headers in headers.filter { $0.0 == "wuhu-group" }.map(\.1) }
    #expect(groups.allSatisfy { $0 == ["alice"] })
  }
}

private let listing: JSONValue = ["rev": 1, "entries": []]

private struct Unreachable: Error {}

private actor DialRecorder {
  var headers: [[(String, String)]] = []

  func dial(_ url: URL, _ headers: [(String, String)]) throws -> any FrameTransport {
    self.headers.append(headers)
    throw Unreachable()
  }
}

private actor Recorder {
  var requests: [Request] = []
  private let responder: @Sendable (Request) async throws -> Response

  init(responder: @escaping @Sendable (Request) async throws -> Response) {
    self.responder = responder
  }

  func fetch(_ request: Request) async throws -> Response {
    self.requests.append(request)
    return try await self.responder(request)
  }
}

private actor LocalVerbs {
  var calls: [String] = []

  func record(_ call: String) {
    self.calls.append(call)
  }
}

private actor TextSink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}

// A space at 127.0.0.1:5530 with no device keys: no bearer, so the requests are
// exactly what the CLI builds. /v1/server advertises `features` when given.
private struct GroupHarness {
  let recorder: Recorder
  let local = LocalVerbs()
  let scratch: ScratchFolder
  let home: URL
  let cwd: URL
  var wallet: URL { self.cwd.appendingPathComponent(".wuhu", isDirectory: true) }
  var config: URL { self.wallet.appendingPathComponent("config.json") }
  let execEnvironment: [String: String]

  init(
    features: [String]?,
    groups: [String] = ["alice"],
    serverGroup: String? = nil,
    serverFails: Bool = false,
    configGroup: String? = nil,
    pinned: Bool = true,
    notifications: [JSONValue] = [],
  ) throws {
    self.scratch = try ScratchFolder("groups")
    let root = self.scratch.url
    self.home = root.appendingPathComponent("home", isDirectory: true)
    self.cwd = root.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: self.cwd, withIntermediateDirectories: true)
    self.execEnvironment = [
      "WUHU_EXEC": "1",
      "WUHU_TOKEN": "exec-token",
      "WUHU_SPACE_URL": "http://127.0.0.1:5530",
    ]
    if pinned {
      var config: JSONValue = ["space": "127.0.0.1:5530"]
      config.set("group", configGroup.map { JSONValue.string($0) })
      try FileManager.default.createDirectory(at: self.cwd.appendingPathComponent(".wuhu"), withIntermediateDirectories: true)
      try Data(config.jsonString().utf8).write(to: self.cwd.appendingPathComponent(".wuhu/config.json"))
    }
    self.recorder = Recorder { request in
      switch request.url.path {
      case "/v1/server":
        if serverFails {
          return Response(status: .badGateway, body: .chunk(Data("<html>bad gateway</html>".utf8), contentType: "text/html"))
        }
        var info: JSONValue = [:]
        if let features {
          let values: [JSONValue] = features.map { JSONValue.string($0) }
          info.set("features", JSONValue.array(values))
          let group: String? = request.headers["wuhu-group"] ?? serverGroup
          info.set("group", group.map { JSONValue.string($0) })
        }
        return try Response.json(info)
      case "/v1/groups":
        let values: [JSONValue] = groups.map { id in JSONValue.object(["id": JSONValue.string(id)]) }
        return try Response.json(JSONValue.array(values))
      case "/v1/notifications":
        // Every group's rows, whatever the Wuhu-Group header: the server's
        // inbox is the person's.
        let after = request.url.query.flatMap { Int($0.replacingOccurrences(of: "after=", with: "")) } ?? 0
        let rows = notifications.filter { ($0.object?["n"]?.intValue ?? 0) > after }
        return try Response.json(JSONValue.object(["notifications": JSONValue.array(rows)]))
      default:
        return try Response.json(listing)
      }
    }
  }

  func run(_ arguments: [String], environment: [String: String] = [:]) async -> (code: Int32, stdout: String, stderr: String) {
    let stdout = TextSink()
    let stderr = TextSink()
    let recorder = self.recorder
    let local = self.local
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      serve: { config in await local.record("serve \(config.folder)") },
      user: { _ in
        await local.record("user")
        return (output: "", note: nil)
      },
      stdin: { "" },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: environment.merging(["HOME": self.home.path, "TMPDIR": self.scratch.path]) { $1 },
      currentDirectory: self.cwd.path,
    )
    // The certificate check is `use`'s, and this fake has no certificate.
    let code = await withDependencies {
      $0[ServerTrustProbe.self] = ServerTrustProbe(validateSystem: { _, _ in }, observeLeaf: { _, _ in throw Unreachable() })
    } operation: {
      await runner.run(arguments: arguments)
    }
    return (code, await stdout.text, await stderr.text)
  }

  func configJSON() throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(contentsOf: self.config))
  }
}
