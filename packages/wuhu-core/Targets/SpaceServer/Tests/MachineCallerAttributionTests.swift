#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
import Fetch
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
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    while try await channels.read("stdin", upTo: 65536) != nil {}
    return ["termination": ["tag": "exit", "code": 0]]
  }
}

@Suite struct MachineCallerAttributionTests {
  @Test func everyStartASessionCausesNamesItAndOtherStartsDont() async throws {
    let folder = try ScratchFolder("v2-caller")
    let file = folder.url.appending(path: "notes.txt")
    try Data("needle".utf8).write(to: file)
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "Backend coder", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let (record, _) = try await space.addMachineV2(name: "caller-v2", group: .shared)
    let seen = Mutex<[AdmittedStart]>([])
    let agent = try ComputerAgent(machine: record.id.rawValue, kinds: [.init(SilentExec())], audit: { start in seen.withLock { $0.append(start) } })
    let hub = MachineHub(space: space)
    let coordinator = MachineV2Coordinator(space: space, key: SymmetricKey(size: .bits256), problemsGroup: .shared, origin: URL(string: "https://test.invalid")!, fetch: { _ in FetchClient { try await agent.handler($0) } }, abort: { _, _ in })
    try await coordinator.prepare()
    let service = MachineV2Service(hub: MachineV2Hub(space: space), coordinator: coordinator, failure: nil)
    await hub.configureV2(service)
    let expected = StartRequest.Caller(session: session.rawValue, title: "Backend coder", group: "shared")
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      let seam = machineSeam(hub: hub)
      // A tool call (the executor sets the task-local) and a script (an attributed seam) both name the session.
      _ = try await MachineSeam.$caller.withValue(session) { try await seam.vfs(record.id, .read(path: file.path)) }
      _ = try await seam.attributed(to: session).search(record.id, .grep(pattern: "needle", path: file.path, matchLimit: nil, entryLimit: nil, step: nil))
      // No session: no caller, and a session that can't be read doesn't fail the start.
      _ = try await seam.vfs(record.id, .stat(path: file.path))
      _ = try await seam.attributed(to: SessionID(rawValue: "gone-gone-gone")).vfs(record.id, .stat(path: file.path))
      #expect(seen.withLock { $0.map(\.kind) } == ["read.v1", "grep.v1", "stat.v1", "stat.v1"])
      #expect(seen.withLock { $0.map(\.caller) } == [expected, expected, nil, nil])

      // Exec: the relay attributes the exec record's caller.
      let minted = try await space.mintExec(machine: record.id, caller: session.rawValue, group: .shared)
      let endpoint = ChannelEndpoint()
      let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: ["true"]))
      let transport = try await execBackend(space: space, hub: hub).connect(minted.id)
      tasks.addTask { await endpoint.run(transport) }
      await outgoing.closeStdin()
      for try await event in outgoing.events { if case .exit = event { break } }
      let exec = try #require(seen.withLock { $0.last })
      #expect(exec.kind == "exec.v1"); #expect(exec.caller == expected)
      await agent.shutdown(); await service.shutdown()
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
      #expect(await hub.admitsCaller(minted, leg: .anonymous) == false)
      #expect(await hub.admitsCaller(minted, leg: .session(session)))
      let (personServer, personClient) = WebSocket.pair()
      await hub.runCallerSession(minted, socket: personServer, leg: person)
      var personInbound = personClient.inbound.makeAsyncIterator()
      #expect(await personInbound.next() == nil)
      #expect(await hub.admitsCaller(minted, leg: .session(session)))
      #expect(seen.all.isEmpty)
    }
  }

  // Once a session's exec is running, a person can't attach to it at all (no stdin, no output under the session's credential);
  // the session itself reconnects and finishes it.
  @Test func aSessionOwnedExecRefusesAPersonAndTakesTheSessionsReconnect() async throws {
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
      #expect(await hub.admitsCaller(minted, leg: .anonymous) == false)
      let (personServer, personClient) = WebSocket.pair()
      await hub.runCallerSession(minted, socket: personServer, leg: person)
      var personInbound = personClient.inbound.makeAsyncIterator()
      #expect(await personInbound.next() == nil)

      firstClient.close(); firstRun.cancel(); _ = await (firstLeg.value, firstRun.value)
      #expect(await hub.admitsCaller(minted, leg: .session(session)))
      let (secondServer, secondClient) = WebSocket.pair()
      let secondLeg = Task { await hub.runCallerSession(minted, socket: secondServer, leg: .session(session)) }
      let secondRun = Task { await caller.run(WebSocketTransport(secondClient)) }
      await exec.closeStdin()
      for try await event in exec.events { if case .exit = event { break } }
      #expect(seen.all.count == 1)
      secondClient.close(); secondRun.cancel(); _ = await (secondLeg.value, secondRun.value)
    }
  }

  private func withExecFixture(caller: Bool = true, _ body: (Space, MachineHub, SessionID, ExecRecord, Starts) async throws -> Void) async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "Backend coder", kind: .task, createdBy: "owner", executor: .kernel(.init(provider: "testing", model: "test-model", effort: "high")))
    let (record, _) = try await space.addMachineV2(name: "forge-v2", group: .shared)
    let seen = Starts()
    let agent = try ComputerAgent(machine: record.id.rawValue, kinds: [.init(SilentExec())], audit: { seen.append($0) })
    let hub = MachineHub(space: space, tokens: ExecTokens(spaceURL: "https://test.invalid"))
    let coordinator = MachineV2Coordinator(space: space, key: SymmetricKey(size: .bits256), problemsGroup: .shared, origin: URL(string: "https://test.invalid")!, fetch: { _ in FetchClient { try await agent.handler($0) } }, abort: { _, _ in })
    try await coordinator.prepare()
    let service = MachineV2Service(hub: MachineV2Hub(space: space), coordinator: coordinator, failure: nil)
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, caller: caller ? session.rawValue : nil, group: .shared)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      defer { tasks.cancelAll() }
      try await body(space, hub, session, minted, seen)
      await agent.shutdown(); await service.shutdown()
    }
  }
}

private final class Starts: Sendable {
  private let list = Mutex<[AdmittedStart]>([])
  var all: [AdmittedStart] { list.withLock { $0 } }
  func append(_ start: AdmittedStart) { list.withLock { $0.append(start) } }
}
