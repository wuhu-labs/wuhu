import CLIKit
import Clocks
import Dependencies
import Fetch
import FetchSSE
import Foundation
import JSONValue
import Scratch
import Serve
import ServeTesting
import SpaceCore
import SpaceServer
import Testing

// A 1x1 transparent PNG: a signature, a NUL run, and deflate bytes that are
// not valid UTF-8.
private let onePixelPNG: [UInt8] = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]

@Suite
struct ClientServerFaithfulnessTests {
  @Test func everyVerbRunsAgainstRealSpaceServer() async throws {
    let harness = try ServerHarness()

    #expect(await harness.run(["write", "--force", "/a.md", "--body", "hello\nworld"]) == 0)
    #expect(await harness.run(["read", "/a.md"]) == 0)
    #expect(await harness.run(["edit", "/a.md", "hello", "hi"]) == 0)
    #expect(await harness.run(["ls", "/"]) == 0)
    #expect(await harness.run(["stat", "/a.md"]) == 0)
    #expect(await harness.run(["grep", "hi", "/"]) == 0)
    #expect(await harness.run(["find", "**/*.md", "/"]) == 0)
    #expect(await harness.run(["history", "/a.md"]) == 0)
    #expect(await harness.run(["checkout", "/a.md", "1"]) == 0)

    let header = "{\"columns\":[{\"name\":\"n\",\"type\":\"integer\"}]}"
    #expect(await harness.run(["table", "create", "/t.table", header]) == 0)
    #expect(await harness.run(["table", "mutate", "/t.table", "[{\"kind\":\"insert\",\"values\":[7]}]"]) == 0)
    #expect(await harness.run(["query", "SELECT n FROM \"/t.table\""]) == 0)
    #expect(await harness.run(["table", "alter", "/t.table", header]) == 0)

    #expect(await harness.run(["write", "--force", "/templates/j.md", "--body", "---\ntemplate:\n  strategy: incr\n  prefix: J\n---\nhi"]) == 0)
    #expect(await harness.run(["new", "/templates/j.md", "/journal"]) == 0)
    #expect(await harness.run(["mv", "/a.md", "/moved.md"]) == 0)
    #expect(await harness.run(["rm", "--force", "/moved.md"]) == 0)
  }

  @Test func addressingFormsMatchServerWire() async throws {
    let harness = try ServerHarness(space: "api.test:5530")
    #expect(await harness.run(["write", "--force", "wuhu://api.test:5530/a.md", "--body", "x"]) == 0)
    #expect(await harness.run(["read", "/a.md@1"]) == 0)
    #expect(await harness.stdout.text.contains("x"))
  }

  @Test func putAndCatRoundTripBinaryBytesExactly() async throws {
    let harness = try ServerHarness()
    #expect(await harness.run(["put", "/logo.png"], stdin: onePixelPNG) == 0)
    #expect(await harness.run(["cat", "/logo.png"]) == 0)
    #expect(await harness.bytes.value == onePixelPNG)

    #expect(await harness.run(["read", "/logo.png"]) == 1)
    #expect(await harness.stderr.text.contains("is not UTF-8 text"))
    #expect(await harness.stderr.text.contains("wuhu cat"))
  }

  @Test func writeTakesBodyAndABareWritePointsAtPut() async throws {
    let harness = try ServerHarness()
    #expect(await harness.run(["write", "/notes.md", "--body", "hello"]) == 0)
    #expect(await harness.run(["read", "/notes.md"]) == 0)
    #expect(await harness.stdout.text.contains("hello"))

    #expect(await harness.run(["write", "/other.md"]) == 64)
    #expect(await harness.stderr.text.contains("wuhu put /other.md"))
  }

