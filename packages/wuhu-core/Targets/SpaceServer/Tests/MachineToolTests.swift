import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
import Scratch
import Serve
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct MachineToolTests {
  @Test func fsToolSuiteOverMachinesAgainstARealAgent() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let fixture = try ScratchFolder("m5-fixture")
    defer { fixture.remove() }
    let root = fixture.path

    try await runScenario(server: server) { dialer, _ in
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      let base = "machines://\(machine.rawValue)\(root)"

      let written = try await call(server, "write", ["path": .string("\(base)/notes/hello.txt"), "content": "v1"], as: WriteOutput.self)
      #expect(written.rev == nil)

      let read = try await call(server, "read", ["path": .string("\(base)/notes/hello.txt")], as: ReadOutput.self)
      #expect(read.content == "v1")
      #expect(read.token == written.token)

      let entry = try await call(server, "stat", ["path": .string("\(base)/notes/hello.txt")], as: SpaceContract.Entry.self)
      let attributes = try FileManager.default.attributesOfItem(atPath: "\(root)/notes/hello.txt")
      let mtime = (attributes[.modificationDate] as! Date).timeIntervalSince1970
      #expect(entry.token == String(mtime))
      #expect(entry.kind == .file)
      #expect(entry.size == 2)

      let listed = try await call(server, "ls", ["path": .string("\(base)/notes")], as: ListOutput.self)
      #expect(listed.rev == nil)
      #expect(listed.entries.map(\.name) == ["hello.txt"])

      let edited = try await call(server, "edit", [
        "path": .string("\(base)/notes/hello.txt"),
        "edits": .array([.object(["old": "v1", "new": "v2 fuzzy"])]),
      ], as: EditOutput.self)
      #expect(edited.rev == nil)
      let reread = try await call(server, "read", ["path": .string("\(base)/notes/hello.txt")], as: ReadOutput.self)
      #expect(reread.content == "v2 fuzzy")
      #expect(reread.token == edited.token)

      // A concurrent change invalidates the held token: bump mtime out-of-band
      // and both write-ifMatch and edit-ifMatch surface the space conflict
      // contract (code + re-read hint).
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: mtime + 100)],
        ofItemAtPath: "\(root)/notes/hello.txt",
      )
      let writeConflict = try await failure(server, "write", [
        "path": .string("\(base)/notes/hello.txt"), "content": "v3", "ifMatch": .string(reread.token),
      ])
      #expect(writeConflict.code == "conflict")
      #expect(writeConflict.hint == "changed since you read it — re-read")
      let editConflict = try await failure(server, "edit", [
        "path": .string("\(base)/notes/hello.txt"),
        "edits": .array([.object(["old": "v2", "new": "v3"])]),
        "ifMatch": .string(reread.token),
      ])
      #expect(editConflict.code == "conflict")
      #expect(editConflict.hint == "changed since you read it — re-read")

      let moved = try await call(server, "mv", [
        "from": .string("\(base)/notes/hello.txt"), "to": .string("\(base)/notes/renamed.txt"),
      ], as: MoveOutput.self)
      #expect(moved.rev == nil)
      #expect(moved.dangling == [])
      let renamed = try await call(server, "read", ["path": .string("\(base)/notes/renamed.txt")], as: ReadOutput.self)
      #expect(renamed.content == "v2 fuzzy")

      let crossBackend = try await failure(server, "mv", [
        "from": .string("\(base)/notes/renamed.txt"), "to": "/stolen.txt",
      ])
      #expect(crossBackend.code == "invalidArgument")

      let removed = try await post(server, "rm", ["path": .string("\(base)/notes/renamed.txt")])
      #expect(removed.status == .ok)
      #expect(try await json(removed) == .object([:]))
      #expect(!FileManager.default.fileExists(atPath: "\(root)/notes/renamed.txt"))
      let missing = try await failure(server, "rm", ["path": .string("\(base)/notes/renamed.txt")])
      #expect(missing.code == "notFound")

      // Machine paths are raw: "@" without an all-digit suffix passes through.
      _ = try await call(server, "write", ["path": .string("\(base)/we@ird.txt"), "content": "raw"], as: WriteOutput.self)
      let weird = try await call(server, "read", ["path": .string("\(base)/we@ird.txt")], as: ReadOutput.self)
      #expect(weird.content == "raw")
    }
  }

  @Test func machineAddressesRejectRevisionsLoudly() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let fixture = try ScratchFolder("m5-fixture")
    defer { fixture.remove() }
    let root = fixture.path

    try await runScenario(server: server) { dialer, _ in
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      let base = "machines://\(machine.rawValue)\(root)"

      let suffix = try await failure(server, "read", ["path": .string("\(base)/hello.txt@3")])
      #expect(suffix.code == "unsupported")
      #expect(suffix.message.contains("no revisions"))

      let revField = try await failure(server, "read", ["path": .string("\(base)/hello.txt"), "rev": 3])
      #expect(revField.code == "unsupported")

      let lsRev = try await failure(server, "ls", ["path": .string(base), "rev": 1])
      #expect(lsRev.code == "unsupported")
    }
  }

  @Test func detachedMachineFailsUnavailableAndOversizedFramesNeverSend() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    let detached = try await failure(server, "read", ["path": .string("machines://\(machine.rawValue)/etc/hosts")])
    #expect(detached.code == "unavailable")

    let bogus = try await failure(server, "read", ["path": "machines://nonsense id/etc/hosts"])
    #expect(bogus.code == "invalidPath")

    let fixture = try ScratchFolder("m5-fixture")
    defer { fixture.remove() }
    let root = fixture.path
    try await runScenario(server: server) { dialer, _ in
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      await #expect(throws: MachineHubError.frameTooLarge) {
        _ = try await server.hub.vfs(
          machine: machine,
          op: .write(path: "\(root)/huge.bin", data: Base64Data(Array(repeating: 7, count: 17 << 20)), ifMatch: nil),
        )
      }
      #expect(!FileManager.default.fileExists(atPath: "\(root)/huge.bin"))
    }
  }

  // The bind hello is in flight while attachedMachines() already reports the
  // machine: a round trip issued in that window must resolve, not fail severed.
  @Test func roundTripRacingTheBindHelloResolves() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await server.run() }
      group.addTask {
        let socket = try await connectMachine(server, key: key)
        try await awaitAttached(server, machine)
        try await withThrowingTaskGroup(of: Void.self) { round in
          round.addTask {
            let result = try await server.hub.vfs(machine: machine, op: .mkdir(path: "/tmp/racing"))
            #expect(result == .ok)
          }
          round.addTask {
            var requestID: Int?
            for await message in socket.inbound {
              guard case let .binary(bytes) = message,
                    let frame = try? FrameCodec.decode(bytes),
                    frame.opcode == .vfsRequest,
                    let request = try? frame.payload(VFSRequest.self)
              else { continue }
              requestID = request.id
              break
            }
            let id = try #require(requestID)
            try await socket.send(.binary(FrameCodec.encode(
              Frame(streamID: 0, opcode: .control, payload: ControlMessage.hello(protocolVersion: 1)),
            )))
            try await socket.send(.binary(FrameCodec.encode(
              Frame(streamID: 0, opcode: .vfsResponse, payload: VFSResponse(id: id, result: .ok)),
            )))
          }
          try await round.waitForAll()
        }
        socket.close()
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  @Test func readBeyondTheAgentBoundSurfacesAsAToolError() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let fixture = try ScratchFolder("m5-fixture")
    defer { fixture.remove() }
    let root = fixture.path
    let path = "\(root)/big.bin"
    #expect(FileManager.default.createFile(atPath: path, contents: Data(count: (8 << 20) + 1)))

    try await runScenario(server: server) { dialer, _ in
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      let tooLarge = try await failure(server, "read", ["path": .string("machines://\(machine.rawValue)\(path)")])
      #expect(tooLarge.code == "unsupported")
      #expect(tooLarge.message.contains("exceeds"))
    }
  }
}

