#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Dependencies
import Fetch
import JSONValue
import enum PinnedTLS.PinnedTLS
import Scratch
import SpaceContract
import Synchronization
import Testing

@Suite
struct RequestMappingTests {
  @Test func mapsEveryToolVerb() async throws {
    try await assertRequest(["read", "/a", "--rev", "2", "--lines", "1-3"], response: .object(["token": "t1", "content": "hello"])) { request in
      #expect(request.method == .post)
      #expect(request.url.path == "/v1/tools/read")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a", "rev": 2, "lines": "1-3"])
    }

    try await assertRequest(["write", "--force", "/a", "--body", "body"], response: .object(["rev": 1, "token": "t2"])) { request in
      #expect(request.url.path == "/v1/tools/write")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a", "content": "body"])
    }

    try await assertRequest(["edit", "--force", "/a", "old", "new"], response: .object(["rev": 2, "token": "t3"])) { request in
      #expect(request.url.path == "/v1/tools/edit")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a", "edits": [["old": "old", "new": "new"]]])
    }

    try await assertRequest(["rm", "--force", "/a"], response: .object(["rev": 3])) { request in
      #expect(request.url.path == "/v1/tools/rm")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a"])
    }

    try await assertRequest(["mv", "/a", "/b"], response: .object(["rev": 4, "dangling": []])) { request in
      #expect(request.url.path == "/v1/tools/mv")
      let input = try await requestBodyJSON(request)
      #expect(input == ["from": "/a", "to": "/b"])
    }

    try await assertRequest(["mv", "/a", "/b", "--replace"], response: .object(["rev": 5, "dangling": []])) { request in
      let input = try await requestBodyJSON(request)
      #expect(input == ["from": "/a", "to": "/b", "replace": true])
    }

    try await assertRequest(["ls", "/", "--rev", "9"], response: .object(["rev": 9, "entries": []])) { request in
      #expect(request.url.path == "/v1/tools/ls")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/", "rev": 9])
    }

    try await assertRequest(["stat", "/a"], response: entryJSON(name: "a", token: "s1")) { request in
      #expect(request.url.path == "/v1/tools/stat")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a"])
    }

    try await assertRequest(["grep", "needle", "/", "--match-limit", "5", "--entry-limit", "7", "--step", "c"], response: .object(["matches": [], "cursor": .null])) { request in
      #expect(request.url.path == "/v1/tools/grep")
      let input = try await requestBodyJSON(request)
      #expect(input == ["pattern": "needle", "path": "/", "matchLimit": 5, "entryLimit": 7, "step": "c"])
    }

    try await assertRequest(["find", "**/*.md", "/notes"], response: .object(["paths": []])) { request in
      #expect(request.url.path == "/v1/tools/find")
      let input = try await requestBodyJSON(request)
      #expect(input == ["glob": "**/*.md", "path": "/notes"])
    }

    try await assertRequest(["history", "/a"], response: .object(["entries": []])) { request in
      #expect(request.url.path == "/v1/tools/history")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a"])
    }

    try await assertRequest(["checkout", "/a", "12"], response: .object(["rev": 13, "token": "c1"])) { request in
      #expect(request.url.path == "/v1/tools/checkout")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a", "rev": 12])
    }

    try await assertRequest(["query", "select 1"], response: .object(["columns": [], "rows": []])) { request in
      #expect(request.url.path == "/v1/tools/query")
      let input = try await requestBodyJSON(request)
      #expect(input == ["sql": "select 1"])
    }

    let headerJSON = "{\"columns\":[{\"name\":\"title\",\"type\":\"string\"}]}"
    try await assertRequest(["table", "create", "/t.table", headerJSON], response: .object(["rev": 1, "token": "1"])) { request in
      #expect(request.url.path == "/v1/tools/table.create")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/t.table", "header": ["columns": [["name": "title", "type": "string"]]]])
    }

    let alter = try Harness(response: ["rev": 2, "token": "2"])
    #expect(await alter.runner.run(arguments: ["table", "create", "/t.table", headerJSON]) == 0)
    #expect(await alter.runner.run(arguments: ["table", "alter", "/t.table", headerJSON, "--allow-drop-columns"]) == 0)
    let alterRequest = try #require(await alter.recorder.requests.last)
    #expect(alterRequest.url.path == "/v1/tools/table.alter")
    #expect(try await requestBodyJSON(alterRequest) == ["path": "/t.table", "header": ["columns": [["name": "title", "type": "string"]]], "ifMatch": "2", "allowDropColumns": true])

    let opsJSON = "[{\"kind\":\"insert\",\"values\":[\"a\",1]}]"
    try await assertRequest(["table", "mutate", "/t.table", opsJSON], response: .object(["rev": 3])) { request in
      #expect(request.url.path == "/v1/tools/table.mutate")
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/t.table", "ops": [["kind": "insert", "values": ["a", 1]]]])
    }

    try await assertRequest(["new", "/templates/day.md", "/days"], response: .object(["path": "/days/1.md"])) { request in
      #expect(request.url.path == "/v1/tools/new")
      let input = try await requestBodyJSON(request)
      #expect(input == ["template": "/templates/day.md", "in": "/days"])
    }
  }