  @Test func observeQueryOncePersistsBySpaceAndSkipsEqualSnapshots() async throws {
    let harness = try ServerHarness(space: "space-a")
    let other = try ServerHarness(space: "space-b")
    let header = "{\"columns\":[{\"name\":\"n\",\"type\":\"integer\"}]}"
    #expect(await harness.run(["table", "create", "/t.table", header]) == 0)
    #expect(await other.run(["table", "create", "/t.table", header]) == 0)

    #expect(await harness.run(["observe", "--sql", "SELECT n FROM \"/t.table\"", "--once"]) == 0)
    #expect(await other.run(["observe", "--sql", "SELECT n FROM \"/t.table\"", "--once"]) == 0)

    async let observed: Int32 = harness.run(["observe", "--sql", "SELECT n FROM \"/t.table\"", "--once"])
    await Task.yield()
    #expect(await harness.run(["table", "mutate", "/t.table", "[{\"kind\":\"insert\",\"values\":[1]}]"]) == 0)
    #expect(await observed == 0)
    #expect(await harness.stdout.text.contains("1"))
  }

  @Test func observeGlobOncePrintsFirstDeltaWithoutCursor() async throws {
    let harness = try ServerHarness()
    async let observed: Int32 = harness.run(["observe", "--glob", "/**", "--once"])
    await Task.yield()
    #expect(await harness.run(["write", "--force", "/g.md", "--body", "x"]) == 0)
    #expect(await observed == 0)
    let output = await harness.stdout.text
    #expect(output.contains("\"path\":\"/g.md\"") || output.contains("/g.md"))
  }
}

private struct ServerHarness {
  let temp: ServerTemp
  let runner: CommandRunner
  let stdout: ServerSink
  let stderr: ServerSink
  let bytes = ServerByteSink()

  init(space: String = "space") throws {
    self.temp = try ServerTemp(space: space)
    let (createdSpace, hub) = try withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
      $0.continuousClock = ContinuousClock()
    } operation: {
      let space = try Space.inMemory()
      return (space, MachineHub(space: space))
    }
    let handler = SpaceServer.handler(space: createdSpace, hub: hub, dev: true)
    let client = ServeTesting.client(upgrading: handler)
    let stdout = ServerSink()
    let stderr = ServerSink()
    self.stdout = stdout
    self.stderr = stderr
    self.runner = CommandRunner(
      fetch: client,
      observeFetch: client,
      stdin: { "" },
      stdout: { text in await stdout.append(text) },
      stderr: { text in await stderr.append(text) },
      environment: ["HOME": self.temp.home.path],
      currentDirectory: self.temp.cwd.path,
    )
  }

  func run(_ arguments: [String], stdin: [UInt8] = []) async -> Int32 {
    let runner = CommandRunner(
      fetch: self.runner.fetch,
      observeFetch: self.runner.observeFetch,
      stdin: { String(decoding: stdin, as: UTF8.self) },
      stdout: { text in await self.stdout.append(text) },
      stderr: { text in await self.stderr.append(text) },
      stdinIsTerminal: false,
      stdinChunks: { AsyncStream { $0.yield(stdin); $0.finish() } },
      stdoutBytes: { chunk in await self.bytes.append(chunk) },
      environment: ["HOME": self.temp.home.path],
      currentDirectory: self.temp.cwd.path,
    )
    return await runner.run(arguments: arguments)
  }
}

private actor ServerSink {
  var text = ""

  func append(_ value: String) {
    self.text += value
  }
}

private actor ServerByteSink {
  var value: [UInt8] = []

  func append(_ chunk: [UInt8]) {
    self.value += chunk
  }
}

private struct ServerTemp {
  let scratch: ScratchFolder
  let root: URL
  let home: URL
  let cwd: URL

  init(space: String) throws {
    self.scratch = try ScratchFolder("faithfulness")
    self.root = self.scratch.url
    self.home = self.root.appendingPathComponent("home", isDirectory: true)
    self.cwd = self.root.appendingPathComponent("work", isDirectory: true)
    let wallet = self.cwd.appendingPathComponent(".wuhu", isDirectory: true)
    try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: wallet, withIntermediateDirectories: true)
    try JSONEncoder().encode(["space": space]).write(to: wallet.appendingPathComponent("config.json"), options: .atomic)
  }
}