@Suite struct SearchParityTests {
  @Test func grepAndFindPagesAreIdenticalAcrossBackendsModuloTheAddressPrefix() async throws {
    let space = try makeMachineSpace()
    let server = TestServer(space: space, clock: ContinuousClock())
    let (machine, key) = try await addMachine(server)
    let scratch = try ScratchFolder("m5-fixture")
    defer { scratch.remove() }
    let root = scratch.path
    let fixture: [(String, String)] = [
      ("/docs/a.txt", "foo one\nplain\nfoo two"),
      ("/docs/b.txt", "nothing here"),
      ("/docs/c.txt", "foo three"),
      ("/readme.md", "foo four"),
      ("/src/deep/nested.txt", "foo five\nfoo six"),
    ]

    try await runScenario(server: server) { dialer, _ in
      dialer.offer(try await connectMachine(server, key: key))
      try await awaitAttached(server, machine)
      for (path, content) in fixture {
        _ = try await call(server, "write", ["path": .string(path), "content": .string(content)], as: WriteOutput.self)
        _ = try await call(
          server, "write",
          ["path": .string("machines://\(machine.rawValue)\(root)\(path)"), "content": .string(content)],
          as: WriteOutput.self,
        )
      }
      let machineRoot = "machines://\(machine.rawValue)\(root)"
      let limitRuns: [(matchLimit: Int?, entryLimit: Int?)] = [
        (nil, nil), (1, nil), (nil, 1), (nil, 2), (2, 2),
      ]

      for run in limitRuns {
        let spacePages = try await grepPages(
          server, path: "/", strip: [], pattern: "foo \\w+", matchLimit: run.matchLimit, entryLimit: run.entryLimit,
        )
        let machinePages = try await grepPages(
          server, path: machineRoot, strip: [machineRoot, root], pattern: "foo \\w+",
          matchLimit: run.matchLimit, entryLimit: run.entryLimit,
        )
        #expect(spacePages == machinePages, "grep \(run)")
        #expect(spacePages.last?.cursor == nil)
        if run.matchLimit == nil, run.entryLimit == nil {
          #expect(spacePages.count == 1)
          #expect(spacePages[0].items == [
            "/docs/a.txt:1:foo one",
            "/docs/a.txt:3:foo two",
            "/docs/c.txt:1:foo three",
            "/readme.md:1:foo four",
            "/src/deep/nested.txt:1:foo five",
            "/src/deep/nested.txt:2:foo six",
          ])
        }
      }