  @Test func historyFollowsEveryPageCursorAndPrintsEachRevisionOnceInOrder() async throws {
    let inputs = Mutex<[JSONValue]>([])
    let harness = try Harness { request in
      #expect(request.method == .post)
      #expect(request.url.path == "/v1/tools/history")
      let input = try await requestBodyJSON(request)
      inputs.withLock { $0.append(input) }
      let output: JSONValue
      switch input {
      case ["path": "/a"]:
        output = ["entries": [["rev": 2, "mtime": 102, "change": "write"], ["rev": 6, "mtime": 106, "change": "delete"]], "next": 6]
      case ["path": "/a", "after": 6]:
        output = ["entries": [["rev": 7, "mtime": 107, "change": "checkout", "fromRev": 3], ["rev": 9, "mtime": 109, "change": "move", "to": "/renamed"]], "next": 9]
      case ["path": "/a", "after": 9]:
        output = ["entries": [["rev": 11, "mtime": 111, "change": "write"]], "next": .null]
      default:
        Issue.record("Unexpected history request: \(input)")
        output = ["entries": []]
      }
      return try Response.json(output)
    }
    #expect(await harness.runner.run(arguments: ["history", "/a"]) == 0)
    #expect(inputs.withLock { $0 } == [["path": "/a"], ["path": "/a", "after": 6], ["path": "/a", "after": 9]])
    #expect(await harness.recorder.requests.count == 3)
    #expect(await harness.stdout.text == "2 write 102\n6 delete 106\n7 checkout 107 fromRev=3\n9 move 109 to=/renamed\n11 write 111\n")
    #expect(await harness.stderr.text.isEmpty)
  }

  @Test func mapsObserveToGet() async throws {
    let harness = try Harness(response: .text("data: {\"ok\":true}\n\n"))
    let code = await harness.runner.run(arguments: ["observe", "--glob", "**/*.md", "--throttle-ms", "25"])
    #expect(code == 0)
    let requests = await harness.recorder.requests
    #expect(requests.count == 1)
    #expect(requests[0].method == .get)
    #expect(requests[0].url.path == "/v1/observe")
    #expect(requests[0].url.query?.contains("glob=") == true)
    #expect(requests[0].url.query?.contains("kind=glob") != true)
    #expect(requests[0].url.query?.contains("throttleMs=25") == true)
  }

  @Test func observeGlobForwardsCursorAndSqlRejectsIt() async throws {
    let harness = try Harness(response: .text("data: {\"ok\":true}\n\n"))
    #expect(await harness.runner.run(arguments: ["observe", "--glob", "/**", "--from", "12"]) == 0)
    let requests = await harness.recorder.requests
    #expect(requests.count == 1)
    #expect(requests[0].url.query?.contains("from=12") == true)

    let rejected = try Harness(response: .text(""))
    #expect(await rejected.runner.run(arguments: ["observe", "--sql", "SELECT 1", "--from", "12"]) != 0)
    #expect(await rejected.recorder.requests.isEmpty)
  }

  @Test func namingVerbsSendTheReferenceThroughUntouched() async throws {
    try await assertRequest(
      ["machine", "name", "studio", "Mac-Mini"],
      response: .object(["id": "mc_aaaaaaaa", "name": "mac-mini", "attached": false]),
    ) { request in
      #expect(request.method == .put)
      #expect(request.url.path == "/v1/machine/studio/name")
      let input = try await requestBodyJSON(request)
      #expect(input == ["name": "Mac-Mini"])
    }

    try await assertRequest(
      ["user", "handle", "Morgan", "--display-name", "Lee, Morgan"],
      response: .object(["id": "sail-clock-pepper", "handle": "morgan", "displayName": "Lee, Morgan"]),
    ) { request in
      #expect(request.method == .put)
      #expect(request.url.path == "/v1/user/me/profile")
      let input = try await requestBodyJSON(request)
      #expect(input == ["handle": "Morgan", "displayName": "Lee, Morgan"])
    }
  }

  @Test func namingVerbsParseIntoTheirCommands() throws {
    #expect(try Command.parse(["user", "profile"]) == .userProfile)
    #expect(try Command.parse(["user", "handle", "ali"]) == .userHandle(handle: "ali", displayName: nil))
    #expect(
      try Command.parse(["machine", "join", "https://box:1", "--name", "mini"])
        == .machineJoin(server: "https://box:1", fingerprint: nil, name: "mini"),
    )
    #expect(try Command.parse(["machine", "name", "mc_aaaaaaaa", "mini"]) == .machineName(machine: "mc_aaaaaaaa", name: "mini"))
    #expect(try Command.parse(["machine", "revoke", "mini"]) == .machineRevoke(id: "mini"))
    #expect(parseMachineAddress("machines://mini/tmp") == MachineAddress(machine: "mini", path: "/tmp"))
    #expect(parseMachineAddress("machines://mc_aaaaaaaa") == MachineAddress(machine: "mc_aaaaaaaa", path: "/"))
    #expect(parseMachineAddress("machines:///tmp") == nil)
    #expect(parseMachineAddress("/tmp") == nil)
    #expect(throws: (any Error).self) { try Command.parse(["machine", "name", "mini"]) }
    #expect(throws: (any Error).self) { try Command.parse(["user", "handle"]) }
  }

  @Test func rootAndVerbHelpExitZeroBeforeWalletResolution() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["--help"]) == 0)
    #expect(await harness.runner.run(arguments: ["stat", "--help"]) == 0)
    #expect(await harness.runner.run(arguments: ["observe", "--help"]) == 0)
    let output = await harness.stdout.text
    #expect(output.contains("use       pin"))
    #expect(output.contains("usage: wuhu stat <path>"))
    #expect(output.contains("glob: print the first event; sql: skip equal snapshot hashes"))
    #expect(await harness.stderr.text == "")
  }

  // The secret routes refuse every session, so their help names the person as
  // the CLI's admin and run_script as the agent's way in.
  @Test func secretHelpSaysTheCLIIsAPersonsAndAgentsUseRunScript() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["secret", "--help"]) == 0)
    let output = await harness.stdout.text
    #expect(!output.contains("a live top-level agent"))
    #expect(output.contains("through run_script (wuhu:secret set)"))
    #expect(output.contains("--secret ENV=NAME takes NAME from the store of the machine's group"))
  }
}

