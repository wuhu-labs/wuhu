import Contract
import Foundation
import JSONValue
import MachineContract
import Testing

@Suite
struct MachineContractCodingTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  @Test func controlMessageEncodesInternallyTagged() throws {
    #expect(try encoder.encode(ControlMessage.hello(protocolVersion: 1)) == .object([
      "kind": "hello", "protocolVersion": 1,
    ]))
    #expect(try encoder.encode(ControlMessage.ping) == .object(["kind": "ping"]))
    #expect(try encoder.encode(ControlMessage.error(error: MachineError(code: .tokenRevoked, message: "revoked"))) == .object([
      "kind": "error", "error": .object(["code": "tokenRevoked", "message": "revoked"]),
    ]))
  }

  @Test func exitStatusEncodesInternallyTagged() throws {
    #expect(try encoder.encode(ExitStatus.exited(code: 0)) == .object(["kind": "exited", "code": 0]))
    #expect(try encoder.encode(ExitStatus.signaled(signal: 15)) == .object(["kind": "signaled", "signal": 15]))
  }

  @Test func execEventEncodesInternallyTagged() throws {
    #expect(try encoder.encode(ExecEvent.output(stream: .stdout, cursor: 0, data: Base64Data([104, 105]))) == .object([
      "kind": "output", "stream": "stdout", "cursor": 0, "data": "aGk=",
    ]))
    #expect(try encoder.encode(ExecEvent.exit(status: .exited(code: 0))) == .object([
      "kind": "exit", "status": .object(["kind": "exited", "code": 0]),
    ]))
    #expect(try encoder.encode(ExecEvent.truncated(limit: 1024)) == .object(["kind": "truncated", "limit": 1024]))
    #expect(try encoder.encode(ExecEvent.failed(error: MachineError(code: .machineLost, message: "gone"))) == .object([
      "kind": "failed", "error": .object(["code": "machineLost", "message": "gone"]),
    ]))
  }

  @Test func vfsOpEncodesInternallyTagged() throws {
    #expect(try encoder.encode(VFSOp.stat(path: "/a")) == .object(["kind": "stat", "path": "/a"]))
    #expect(try encoder.encode(VFSOp.write(path: "/a", data: Base64Data([104, 105]), ifMatch: "17.5")) == .object([
      "kind": "write", "path": "/a", "data": "aGk=", "ifMatch": "17.5",
    ]))
    #expect(try encoder.encode(VFSOp.rm(path: "/a", ifMatch: nil)) == .object(["kind": "rm", "path": "/a"]))
    #expect(try encoder.encode(VFSOp.mv(from: "/a", to: "/b")) == .object(["kind": "mv", "from": "/a", "to": "/b"]))
  }

  @Test func aRangedReadCarriesItsRangeAndAPlainReadStaysAsBefore() throws {
    #expect(try encoder.encode(VFSOp.read(path: "/a")) == .object(["kind": "read", "path": "/a"]))
    let ranged = JSONValue.object(["kind": "read", "path": "/a", "offset": 8, "length": 4])
    #expect(try encoder.encode(VFSOp.read(path: "/a", offset: 8, length: 4)) == ranged)
    #expect(try decoder.decode(VFSOp.self, from: ranged) == .read(path: "/a", offset: 8, length: 4))
  }

  // An agent built before ranged reads decodes the op with only a path, so it
  // reads the whole file and refuses one over its bound with tooLarge. The
  // server relies on that to tell such an agent apart.
  @Test func anAgentBuiltBeforeRangedReadsSeesARangedReadAsAWholeFileRead() throws {
    let ranged = try encoder.encode(VFSOp.read(path: "/a", offset: 8, length: 4))
    #expect(try decoder.decode(PlainReadOp.self, from: ranged) == .read(path: "/a"))
  }

  @Test func vfsResultEncodesInternallyTagged() throws {
    let entry = MachineEntry(name: "a", kind: .file, size: 2, token: "3.5", mtime: 3.5)
    #expect(try encoder.encode(VFSResult.entry(entry: entry)) == .object([
      "kind": "entry",
      "entry": .object(["name": "a", "kind": "file", "size": 2, "token": "3.5", "mtime": 3.5]),
    ]))
    #expect(try encoder.encode(VFSResult.ok) == .object(["kind": "ok"]))
  }

  @Test func searchQueryEncodesInternallyTagged() throws {
    #expect(try encoder.encode(
      SearchQuery.grep(pattern: "TODO", path: nil, matchLimit: 100, entryLimit: nil, step: nil),
    ) == .object(["kind": "grep", "pattern": "TODO", "matchLimit": 100]))
    #expect(try encoder.encode(
      SearchQuery.find(glob: "**/*.md", path: "/p", matchLimit: nil, entryLimit: 50, step: "s1"),
    ) == .object(["kind": "find", "glob": "**/*.md", "path": "/p", "entryLimit": 50, "step": "s1"]))
  }

  @Test func searchResultEncodesInternallyTagged() throws {
    let match = SearchMatch(path: "/a", line: 3, text: "TODO x", context: ["ctx"])
    #expect(try encoder.encode(SearchResult.matches(matches: [match], cursor: "c1")) == .object([
      "kind": "matches",
      "matches": .array([.object(["path": "/a", "line": 3, "text": "TODO x", "context": .array(["ctx"])])]),
      "cursor": "c1",
    ]))
    #expect(try encoder.encode(SearchResult.paths(paths: ["/a"], cursor: nil)) == .object([
      "kind": "paths", "paths": .array(["/a"]),
    ]))
  }

  @Test func absentOptionalDecodesNilAndReEncodesAbsent() throws {
    let json: JSONValue = .object([
      "id": "ex_a1b2c3d4", "cwd": "/work", "command": .array(["make", "test"]),
    ])
    let start = try decoder.decode(ExecStart.self, from: json)
    #expect(start.env == nil)
    #expect(start.window == nil)
    #expect(try encoder.encode(start) == json)
  }

  @Test func execStartCarriesMapsAndKnobs() throws {
    let start = ExecStart(
      id: ExecID(rawValue: "ex_a1b2c3d4"),
      cwd: "/work",
      command: ["swift", "build"],
      env: ["CI": "1"],
      secrets: ["GITHUB_TOKEN": "gh"],
      window: 1024,
      maxOutput: 2048,
      timeout: 1.5,
    )
    let json = try encoder.encode(start)
    #expect(json == .object([
      "id": "ex_a1b2c3d4", "cwd": "/work", "command": .array(["swift", "build"]),
      "env": .object(["CI": "1"]), "secrets": .object(["GITHUB_TOKEN": "gh"]),
      "window": 1024, "maxOutput": 2048, "timeout": 1.5,
    ]))
  }

  @Test func execStartCarriesTheSessionCredential() throws {
    let start = ExecStart(
      id: ExecID(rawValue: "ex_a1b2c3d4"),
      cwd: "/work",
      command: ["wuhu", "ls"],
      session: ExecSessionCredential(token: "wst_abc", spaceURL: "https://space.test:5530"),
    )
    let json = try encoder.encode(start)
    #expect(json == .object([
      "id": "ex_a1b2c3d4", "cwd": "/work", "command": .array(["wuhu", "ls"]),
      "session": .object(["token": "wst_abc", "spaceURL": "https://space.test:5530"]),
    ]))
    #expect(try decoder.decode(ExecStart.self, from: json) == start)
  }

  @Test func execStartIgnoresFieldsItDoesNotKnow() throws {
    let json: JSONValue = .object([
      "id": "ex_a1b2c3d4", "cwd": "/work", "command": .array(["true"]),
      "fromANewerServer": .object(["token": "x"]),
    ])
    let start = try decoder.decode(ExecStart.self, from: json)
    #expect(start.command == ["true"])
    #expect(start.session == nil)
  }

  @Test func joinTokenAppearsOnlyInMintShapes() throws {
    let token = "jt_abcdefghijklmnopqrstuvwxyz012345"
    #expect(try encoder.encode(MachineAddOutput(id: MachineID(rawValue: "mc_a1b2c3d4"), token: token, fingerprint: nil)) == .object([
      "id": "mc_a1b2c3d4", "token": .string(token),
    ]))
    let fingerprint = "sha256:" + String(repeating: "a", count: 64)
    #expect(try encoder.encode(MachineAddOutput(id: MachineID(rawValue: "mc_a1b2c3d4"), token: token, fingerprint: fingerprint)) == .object([
      "id": "mc_a1b2c3d4", "token": .string(token), "fingerprint": .string(fingerprint),
    ]))
    #expect(try encoder.encode(MachineStatus(id: MachineID(rawValue: "mc_a1b2c3d4"), name: nil, attached: true)) == .object([
      "id": "mc_a1b2c3d4", "attached": true,
    ]))
  }

  @Test func connectSignaturesAreDomainSeparated() {
    let payload = MachineConnect.signingPayload(challenge: "mch_abc")
    #expect(payload == Data("wuhu-machine-connect:mch_abc".utf8))
  }
}

@Contract
enum PlainReadOp: Codable, Equatable {
  case read(path: String)
}
