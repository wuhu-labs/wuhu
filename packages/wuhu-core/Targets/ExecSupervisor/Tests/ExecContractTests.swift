#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CExecSupervisor
@testable import ExecSupervisor
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Fetch
import enum JSONValue.JSONValue
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import Testing

func execRequest(_ id: UUID, query: String = "", suffix: String = "", method: Fetch.Method = .get, body: Body? = nil) -> Request {
  Request(url: URL(string: "http://memory/machine/v2/machines/test/operations/\(id)\(suffix)\(query)")!, method: method, body: body)
}

func withExec(limits: OperationLimits = .init(), disclaimResponsibility: Bool = false, _ action: (OperationAgent) async throws -> Void) async throws {
  let agent = try OperationAgent(machine: "test", kinds: [AnyOperationKind(ExecKind(disclaimResponsibility: disclaimResponsibility))], limits: limits, authorize: { _, _ in })
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { await agent.run() }
    do { try await action(agent) } catch { await agent.shutdown(); group.cancelAll(); throw error }
    await agent.shutdown(); group.cancelAll()
  }
}

func startExec(_ agent: OperationAgent, id: UUID, script: String, stdin: Bool = false, secrets: JSONValue = [:]) async throws {
  let response = try await agent.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", .string(script)], "cwd": "/tmp", "stdin": .bool(stdin), "secretValues": secrets]))))
  #expect(response.status.code == 201)
}

func waitExit(_ agent: OperationAgent, id: UUID) async throws -> OperationSnapshot {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(8)
  while clock.now < deadline {
    let s = try await agent.handler(execRequest(id)).body.json(OperationSnapshot.self)
    if s.verdict != nil { return s }
    try await clock.sleep(for: .milliseconds(10))
  }
  throw TestFailure.timeout
}

func waitOutputEnd(_ agent: OperationAgent, id: UUID) async throws -> OperationSnapshot {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(8)
  while clock.now < deadline {
    let s = try await agent.handler(execRequest(id, query: "?channel=stdout&after=0")).body.json(OperationSnapshot.self)
    if s.channelEnd { return s }
    try await clock.sleep(for: .milliseconds(10))
  }
  throw TestFailure.timeout
}

func waitStderr(_ agent: OperationAgent, id: UUID, containing expected: Data) async throws -> Data {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(8)
  var output = Data()
  var after: UInt64 = 0
  while clock.now < deadline {
    let snapshot = try await agent.handler(execRequest(id, query: "?channel=stderr&after=\(after)")).body.json(OperationSnapshot.self)
    if let data = snapshot.payload?.data { output.append(data) }
    if let through = snapshot.through { after = through.rawValue }
    if output.range(of: expected) != nil { return output }
    try await clock.sleep(for: .milliseconds(10))
  }
  Issue.record("stderr did not contain \(String(decoding: expected, as: UTF8.self)) before the deadline: \(String(decoding: output, as: UTF8.self))")
  throw TestFailure.timeout
}