@Suite
struct WalletTests {
  @Test func useCreatesLocalWalletAndConfirmsWithPath() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    let code = await runTrusting(harness, ["use", "127.0.0.1:5530"])
    #expect(code == 0)
    let wallet = temp.cwd.appendingPathComponent(".wuhu", isDirectory: true)
    let text = try String(contentsOf: wallet.appendingPathComponent("config.json"), encoding: .utf8)
    #expect(text.contains("127.0.0.1:5530"))
    let confirmation = await harness.stdout.text
    #expect(confirmation.hasPrefix("pinned 127.0.0.1:5530 -> \(wallet.path)"))
    // Anonymous seats have no persona: minting takes an enrolled device key.
    #expect(!FileManager.default.fileExists(atPath: wallet.appendingPathComponent("personas.json").path))
    #expect(!FileManager.default.fileExists(atPath: temp.home.appendingPathComponent(".wuhu").path))
  }

  @Test func useUpdatesAncestorWallet() async throws {
    let temp = try TemporaryDirectory()
    let ancestor = temp.root.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: true)
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await runTrusting(harness, ["use", "127.0.0.1:6650"]) == 0)
    let text = try String(contentsOf: ancestor.appendingPathComponent("config.json"), encoding: .utf8)
    #expect(text.contains("127.0.0.1:6650"))
    let ancestorConfirmation = await harness.stdout.text
    #expect(ancestorConfirmation.hasPrefix("pinned 127.0.0.1:6650 -> \(ancestor.path)"))
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu").path))
  }

  @Test func useNeverWritesHomeWalletEvenWhenWalkUpFindsIt() async throws {
    let temp = try TemporaryDirectory(cwdUnderHome: true)
    let homeWallet = temp.home.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: homeWallet, withIntermediateDirectories: true)
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await runTrusting(harness, ["use", "127.0.0.1:6650"]) == 0)
    #expect(!FileManager.default.fileExists(atPath: homeWallet.appendingPathComponent("config.json").path))
    let local = temp.cwd.appendingPathComponent(".wuhu", isDirectory: true)
    let text = try String(contentsOf: local.appendingPathComponent("config.json"), encoding: .utf8)
    #expect(text.contains("127.0.0.1:6650"))
    let localConfirmation = await harness.stdout.text
    #expect(localConfirmation.hasPrefix("pinned 127.0.0.1:6650 -> \(local.path)"))
  }

  @Test func useFailedWriteExitsNonzeroWithNoSuccessLine() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let config = temp.cwd.appendingPathComponent(".wuhu/config.json")
    try FileManager.default.removeItem(at: config)
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await runTrusting(harness, ["use", "127.0.0.1:6650"]) != 0)
    #expect(await harness.stdout.text == "")
  }

  @Test func readAndStatRecordTokens() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp) { request in
      if request.url.path == "/v1/tools/read" {
        return try Response.json(JSONValue.object(["token": "r1", "content": "text"]))
      }
      return try Response.json(entryJSON(name: "a", token: "s1"))
    }
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 0)
    #expect(await harness.runner.run(arguments: ["stat", "/a"]) == 0)
    let etags = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: temp.cwd.appendingPathComponent(".wuhu/etags.json")))
    #expect(etags["127.0.0.1:5530|/a"] == "s1")
  }

  @Test func writeUsesRecordedToken() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    try writeJSON(["127.0.0.1:5530|/a": "known"], to: temp.cwd.appendingPathComponent(".wuhu/etags.json"))
    let harness = try Harness(temp: temp, response: .object(["rev": 1, "token": "next"]))
    #expect(await harness.runner.run(arguments: ["write", "/a", "--body", ""]) == 0)
    let request = await harness.recorder.requests.first
    let input = try await requestBodyJSON(try #require(request))
    #expect(input == ["path": "/a", "content": "", "ifMatch": "known"])
  }

  @Test func writeRefusesUntrackedExistingPath() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: entryJSON(name: "a", token: "exists"))
    let code = await harness.runner.run(arguments: ["write", "/a", "--body", ""])
    #expect(code == 1)
    #expect(await harness.stderr.text == "refusing to overwrite /a: read it first, or pass --force\n")
    let requests = await harness.recorder.requests
    #expect(requests.map(\.url.path) == ["/v1/tools/stat"])
  }

  @Test func forceWriteSkipsPreflightAndIfMatch() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .object(["rev": 1, "token": "next"]))
    #expect(await harness.runner.run(arguments: ["write", "--force", "/a", "--body", ""]) == 0)
    let requests = await harness.recorder.requests
    #expect(requests.map(\.url.path) == ["/v1/tools/write"])
    let input = try await requestBodyJSON(requests[0])
    #expect(input == ["path": "/a", "content": ""])
  }

  @Test func barePathWithoutPinIsUsageError() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    let code = await harness.runner.run(arguments: ["read", "/a"])
    #expect(code == 64)
    #expect(await harness.stderr.text == "no space pinned; run: wuhu use <host:port>\n")
  }

  @Test func explicitHostRoutesWithoutPinnedSpace() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "wuhu://example.test:5530/a"]) == 0)
    let request = try #require(await harness.recorder.requests.first)
    #expect(request.url.host == "example.test")
    #expect(request.url.port == 5530)
    #expect(try await requestBodyJSON(request) == ["path": "/a"])
  }

  @Test func theSystemHostGoesToThePinnedSpaceAsAPath() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "wuhu://system/AGENTS.md"]) == 0)
    #expect(await harness.runner.run(arguments: ["read", "wuhu://system"]) == 0)
    let requests = await harness.recorder.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.url.host != "system" })
    #expect(try await requestBodyJSON(requests[0]) == ["path": "wuhu://system/AGENTS.md"])
    #expect(try await requestBodyJSON(requests[1]) == ["path": "wuhu://system"])
  }

  @Test func aLocalGroupAddressIsAPathOfThePinnedSpaceForEveryFileVerb() async throws {
    #expect(try routePath("wuhu://shared.localspace/notes.md") == RoutedPath(spaceOverride: nil, path: "wuhu://shared.localspace/notes.md"))
    #expect(try routePath("WUHU://Team-1.LocalSpace/a") == RoutedPath(spaceOverride: nil, path: "WUHU://Team-1.LocalSpace/a"))
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    let address = "wuhu://shared.localspace/notes/a.md"
    let verbs: [[String]] = [
      ["read", address], ["stat", address], ["history", address], ["ls", "wuhu://shared.localspace/notes"],
      ["find", "*.md", "wuhu://shared.localspace/notes"], ["grep", "x", address], ["checkout", address, "3"],
      ["new", "wuhu://shared.localspace/templates/T.md"], ["rm", "--force", address],
    ]
    for arguments in verbs {
      _ = await harness.runner.run(arguments: arguments)
    }
    let requests = await harness.recorder.requests
    #expect(requests.count == verbs.count)
    #expect(requests.allSatisfy { $0.url.host != "shared.localspace" })
    for request in requests {
      let body = try await requestBodyJSON(request)
      let named = body.object?["path"]?.stringValue ?? body.object?["template"]?.stringValue
      #expect(named?.hasPrefix("wuhu://shared.localspace/") == true, "\(request.url)")
    }
  }

  @Test func catAndPutCarryALocalGroupAsAQuery() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let recorder = Recorder { _ in Response(status: .ok, body: .bytes(Data("x".utf8), contentType: "text/plain")) }
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { "" },
      stdout: { _ in },
      stderr: { _ in },
      stdoutBytes: { _ in },
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
    #expect(await runner.run(arguments: ["cat", "wuhu://team.localspace/logo.png"]) == 0)
    let request = try #require(await recorder.requests.first)
    #expect(request.url.host != "team.localspace")
    #expect(request.url.path == "/v1/f/logo.png")
    #expect(request.url.query == "group=team")
  }

  @Test func theSystemHostWithAPortIsASpace() async throws {
    #expect(try routePath("wuhu://system:5530/notes.md") == RoutedPath(spaceOverride: "system:5530", path: "/notes.md"))
    #expect(try routePath("https://system:5530/notes.md") == RoutedPath(spaceOverride: "system:5530", path: "/notes.md"))
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "wuhu://system:5530/notes.md"]) == 0)
    let request = try #require(await harness.recorder.requests.first)
    #expect(request.url.host == "system")
    #expect(request.url.port == 5530)
    #expect(try await requestBodyJSON(request) == ["path": "/notes.md"])
  }

  @Test func aShareLinkRoutesLikeItsWuhuTwin() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "https://example.test:5530/notes/My%20Plan.md"]) == 0)
    let request = try #require(await harness.recorder.requests.first)
    #expect(request.url.host == "example.test")
    #expect(request.url.port == 5530)
    #expect(try await requestBodyJSON(request) == ["path": "/notes/My Plan.md"])
    #expect(await harness.runner.run(arguments: ["read", "https://example.test:5530/_/sessions/s1"]) == 64)
    #expect(await harness.recorder.requests.count == 1)
  }

  @Test func historicalReadDoesNotRecordToken() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .object(["token": "old", "content": "past"]))
    #expect(await harness.runner.run(arguments: ["read", "/a", "--rev", "1"]) == 0)
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu/etags.json").path))
  }

  @Test func refusePreflightDoesNotRecordTokenOrConsumeStdin() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let stdin = TextSink()
    let recorder = Recorder { _ in try Response.json(entryJSON(name: "a", token: "exists")) }
    let stderr = TextSink()
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { "body" },
      stdout: { _ in },
      stderr: { text in await stderr.append(text) },
      stdinIsTerminal: false,
      stdinChunks: {
        AsyncStream { continuation in
          Task {
            await stdin.append("called")
            continuation.yield(Array("body".utf8))
            continuation.finish()
          }
        }
      },
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
    #expect(await runner.run(arguments: ["put", "/a"]) == 1)
    #expect(await stderr.text == "refusing to overwrite /a: read it first, or pass --force\n")
    #expect(await stdin.text == "")
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu/etags.json").path))
  }

  @Test func removeClearsTokenAndMoveMigratesTreeTokens() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let wallet = temp.cwd.appendingPathComponent(".wuhu/etags.json")
    try writeJSON([
      "127.0.0.1:5530|/a": "ta",
      "127.0.0.1:5530|/dir/x": "tx",
      "127.0.0.1:5530|/dir/sub/y": "ty",
    ], to: wallet)
    let harness = try Harness(temp: temp) { request in
      switch request.url.path {
      case "/v1/tools/rm": try Response.json(JSONValue.object(["rev": 1]))
      case "/v1/tools/mv": try Response.json(JSONValue.object(["rev": 2, "dangling": []]))
      default: try Response.json(JSONValue.object([:]))
      }
    }
    #expect(await harness.runner.run(arguments: ["rm", "/a"]) == 0)
    #expect(await harness.runner.run(arguments: ["mv", "/dir", "/moved"]) == 0)
    let etags = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: wallet))
    #expect(etags["127.0.0.1:5530|/a"] == nil)
    #expect(etags["127.0.0.1:5530|/moved/x"] == "tx")
    #expect(etags["127.0.0.1:5530|/moved/sub/y"] == "ty")
  }

  @Test func malformedCachesSelfHealAndMalformedConfigIsActionable() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let wallet = temp.cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try "not json".write(to: wallet.appendingPathComponent("etags.json"), atomically: true, encoding: .utf8)
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 0)
    #expect((await harness.stderr.text).contains("warning: ignoring malformed"))

    try "not json".write(to: wallet.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let broken = try Harness(temp: temp, response: .object([:]))
    #expect(await broken.runner.run(arguments: ["read", "/a"]) == 64)
    #expect(await broken.stderr.text == "malformed .wuhu/config.json; run: wuhu use <host:port> to repair\n")
    #expect(await runTrusting(broken, ["use", "localhost:1"]) == 0)
  }

  @Test func wuhuFileIsRejected() async throws {
    let temp = try TemporaryDirectory()
    try "x".write(to: temp.cwd.appendingPathComponent(".wuhu"), atomically: true, encoding: .utf8)
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 64)
    #expect(await harness.stderr.text == "found .wuhu but it is not a directory\n")
  }
}

