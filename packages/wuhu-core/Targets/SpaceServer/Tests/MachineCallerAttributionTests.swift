import ControlledTime
import Dependencies
import DeterministicDependencies
import LoopCore
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import MachineChannel
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
import Serve
import SessionDomain
@testable import SpaceCore
@testable import SpaceServer
import struct SpaceTools.MachineSeam
import Synchronization
import Testing

private struct SilentExec: OperationKind {
  struct Input: Decodable, Sendable { let argv: [String] }
  let descriptor = ComputerKindSchemas.exec
  func start(_ input: Input, limits: OperationLimits) async throws -> OperationStart<JSONValue> {
    OperationStart { channels, cancellation in try await run(input, channels: channels, cancellation: cancellation) }
  }

  private func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    while try await channels.read("stdin", upTo: 65536) != nil {}
    return ["termination": ["tag": "exit", "code": 0]]
  }
}

@Suite(.deterministicDependencies(clock: VirtualClock())) struct MachineCallerAttributionTests {
  @Test func everyStartASessionCausesNamesItAndOtherStartsDont() async throws {
    let folder = try ScratchFolder("v2-caller")
    let file = folder.url.appending(path: "notes.txt")
    try Data("needle".utf8).write(to: file)
    let space = try Space.inMemory()
    _ = try await SessionToolFixture(space: space)
    let session = try await space.sessions.createSession(group: .shared, title: "Backend coder", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let (record, _) = try await space.addMachineV2(name: "caller_v2", group: .shared)
    let seen = Mutex<[AdmittedStart]>([])
    let agent = try ComputerAgent(machine: record.id.rawValue, kinds: [.init(SilentExec())], audit: { start in seen.withLock { $0.append(start) } })
    let hub = MachineHub(space: space)
    let expected = StartRequest.Caller(session: session.rawValue, title: "Backend coder", group: "shared")
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      try await withMachineBox(space: space, hub: hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
        let seam = machineSeam(hub: hub)
        // A tool call (the executor sets the task-local) and a script (an attributed seam) both name the session.
        _ = try await MachineSeam.$caller.withValue(session) { try await seam.vfs(record.id, .read(path: file.path)) }
        _ = try await seam.attributed(to: session).search(record.id, SearchQuery(mode: .grep, pattern: "needle", root: file.path, scope: "test"))
        // No session: no caller, and a session that can't be read doesn't fail the start.
        _ = try await seam.vfs(record.id, .stat(path: file.path))
        _ = try await seam.attributed(to: SessionID(rawValue: "gone-gone-gone")).vfs(record.id, .stat(path: file.path))
        #expect(seen.withLock { $0.map(\.kind) } == ["read.v1", "search.v1", "stat.v1", "stat.v1"])
        #expect(seen.withLock { $0.map(\.caller) } == [expected, expected, nil, nil])

        // Exec: the relay attributes the exec record's caller.
        let minted = try await space.reserveExec(machine: record.id, caller: session.rawValue, group: .shared)
        let endpoint = ChannelEndpoint()
        let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["true"]))
        let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
        tasks.addTask { await endpoint.run(transport) }
        await outgoing.closeStdin()
        for try await event in outgoing.events { if case .exit = event { break } }
        let exec = try #require(seen.withLock { $0.last })
        #expect(exec.kind == "exec.v1"); #expect(exec.caller == expected)
      }
      await agent.shutdown()
    }
  }

  // The byte lane through the session gate names the session too, on a GET and on a PUT.
  @Test func theByteLaneNamesTheSessionOnAMachine() async throws {
    let folder = try ScratchFolder("v2-byte-lane")
    let file = folder.url.appending(path: "notes.txt")
    try Data("needle".utf8).write(to: file)
    let harness = try await SessionHarness(spaceURL: "https://space.test:5530")
    let tokens = harness.runtime.tokens
    let space = harness.space
    let session = try await space.sessions.createSession(group: .shared, title: "Backend coder", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let (record, _) = try await space.addMachineV2(name: "lane_v2", group: .shared)
    let seen = Starts()
    let agent = try ComputerAgent(machine: record.id.rawValue, kinds: [.init(SilentExec())], audit: { seen.append($0) })
    let exec = try await space.reserveExec(machine: record.id, caller: session.rawValue, group: .shared)
    @Dependency(\.date) var date
    let bearer = try await tokens.credential(session: session, exec: exec.id, timeout: nil, now: date.now).token
    let expected = StartRequest.Caller(session: session.rawValue, title: "Backend coder", group: "shared")
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      try await withMachineBox(space: space, hub: harness.hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
        let lane = "/v1/f\(file.path)?machine=\(record.id.rawValue)"
        var get = Request(url: URL(string: "http://space" + lane)!)
        get.headers[.authorization] = "Bearer " + bearer
        let got = try await harness.api(get)
        #expect(got.status == .ok)
        let put = try await harness.put(lane, .string("x"), bearer: bearer)
        #expect(put.status == .ok)
        let kinds = seen.all.map(\.kind)
        #expect(kinds == ["read.v1", "mkdir.v1", "write.v1"])
        #expect(seen.all.map(\.caller) == Array(repeating: expected, count: kinds.count))
      }
      await agent.shutdown()
    }
  }

  // A person's own exec (minted without a caller) runs as them: no session caller and no session credential on the machine, and no
  // other actor can attach once they hold it.
  @Test func aPersonsOwnExecRunsWithoutASessionCallerOrCredential() async throws {
    try await withExecFixture(caller: false) { space, hub, session, minted, seen in
      let person = ExecLeg.person(AccountID(rawValue: "ac_person1"))
      let (personServer, personClient) = WebSocket.pair()
      let personLeg = Task { await hub.runCallerSession(minted, socket: personServer, leg: person) }
      let caller = ChannelEndpoint()
      let personExec = await caller.startExec(.init(id: minted.id, cwd: "/tmp", command: ["person"]))
      let personRun = Task { await caller.run(WebSocketTransport(personClient)) }
      await personExec.closeStdin()
      for try await event in personExec.events { if case .exit = event { break } }
      #expect(await hub.admitsCaller(minted, leg: .session(session)) == false)
      let starts = seen.all
      #expect(starts.count == 1)
      #expect(starts.first?.input.object?["argv"] == ["person"])
      #expect(starts.first?.caller == nil)
      #expect(starts.first?.input.object?["sessionCredential"] == nil)
      personClient.close(); personRun.cancel(); _ = await (personLeg.value, personRun.value)
    }
  }

  // A session's exec is reserved for it from the mint: a person attaching before any start is refused and can't hold it.
  @Test func aPersonCannotAttachToASessionsExecBeforeItStarts() async throws {
    try await withExecFixture { space, hub, session, minted, seen in
      let person = ExecLeg.person(AccountID(rawValue: "ac_person1"))
      #expect(await hub.admitsCaller(minted, leg: person) == false)
      #expect(await hub.admitsCaller(minted, leg: .session(session)))
      let (personServer, personClient) = WebSocket.pair()
      await hub.runCallerSession(minted, socket: personServer, leg: person)
      var personInbound = personClient.inbound.makeAsyncIterator()
      #expect(await personInbound.next() == nil)
      #expect(await hub.admitsCaller(minted, leg: .session(session)))
      #expect(seen.all.isEmpty)
    }
  }

  @Test func aSessionOwnedExecRefusesAPersonWhileItIsRunning() async throws {
    try await withExecFixture { space, hub, session, minted, seen in
      let caller = ChannelEndpoint()
      let exec = await caller.startExec(.init(id: minted.id, cwd: "/tmp", command: ["session"]))
      let (firstServer, firstClient) = WebSocket.pair()
      let firstLeg = Task { await hub.runCallerSession(minted, socket: firstServer, leg: .session(session)) }
      let firstRun = Task { await caller.run(WebSocketTransport(firstClient)) }
      #expect(try await realPollUntil { seen.all.count == 1 })
      let start = try #require(seen.all.first)
      #expect(start.caller == StartRequest.Caller(session: session.rawValue, title: "Backend coder", group: "shared"))
      #expect(start.input.object?["sessionCredential"]?.object?["token"]?.stringValue != nil)

      let person = ExecLeg.person(AccountID(rawValue: "ac_person1"))
      #expect(await hub.admitsCaller(minted, leg: person) == false)
      let (personServer, personClient) = WebSocket.pair()
      await hub.runCallerSession(minted, socket: personServer, leg: person)
      var personInbound = personClient.inbound.makeAsyncIterator()
      #expect(await personInbound.next() == nil)

      await exec.closeStdin()
      for try await event in exec.events { if case .exit = event { break } }
      #expect(seen.all.count == 1)
      #expect(await hub.admitsCaller(minted, leg: .session(session)) == false)
      firstClient.close(); firstRun.cancel(); _ = await (firstLeg.value, firstRun.value)
    }
  }

  @Test(arguments: [0.0, -1.0]) func aNonPositiveCallerTimeoutIsRefusedBeforeAdmission(timeout: Double) async throws {
    try await withExecFixture { space, hub, _, minted, seen in
      let endpoint = ChannelEndpoint()
      let exec = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["true"], timeout: timeout))
      let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
      let caller = Task { await endpoint.run(transport) }
      defer { transport.close(); caller.cancel() }
      var stderr = ""
      var status: MachineContract.ExitStatus?
      for try await event in exec.events {
        if case let .output(.stderr, _, bytes) = event { stderr += String(decoding: bytes.bytes, as: UTF8.self) }
        if case let .exit(value) = event { status = value; break }
      }
      #expect(stderr == "invalidInput: Exec timeout must be positive and finite\n")
      #expect(status == .exited(code: 1))
      #expect(try await space.execRecord(minted.id)?.terminal == .reaped)
      let row = try #require(space.worker.cell(MachineCell.ID(minted.machine.rawValue)).operation(minted.id.rawValue))
      #expect(row.diagnostic?.code == .invalidInput)
      #expect(row.snapshot?.verdict?.result == nil)
      #expect(seen.all.isEmpty)
    }
  }

  private func withExecFixture(caller: Bool = true, _ body: (Space, MachineHub, SessionID, ExecRecord, Starts) async throws -> Void) async throws {
    let space = try Space.inMemory()
    _ = try await SessionToolFixture(space: space)
    let session = try await space.sessions.createSession(group: .shared, title: "Backend coder", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let (record, _) = try await space.addMachineV2(name: "forge_v2", group: .shared)
    let seen = Starts()
    let agent = try ComputerAgent(machine: record.id.rawValue, kinds: [.init(SilentExec())], audit: { seen.append($0) })
    let hub = MachineHub(space: space, tokens: try await testTokens(space: space, spaceURL: "https://test.invalid"))
    let minted = try await space.reserveExec(machine: record.id, caller: caller ? session.rawValue : nil, group: .shared)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      try await withMachineBox(space: space, hub: hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
        try await body(space, hub, session, minted, seen)
      }
      await agent.shutdown()
    }
  }
}

private final class Starts: Sendable {
  private let list = Mutex<[AdmittedStart]>([])
  var all: [AdmittedStart] { list.withLock { $0 } }
  func append(_ start: AdmittedStart) { list.withLock { $0.append(start) } }
}