enum TestFailure: Error { case timeout }
@Suite struct ExecContractTests {
  @Test(arguments: [true, false]) func lowercaseUUIDStartAndPollAddressTheSameOperation(lowercaseStart: Bool) async throws {
    try await withExec { agent in
      let id = UUID(); let nonce = UUID().uuidString + UUID().uuidString
      let manifest = SupervisorManifest(version: 1, machine: "test", operation: id, nonce: nonce, socket: "/tmp/unused/control.sock")
      let gate = SupervisorGate(manifest: manifest, agent: agent)
      let spelling = lowercaseStart ? id.uuidString.lowercased() : id.uuidString
      var start = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "sleep .1; exit 17"], "cwd": "/tmp", "stdin": false])))
      start.url = URL(string: start.url.absoluteString.replacingOccurrences(of: id.uuidString, with: spelling))!
      start.headers["X-Wuhu-Supervisor-Nonce"] = nonce
      let accepted = try await gate.handler(start)
      #expect(accepted.status.code == 201)
      var poll = execRequest(id)
      poll.url = URL(string: poll.url.absoluteString.replacingOccurrences(of: id.uuidString, with: id.uuidString.lowercased()))!
      poll.headers["X-Wuhu-Supervisor-Nonce"] = nonce
      #expect(try await gate.handler(poll).status.code == 200)
    }
  }

  @Test func daemonInheritedPipesDoNotDelayDirectChildExit() async throws {
    try await withExec { agent in
      let id = UUID()
      try await startExec(agent, id: id, script: "sleep 2 & printf before; exit 17")
      let s = try await waitExit(agent, id: id)
      #expect(s.verdict?.result == ["termination": ["tag": "exit", "code": 17]])
      let out = try await waitOutputEnd(agent, id: id)
      #expect(out.payload?.data == Data("before".utf8))
    }
  }

  @Test func fullStdoutDoesNotBlockStopOrStderr() async throws {
    try await withExec { agent in
      let id = UUID()
      try await startExec(agent, id: id, script: "printf stderr >&2; exec yes x")
      let stderr = try await waitStderr(agent, id: id, containing: Data("stderr".utf8))
      #expect(stderr == Data("stderr".utf8))
      _ = try await agent.handler(execRequest(id, suffix: "/stop", method: .put, body: .json(StopRequest(reason: "testStop"))))
      let s = try await waitExit(agent, id: id)
      #expect(s.verdict?.tag == .stopped)
      #expect(s.verdict?.reason == "testStop")
      #expect(s.verdict?.result != nil)
    }
  }

  @Test func invalidSpawnIsTypedFailureNotExit127() async throws {
    try await withExec { agent in
      let id = UUID()
      _ = try await agent.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: ["argv": ["/no/such/executable"], "cwd": "/tmp", "stdin": false]))))
      let s = try await waitExit(agent, id: id)
      #expect(s.verdict?.tag == .failed)
      #expect(s.verdict?.error?.code == .spawnFailed)
    }
  }

  @Test func termIgnoringGroupRequiresObservedSIGKILLAfterGrace() async throws {
    try await withExec { agent in
      let id = UUID()
      try await startExec(agent, id: id, script: "trap '' TERM; printf ready >&2; exec sleep 100")
      _ = try await waitStderr(agent, id: id, containing: Data("ready".utf8))
      let clock = ContinuousClock(); let began = clock.now
      _ = try await agent.handler(execRequest(id, suffix: "/stop", method: .put, body: .json(StopRequest(reason: "ignoredTerm"))))
      let snapshot = try await waitExit(agent, id: id)
      #expect(clock.now - began >= .seconds(5))
      #expect(snapshot.verdict?.tag == .stopped)
      #expect(snapshot.verdict?.result == ["termination": ["tag": "signal", "signal": 9]])
    }
  }

  @Test func racingStopRetainsObservedTermination() async throws {
    try await withExec { agent in
      for _ in 0 ..< 12 {
        let id = UUID()
        try await startExec(agent, id: id, script: "exec yes x")
        try await ContinuousClock().sleep(for: .milliseconds(25))
        _ = try await agent.handler(execRequest(id, suffix: "/stop", method: .put, body: .json(StopRequest(reason: "race"))))
        let snapshot = try await waitExit(agent, id: id)
        #expect(snapshot.verdict?.tag == .stopped)
        #expect(snapshot.verdict?.result != nil)
      }
    }
  }

  @Test func childCannotInheritUnrelatedDescriptors() async throws {
    let fd = open("/dev/null", O_RDONLY)
    #expect(fd >= 0)
    defer { exec_close(fd) }
    #expect(fcntl(fd, F_SETFD, 0) == 0)
    try await withExec { agent in
      let id = UUID()
      #if os(Linux)
        let folder = "/proc/self/fd/"
      #else
        let folder = "/dev/fd/"
      #endif
      try await startExec(agent, id: id, script: "test ! -e \(folder)\(fd)")
      #expect(try await waitExit(agent, id: id).verdict?.result == ["termination": ["tag": "exit", "code": 0]])
    }
  }

  @Test func maskerSurvivesChunkBoundary() async throws {
    try await withExec { agent in
      let id = UUID()
      try await startExec(agent, id: id, script: "printf sec; sleep .03; printf ret", secrets: ["MASK": "secret"])
      _ = try await waitExit(agent, id: id)
      let out = try await waitOutputEnd(agent, id: id)
      #expect(out.payload?.data == Data("***".utf8))
    }
  }
}

extension ExecContractTests {
  @Test func serverOwnedCredentialReplacesCallerFieldsAndIsMasked() async throws {
    try await withExec { agent in
      let id = UUID()
      let input: JSONValue = ["argv": ["/bin/sh", "-c", "printf '%s|%s|%s|%s' \"$WUHU_EXEC\" \"$WUHU_SPACE_URL\" \"$WUHU_TOKEN_EXPIRES_AT\" \"$WUHU_TOKEN\""], "cwd": "/tmp", "stdin": false, "env": ["WUHU_EXEC": "fake", "WUHU_TOKEN": "fake", "WUHU_SPACE_URL": "fake", "WUHU_TOKEN_EXPIRES_AT": "fake"], "sessionCredential": ["token": "wst_private_token", "spaceURL": "https://session.test", "expiresAt": 12345]]
      let response = try await agent.handler(execRequest(id, method: .post, body: .json(StartRequest(kind: "exec.v1", input: input))))
      #expect(response.status.code == 201)
      _ = try await waitExit(agent, id: id)
      let out = try await waitOutputEnd(agent, id: id)
      #expect(out.payload?.data == Data("1|https://session.test|12345.0|***".utf8))
    }
  }
}

extension ExecContractTests {
  @Test func invalidSessionCredentialExpiryIsRejectedAtAdmission() throws {
    for expiry in [Double.nan, .infinity, -.infinity, 0, -1] {
      let input = ExecInput(argv: ["/bin/true"], cwd: "/tmp", env: nil, secretValues: nil, sessionCredential: .init(token: "wst_test", spaceURL: "https://test.invalid", expiresAt: expiry), stdin: false)
      do { try input.validate(); Issue.record("invalid expiry accepted") }
      catch let error as OperationError { #expect(error.code == .invalidInput) }
    }
  }
}