@Suite
struct FormattingAndErrorTests {
  @Test func formatsListHistoryAndQuery() async throws {
    #expect(formatList(try decode(ListOutput.self, .object(["rev": 3, "entries": [
      entryJSON(name: "docs", kind: "directory", size: 0, token: "d1"),
      entryJSON(name: "a.md", kind: "file", size: 12, token: "f1"),
      entryJSON(name: "t.table", kind: "table", size: 5, token: "t1"),
    ]]))) == "d  0 docs\n- 12 a.md\nt  5 t.table\n")

    let stat = formatStat(try decode(Entry.self, entryJSON(name: "a.md", kind: "file", size: 12, lineCount: 2, token: "f1", mtime: 1_700_000_000)))
    #expect(stat.contains("kind=file"))
    #expect(stat.contains("size=12 B"))
    #expect(stat.contains("lines=2"))
    #expect(stat.contains("token=f1"))
    #expect(stat.contains("mtime="))
    #expect(stat.contains("name=a.md"))

    #expect(formatHistory(try decode(HistoryOutput.self, .object(["entries": [
      .object(["rev": 1, "mtime": 2, "change": "write"]),
      .object(["rev": 2, "mtime": 3.5, "change": "move", "to": "/b"]),
    ]]))) == "1 write 2\n2 move 3.5 to=/b\n")

    #expect(formatQuery(try decode(QueryOutput.self, .object([
      "columns": ["name", "done"],
      "rows": [["Buy\tmilk\n", false], ["Count", 2]],
    ]))) == "name\tdone\nBuy\\tmilk\\n\tfalse\nCount\t2\n")
  }

  @Test func parserHonorsEndOfOptionsSentinel() async throws {
    try await assertRequest(["edit", "--force", "/a", "--", "--force", "new"], response: .object(["rev": 1, "token": "t"])) { request in
      let input = try await requestBodyJSON(request)
      #expect(input == ["path": "/a", "edits": [["old": "--force", "new": "new"]]])
    }
  }

  @Test func rendersToolError() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let error: JSONValue = .object(["code": "conflict", "message": "stale", "hint": "read again"])
    let harness = try Harness(temp: temp, response: try Response.json(error, status: .init(code: 409)))
    let code = await harness.runner.run(arguments: ["read", "/a"])
    #expect(code == 1)
    #expect(await harness.stderr.text == "conflict: stale\nhint: read again\n")
  }

  @Test func rendersNonJSONErrorBody() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .text("broken", status: .init(code: 500)))
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 1)
    #expect(await harness.stderr.text == "HTTP 500: broken\n")
  }

  @Test func stdinErrorsStopStdinVerbsBeforeRequest() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let recorder = Recorder { _ in try Response.json(JSONValue.object(["rev": 1, "token": "t"])) }
    let stderr = TextSink()
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { throw CLIError(message: "stdin is not valid UTF-8") },
      stdout: { _ in },
      stderr: { text in await stderr.append(text) },
      stdinIsTerminal: false,
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
    #expect(await runner.run(arguments: ["login"]) == 1)
    #expect(await stderr.text == "stdin is not valid UTF-8\n")
    #expect(await recorder.requests.isEmpty)
  }

  @Test func writeWithoutBodyIsAUsageErrorPointingAtPut() async throws {
    let harness = try Harness(response: .object([:]))
    #expect(await harness.runner.run(arguments: ["write", "/a.png"]) == 64)
    #expect(await harness.stderr.text.contains("wuhu put /a.png"))
    #expect(await harness.recorder.requests.isEmpty)
  }

  @Test func putStreamsStdinBytesToTheByteRoute() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let payload: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE]
    let recorder = Recorder { _ in try Response.json(JSONValue.object(["rev": 3, "token": "t9"])) }
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { "" },
      stdout: { _ in },
      stderr: { _ in },
      stdinIsTerminal: false,
      stdinChunks: { AsyncStream { $0.yield(payload); $0.finish() } },
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
    #expect(await runner.run(arguments: ["put", "--force", "/logo.png"]) == 0)
    let request = try #require(await recorder.requests.first)
    #expect(request.method == .put)
    #expect(request.url.path == "/v1/f/logo.png")
    #expect(try await request.body?.data() == Data(payload))
  }

  @Test func catReadsTheByteRouteWithoutRecordingAToken() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let payload: [UInt8] = [0x00, 0xC3, 0x28]
    let bytes = ByteSink()
    let recorder = Recorder { _ in
      Response(status: .ok, body: .bytes(Data(payload), contentType: "image/png"))
    }
    let runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { "" },
      stdout: { _ in },
      stderr: { _ in },
      stdoutBytes: { chunk in await bytes.append(chunk) },
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
    #expect(await runner.run(arguments: ["cat", "/logo.png"]) == 0)
    let request = try #require(await recorder.requests.first)
    #expect(request.method == .get)
    #expect(request.url.path == "/v1/f/logo.png")
    #expect(await bytes.value == payload)
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu/etags.json").path))
  }
}