      for run in limitRuns {
        let spacePages = try await findPages(
          server, path: "/", strip: [], glob: "**/*.txt", matchLimit: run.matchLimit, entryLimit: run.entryLimit,
        )
        let machinePages = try await findPages(
          server, path: machineRoot, strip: [machineRoot, root], glob: "**/*.txt",
          matchLimit: run.matchLimit, entryLimit: run.entryLimit,
        )
        #expect(spacePages == machinePages, "find \(run)")
        #expect(spacePages.last?.cursor == nil)
        #expect(spacePages.flatMap(\.items) == [
          "/docs/a.txt", "/docs/b.txt", "/docs/c.txt", "/src/deep/nested.txt",
        ])
      }
    }
  }
}

// MARK: - Helpers

private struct ToolFailure {
  let code: String
  let message: String
  let hint: String?
}

private struct Page: Equatable {
  let items: [String]
  let cursor: String?
}

func awaitAttached(_ server: TestServer, _ machine: MachineID) async throws {
  let attached = try await realPollUntil { await server.hub.attachedMachines().contains(machine) }
  #expect(attached)
}

private func post(_ server: TestServer, _ tool: String, _ input: JSONValue) async throws -> Response {
  try await server.http(.post, "/v1/tools/\(tool)", json: input)
}

private func call<Output: Decodable>(
  _ server: TestServer, _ tool: String, _ input: JSONValue, as output: Output.Type,
) async throws -> Output {
  let response = try await post(server, tool, input)
  #expect(response.status == .ok, "\(tool) \(input)")
  return try await response.json(output)
}

private func failure(_ server: TestServer, _ tool: String, _ input: JSONValue) async throws -> ToolFailure {
  let response = try await post(server, tool, input)
  #expect(response.status == .unprocessableContent, "\(tool) \(input)")
  let payload = try await json(response)
  guard case let .object(fields) = payload,
        case let .string(code)? = fields["code"],
        case let .string(message)? = fields["message"]
  else {
    Issue.record("expected a tool error payload, got \(payload)")
    return ToolFailure(code: "", message: "", hint: nil)
  }
  let hint: String? = if case let .string(value)? = fields["hint"] { value } else { nil }
  return ToolFailure(code: code, message: message, hint: hint)
}

// The fixture root is a random-suffixed absolute path, so removing every
// occurrence normalizes both match paths (full address prefix) and cursors
// (machine-local path after the "line@").
private func stripPrefix(_ value: String, _ strips: [String]) -> String {
  var value = value
  for strip in strips {
    value = value.replacingOccurrences(of: strip, with: "")
  }
  return value
}

private extension JSONValue {
  mutating func set(_ key: String, _ value: JSONValue?) {
    guard case var .object(fields) = self, let value else { return }
    fields[key] = value
    self = .object(fields)
  }
}

private func grepPages(
  _ server: TestServer, path: String, strip: [String], pattern: String, matchLimit: Int?, entryLimit: Int?,
) async throws -> [Page] {
  var pages: [Page] = []
  var step: String?
  for _ in 0 ..< 50 {
    var input: JSONValue = .object(["pattern": .string(pattern), "path": .string(path)])
    input.set("matchLimit", matchLimit.map(JSONValue.integer))
    input.set("entryLimit", entryLimit.map(JSONValue.integer))
    input.set("step", step.map(JSONValue.string))
    let output = try await call(server, "grep", input, as: GrepOutput.self)
    pages.append(Page(
      items: output.matches.map { "\(stripPrefix($0.path, strip)):\($0.line):\($0.text)" },
      cursor: output.cursor.map { stripPrefix($0, strip) },
    ))
    guard let next = output.cursor else { return pages }
    step = next
  }
  Issue.record("grep did not exhaust in 50 pages")
  return pages
}

private func findPages(
  _ server: TestServer, path: String, strip: [String], glob: String, matchLimit: Int?, entryLimit: Int?,
) async throws -> [Page] {
  var pages: [Page] = []
  var step: String?
  for _ in 0 ..< 50 {
    var input: JSONValue = .object(["glob": .string(glob), "path": .string(path)])
    input.set("matchLimit", matchLimit.map(JSONValue.integer))
    input.set("entryLimit", entryLimit.map(JSONValue.integer))
    input.set("step", step.map(JSONValue.string))
    let output = try await call(server, "find", input, as: FindOutput.self)
    pages.append(Page(
      items: output.paths.map { stripPrefix($0, strip) },
      cursor: output.cursor.map { stripPrefix($0, strip) },
    ))
    guard let next = output.cursor else { return pages }
    step = next
  }
  Issue.record("find did not exhaust in 50 pages")
  return pages
}