private func runTrusting(_ harness: Harness, _ arguments: [String]) async -> Int32 {
  await withDependencies {
    $0[ServerTrustProbe.self] = ServerTrustProbe(
      validateSystem: { _, _ in },
      observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
    )
  } operation: {
    await harness.runner.run(arguments: arguments)
  }
}

private func requestBodyJSON(_ request: Request) async throws -> JSONValue {
  let text = try await (request.body ?? .empty).text()
  return try #require(JSONValue.parse(text))
}

private func assertRequest(
  _ arguments: [String],
  stdin: String = "",
  response: JSONValue,
  inspect: (Request) async throws -> Void,
) async throws {
  let harness = try Harness(stdin: stdin, response: response)
  let code = await harness.runner.run(arguments: arguments)
  #expect(code == 0)
  let requests = await harness.recorder.requests
  #expect(requests.count == 1)
  try await inspect(try #require(requests.first))
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

private actor TextSink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}

private actor ByteSink {
  var value: [UInt8] = []

  func append(_ chunk: [UInt8]) {
    self.value += chunk
  }
}

private struct Harness {
  let temp: TemporaryDirectory
  let runner: CommandRunner
  let recorder: Recorder
  let stdout: TextSink
  let stderr: TextSink

  init(
    temp: TemporaryDirectory? = nil,
    stdin: String = "",
    response: JSONValue,
  ) throws {
    let temp = try temp ?? TemporaryDirectory(withLocalWallet: true)
    try self.init(temp: temp, stdin: stdin) { _ in try Response.json(response) }
  }

  init(
    temp: TemporaryDirectory? = nil,
    stdin: String = "",
    response: Response,
  ) throws {
    let temp = try temp ?? TemporaryDirectory(withLocalWallet: true)
    try self.init(temp: temp, stdin: stdin) { _ in response }
  }

  init(
    temp: TemporaryDirectory? = nil,
    stdin: String = "",
    responder: @escaping @Sendable (Request) async throws -> Response,
  ) throws {
    let temp = try temp ?? TemporaryDirectory(withLocalWallet: true)
    let recorder = Recorder(responder: responder)
    let stdout = TextSink()
    let stderr = TextSink()
    self.temp = temp
    self.recorder = recorder
    self.stdout = stdout
    self.stderr = stderr
    self.runner = CommandRunner(
      fetch: FetchClient { request in try await recorder.fetch(request) },
      stdin: { stdin },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: ["HOME": temp.home.path],
      currentDirectory: temp.cwd.path,
    )
  }
}

private struct TemporaryDirectory {
  let scratch: ScratchFolder
  let root: URL
  let home: URL
  let cwd: URL

  init(withLocalWallet: Bool = false, cwdUnderHome: Bool = false, cwdIsHome: Bool = false) throws {
    self.scratch = try ScratchFolder("cli")
    self.root = self.scratch.url
    self.home = self.root.appendingPathComponent("home", isDirectory: true)
    self.cwd = cwdIsHome ? self.home : (cwdUnderHome ? self.home : self.root).appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: self.cwd, withIntermediateDirectories: true)
    if withLocalWallet {
      let wallet = self.cwd.appendingPathComponent(".wuhu", isDirectory: true)
      try FileManager.default.createDirectory(at: wallet, withIntermediateDirectories: true)
      try writeJSON(["space": "127.0.0.1:5530"], to: wallet.appendingPathComponent("config.json"))
    }
  }
}

private func entryJSON(name: String, kind: String = "file", size: Int = 1, lineCount: Int? = nil, token: String, mtime: Double = 0) -> JSONValue {
  var value: JSONValue = .object(["name": .string(name), "kind": .string(kind), "size": .integer(size), "token": .string(token), "mtime": .number(mtime)])
  value.set("lineCount", lineCount.map(JSONValue.integer))
  return value
}

private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
  try JSONValueDecoder().decode(type, from: value)
}

private func writeJSON(_ value: some Encodable, to url: URL) throws {
  let data = try JSONEncoder().encode(value)
  try data.write(to: url, options: .atomic)
}

@Suite
struct TrustVerbTests {
  @Test func useWithoutPinRequiresSystemTrust() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    let code = await withDependencies {
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { _, _ in throw CLIError(message: "certificate not trusted") },
        observeLeaf: { _, _ in throw UnimplementedProbe(endpoint: "observeLeaf") },
      )
    } operation: {
      await harness.runner.run(arguments: ["use", "127.0.0.1:5530"])
    }
    #expect(code != 0)
    #expect(await harness.stdout.text == "")
    #expect((await harness.stderr.text).contains("wuhu use 127.0.0.1:5530 --pin"))
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu").path))
  }

  @Test func usePinRecordsTheObservedLeafWithoutSystemValidation() async throws {
    let temp = try TemporaryDirectory()
    let harness = try Harness(temp: temp, response: .object([:]))
    let der = Data([7, 7, 7]).base64EncodedString()
    let code = await withDependencies {
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
        observeLeaf: { _, _ in der },
      )
    } operation: {
      await harness.runner.run(arguments: ["use", "--pin", "127.0.0.1:5530"])
    }
    #expect(code == 0)
    let trust = try ServerTrust(environment: ["HOME": temp.home.path])
    #expect(try trust.pin(forHost: "127.0.0.1:5530") == PinnedTLS.fingerprint(certificateDER: [7, 7, 7]))
    #expect(!FileManager.default.fileExists(atPath: temp.cwd.appendingPathComponent(".wuhu/trust.json").path))
    let output = await harness.stdout.text
    #expect(output.contains("pinned server certificate sha256:"))
  }

  @Test func useWithARecordedPinSkipsSystemValidation() async throws {
    let temp = try TemporaryDirectory()
    let trust = try ServerTrust(environment: ["HOME": temp.home.path])
    try trust.record(PinnedTLS.fingerprint(certificateDER: [1, 2, 3]), forHost: "127.0.0.1:5530")
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["use", "127.0.0.1:5530"]) == 0)
    #expect((await harness.stdout.text).contains("(pinned)"))
  }

  @Test func folderLevelTrustFileIsIgnoredWithAWarning() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let folderTrust = temp.cwd.appendingPathComponent(".wuhu/trust.json")
    try #"{"127.0.0.1:5530": "Y2VydC1h"}"#.write(to: folderTrust, atomically: true, encoding: .utf8)
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 0)
    let stderr = await harness.stderr.text
    #expect(stderr.contains("warning: ignoring \(folderTrust.path)"))
    #expect(stderr.contains("wuhu use <host:port> [--pin]"))
    #expect(stderr.contains("can be deleted"))
  }

  @Test func userTrustStoreAtHomeCwdIsNotALegacyFolderWallet() async throws {
    let temp = try TemporaryDirectory(cwdIsHome: true)
    let userWallet = temp.home.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: userWallet, withIntermediateDirectories: true)
    try writeJSON(["space": "127.0.0.1:5530"], to: userWallet.appendingPathComponent("config.json"))
    let trust = try ServerTrust(environment: ["HOME": temp.home.path])
    let fingerprint = PinnedTLS.fingerprint(certificateDER: [1, 2, 3])
    try trust.record(fingerprint, forHost: "127.0.0.1:5530")
    let harness = try Harness(temp: temp, response: .object(["token": "t", "content": "ok"]))
    #expect(await harness.runner.run(arguments: ["read", "/a"]) == 0)
    #expect(await harness.stderr.text == "")
    #expect(try trust.pin(forHost: "127.0.0.1:5530") == fingerprint)
  }

  @Test func userTrustStoreBehindASymlinkedHomeIsNotALegacyFolderWallet() async throws {
    let temp = try TemporaryDirectory(cwdIsHome: true)
    let userWallet = temp.home.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: userWallet, withIntermediateDirectories: true)
    try writeJSON(["space": "127.0.0.1:5530"], to: userWallet.appendingPathComponent("config.json"))
    try ServerTrust(environment: ["HOME": temp.home.path])
      .record(PinnedTLS.fingerprint(certificateDER: [1, 2, 3]), forHost: "127.0.0.1:5530")
    let link = temp.root.appendingPathComponent("homelink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temp.home)
    let stderr = TextSink()
    let runner = CommandRunner(
      fetch: FetchClient { _ in try Response.json(JSONValue.object(["token": "t", "content": "ok"])) },
      stdin: { "" },
      stdout: { _ in },
      stderr: { text in await stderr.append(text) },
      environment: ["HOME": link.path],
      currentDirectory: temp.home.path,
    )
    #expect(await runner.run(arguments: ["read", "/a"]) == 0)
    #expect(await stderr.text == "")
  }

  @Test func malformedUserTrustStoreFailsLoudly() async throws {
    let temp = try TemporaryDirectory()
    let userStore = temp.home.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: userStore, withIntermediateDirectories: true)
    try #"{"127.0.0.1:5530": "Y2VydC1h"}"#.write(
      to: userStore.appendingPathComponent("trust.json"), atomically: true, encoding: .utf8,
    )
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await runTrusting(harness, ["use", "127.0.0.1:5530"]) != 0)
    #expect((await harness.stderr.text).contains("malformed trust store"))
  }

  @Test func untrustRemovesTheRecordAndAbsentHostIsNotAnError() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let trust = try ServerTrust(environment: ["HOME": temp.home.path])
    try trust.record(PinnedTLS.fingerprint(certificateDER: [9]), forHost: "127.0.0.1:5530")
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["untrust", "127.0.0.1:5530"]) == 0)
    #expect(try trust.pin(forHost: "127.0.0.1:5530") == nil)
    #expect(await harness.runner.run(arguments: ["untrust", "127.0.0.1:5530"]) == 0)
    let output = await harness.stdout.text
    #expect(output.contains("forgot 127.0.0.1:5530"))
    #expect(output.contains("no trust record for 127.0.0.1:5530"))
  }

  @Test func trustWithoutAPinPointsAtUsePin() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let harness = try Harness(temp: temp, response: .object([:]))
    #expect(await harness.runner.run(arguments: ["trust", "127.0.0.1:5530"]) != 0)
    #expect((await harness.stderr.text).contains("wuhu use 127.0.0.1:5530 --pin"))
  }

  @Test func trustRerecordsThePinnedCertificate() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let trust = try ServerTrust(environment: ["HOME": temp.home.path])
    try trust.record(PinnedTLS.fingerprint(certificateDER: [1]), forHost: "127.0.0.1:5530")
    let harness = try Harness(temp: temp, response: .object([:]))
    let der = Data([2]).base64EncodedString()
    let code = await withDependencies {
      $0[ServerTrustProbe.self] = ServerTrustProbe(
        validateSystem: { _, _ in throw UnimplementedProbe(endpoint: "validateSystem") },
        observeLeaf: { _, _ in der },
      )
    } operation: {
      await harness.runner.run(arguments: ["trust", "127.0.0.1:5530"])
    }
    #expect(code == 0)
    #expect(try trust.pin(forHost: "127.0.0.1:5530") == PinnedTLS.fingerprint(certificateDER: [2]))
    #expect((await harness.stdout.text).contains("server certificate sha256:"))
  }
}

@Suite struct CapabilityCLITests {
  @Test func transcriptionHelpExplainsAuthoritativeCapabilities() async throws {
    let harness = try Harness(response: .object([:]))
    #expect(await harness.runner.run(arguments: ["transcribe", "--help"]) == 0)
    let help = await harness.stdout.text
    #expect(help.contains("/capabilities.json") && help.contains("unconfigured capability synthesizes Codex"))
    #expect(help.contains("never falls back") && help.contains("readable timing"))
    #expect(!help.contains("otherwise through its openai"))
  }

  @Test func capabilityCallsUseTheLongOperationTransport() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    try Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!.write(to: temp.cwd.appendingPathComponent("clip.wav"))
    let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="
    let harness = try Harness(temp: temp, response: .object(["query": "moon", "sources": [], "text": "hello", "provider": "openai", "model": "gpt-4o-mini-transcribe", "b64JSON": .string(png)]))
    let ordinaryCalls = LockIsolated(0)
    var runner = harness.runner
    runner.observeFetch = runner.fetch
    runner.fetch = FetchClient { _ in ordinaryCalls.withValue { $0 += 1 }; return try .json(JSONValue.object(["columns": [], "rows": []])) }
    #expect(await runner.run(arguments: ["web-search", "moon"]) == 0)
    #expect(await runner.run(arguments: ["transcribe", "clip.wav"]) == 0)
    #expect(await runner.run(arguments: ["image", "moon", "--destination", "long.png"]) == 0)
    #expect(ordinaryCalls.value == 0)
    #expect(await harness.recorder.requests.count == 3)
    #expect(await runner.run(arguments: ["query", "SELECT 1"]) == 0)
    #expect(ordinaryCalls.value == 1)
  }

  @Test func capabilityErrorsRetainTheirCodeAndHintInTheCLI() async throws {
    let harness = try Harness(response: .json(JSONValue.object(["code": "provider_not_configured", "message": "Missing key", "hint": "Configure server credentials"]), status: .serviceUnavailable))
    #expect(await harness.runner.run(arguments: ["web-search", "moon"]) == 1)
    #expect(await harness.stderr.text == "provider_not_configured: Missing key\nhint: Configure server credentials\n")
  }

  @Test func webSearchMapsNeutralProviderAndCount() async throws {
    try await assertRequest(["web-search", "synthetic moon", "--provider", "brave", "--count", "3"], response: .object(["query": "synthetic moon", "provider": "brave", "sources": []])) { request in
      #expect(request.method == .post && request.url.path == "/v1/web-search")
      let body = try await requestBodyJSON(request)
      #expect(body == .object(["query": "synthetic moon", "provider": "brave", "count": 3]))
    }
  }

  @Test func transcriptionCarriesTheSameRichOptionsAsScripts() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let audio = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==")!
    try audio.write(to: temp.cwd.appendingPathComponent("clip.wav"))
    let harness = try Harness(temp: temp, response: .object(["text": "hello", "provider": "qwen", "model": "qwen-audio-3.1-asr-flash-filetrans", "segments": [["text": "hello", "start": 0, "end": 1, "speaker": "1"]]]))
    #expect(await harness.runner.run(arguments: ["transcribe", "clip.wav", "--provider", "qwen", "--model", "qwen-audio-3.1-asr-flash-filetrans", "--timestamps", "words,segments", "--diarize", "--json"]) == 0)
    let request = try #require(await harness.recorder.requests.first)
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "provider", value: "qwen")))
    #expect(query.contains(URLQueryItem(name: "timestamps", value: "words,segments")))
    #expect(query.contains(URLQueryItem(name: "diarize", value: "true")))
    #expect(try await request.body?.data() == audio)
    #expect(await harness.stdout.text.contains("\"speaker\":\"1\""))
  }

  @Test func imageEditingUploadsPrivateBytesAndNeverOverwrites() async throws {
    let temp = try TemporaryDirectory(withLocalWallet: true)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8) + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
    try png.write(to: temp.cwd.appendingPathComponent("reference.png"))
    let harness = try Harness(temp: temp, response: .object(["b64JSON": .string(png.base64EncodedString()), "mimeType": "image/png"]))
    let args = ["image", "blue moon", "--image", "reference.png", "--destination", "art/result.png", "--provider", "qwen", "--quality", "standard"]
    #expect(await harness.runner.run(arguments: args) == 0)
    let request = try #require(await harness.recorder.requests.first)
    #expect(request.url.path == "/v1/image" && request.method == .post)
    let body = try await requestBodyJSON(request)
    #expect(body.object?["images"] == .array([.string(png.base64EncodedString())]))
    #expect(body.object?["quality"] == .string("standard"))
    #expect(try Data(contentsOf: temp.cwd.appendingPathComponent("art/result.png")) == png)
    #expect(await harness.runner.run(arguments: args) == 1)
    #expect(await harness.recorder.requests.count == 1)
    #expect(await harness.stderr.text.contains("never overwrites"))
  }
}
