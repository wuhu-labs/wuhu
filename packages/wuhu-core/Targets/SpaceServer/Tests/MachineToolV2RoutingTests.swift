import Clocks
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ComputerFiles
import Crypto
@testable import ExecSupervisor
import Fetch
import FileSearch
import enum JSONValue.JSONValue
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import enum SpaceTools.ToolRunError
import Synchronization
import Testing

@Suite(.deterministicDependencies(clock: TestClock()), .timeLimit(.minutes(3))) struct MachineToolV2RoutingTests {
  @Test func registeredTransportNotNameSelectsNormalFilesystemSearchAndExecPreflight() async throws {
    let folder = try ScratchFolder("v2-normal-tools")
    let a = folder.url.appending(path: "z.txt")
    let b = folder.url.appending(path: "a.txt")
    try Data("needle one\nneedle two\nneedle three".utf8).write(to: a)
    try Data("other".utf8).write(to: b)
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "normal-v2", group: .shared)
    let legacy = try await space.addMachine(name: "legacy-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
    await hub.configureV2(service)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      let read = try await hub.vfs(machine: record.id, op: .read(path: a.path))
      guard case let .file(_, bytes) = read else { Issue.record("normal read did not reach v2"); return }
      #expect(String(decoding: bytes.bytes, as: UTF8.self) == "needle one\nneedle two\nneedle three")
      let written = try await hub.vfs(machine: record.id, op: .write(path: b.path, data: .init(Array("changed".utf8)), ifMatch: nil))
      guard case .written = written else { Issue.record("normal write did not reach v2"); return }
      #expect(try String(contentsOf: b, encoding: .utf8) == "changed")
      let page = try await hub.search(machine: record.id, query: SearchQuery(mode: .grep, pattern: "needle", root: a.path, scope: "test", limit: 1))
      #expect(page.hits.map(\.line) == [1])
      let step = try #require(page.cursor)
      let next = try await hub.search(machine: record.id, query: SearchQuery(mode: .grep, pattern: "needle", root: a.path, scope: "test", limit: 5, step: step))
      #expect(next.hits.map(\.line) == [2, 3]); #expect(next.cursor == nil)
      for query in [SearchQuery(mode: .grep, pattern: "other", root: a.path, scope: "test", step: step), SearchQuery(mode: .find, pattern: "**", root: folder.path, scope: "test", step: "s2.not-base64!")] {
        do {
          _ = try await hub.search(machine: record.id, query: query)
          Issue.record("foreign cursor admitted")
        } catch let error as SearchError {
          #expect(error.code == .invalidStep)
        }
      }
      do {
        _ = try await machineSeam(hub: hub).search(record.id, SearchQuery(mode: .grep, pattern: "(", root: a.path, scope: "test"))
        Issue.record("remote invalid regex admitted")
      } catch let ToolRunError.failed(code, message, _, _) {
        #expect(code == .invalidArgument); #expect(message.contains("invalid pattern"))
      }
      do { try await hub.requireExecKind(record.id); Issue.record("missing exec kind admitted") }
      catch let error as OperationError { #expect(error.code == .unknownKind); #expect(error.details?.object?["kind"] == "exec.v1") }
      do { _ = try await hub.vfs(machine: legacy.id, op: .read(path: a.path)); Issue.record("legacy routed to v2 based on suffix") }
      catch let error as MachineHubError { #expect(error == .machineUnattached(legacy.id)) }
      do { _ = try await hub.search(machine: legacy.id, query: SearchQuery(mode: .find, pattern: "*", root: "/", scope: "test")); Issue.record("v1 machine searched") }
      catch let error as MachineHubError { #expect(error == .searchNeedsV2(legacy.id)) }
      await agent.shutdown()
    }
    await service.shutdown()
  }

  @Test(arguments: [false, true])
  func disappearedAdmittedOperationIsUnavailableNotMissingFile(_ search: Bool) async throws {
    let folder = try ScratchFolder("v2-lost-operation")
    let path = folder.url.appending(path: "file.txt")
    try Data("needle".utf8).write(to: path)
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "lost-operation-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
    let admitted = Mutex(false)
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      let response = try await agent.handler(request)
      if request.url.path.contains("/operations/") {
        if request.method == .post { admitted.withLock { $0 = true } }
        if request.method == .get {
          #expect(admitted.withLock { $0 })
          return try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound, headers: response.headers)
        }
      }
      return response
    } })
    await hub.configureV2(service)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }; defer { tasks.cancelAll() }
      do {
        let seam = machineSeam(hub: hub)
        if search { _ = try await seam.search(record.id, SearchQuery(mode: .grep, pattern: "needle", root: path.path, scope: "test")) }
        else { _ = try await seam.vfs(record.id, .read(path: path.path)) }
        Issue.record("vanished admitted operation succeeded")
      } catch let ToolRunError.failed(code, message, _, _) {
        #expect(code == .unavailable); #expect(message.contains("unknownOperation"))
      }
      #expect(admitted.withLock { $0 })
      await agent.shutdown()
    }
    await service.shutdown()
  }

  @Test func v2UnavailableNeverFallsBackToV1() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "offline-v2", group: .shared)
    let hub = MachineHub(space: space)
    do { _ = try await hub.vfs(machine: record.id, op: .stat(path: "/")); Issue.record("unconfigured transport admitted") }
    catch let error as OperationError { #expect(error.code == .machineUnavailable) }
  }
}

import MachineChannel

private struct LostResponse: Error {}

private struct RoutedEcho: OperationKind {
  var fastExit = false
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec
  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    #expect(input.argv == ["echo-test"]); #expect(input.cwd == "/tmp"); #expect(input.stdin)
    if fastExit { try await channels.send(.init(data: Data("fast".utf8)), to: "stdout") }
    else { while let payload = try await channels.read("stdin", upTo: 65536) { try await channels.send(payload, to: "stdout") } }
    try await channels.send(.init(data: Data("stderr".utf8)), to: "stderr")
    return ["termination": ["tag": "exit", "code": 7]]
  }
}

extension MachineToolV2RoutingTests {
  /// `lossy` applies the first attempt of each stdin write, the first output poll carrying bytes and the first terminal
  /// acknowledgement on the machine, then loses the response: the retries must neither drop nor duplicate a byte. A write the
  /// verdict overtook is not retried.
  @Test(arguments: ["echo", "fast", "early-eof", "lossy"])
  func normalExecBackendBridgesStdinBothOutputsAndExit(mode: String) async throws {
    let fastExit = mode == "fast"
    let native = mode == "early-eof"
    let lossy = mode == "lossy"
    let earlyEOF = Mutex<Set<String>>([])
    let lost = Mutex<[String]>([])
    /// A terminal acknowledgement reached the machine after the first one's answer was lost.
    let acknowledgedAgain = Gate()
    let folder = try ScratchFolder("exec-early-eof")
    let exitGate = folder.url.appending(path: "exit")
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "exec-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [native ? .init(ExecKind()) : .init(RoutedEcho(fastExit: fastExit))], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { request in
      if fastExit, request.method == .put, request.url.path.hasSuffix("/inputs/stdin") {
        var response = try Response.json(ErrorEnvelope(OperationError(.operationEnded)), status: .conflict)
        response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
        response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
        response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
        return response
      }
      let response = try await agent.handler(request)
      if lossy, request.url.query?.contains("terminalAck=") == true, lost.withLock({ $0.contains("ack") }) { acknowledgedAgain.open() }
      if lossy, request.method == .put, request.url.path.hasSuffix("/inputs/stdin") {
        let attempt = lost.withLock { value in value.append("stdin"); return value.count(where: { $0 == "stdin" }) }
        if attempt % 2 == 1 { throw LostResponse() }
      }
      // A machine drops an operation once its last channel is acknowledged, so a retried acknowledgement meets an error answer.
      if lossy, request.method == .get, request.url.query?.contains("channel=") == true, response.status == .ok {
        let snapshot = try await response.body.json(OperationSnapshot.self)
        let drop = lost.withLock { value in
          let key = request.url.query?.contains("terminalAck=") == true ? "ack" : (snapshot.payload?.count ?? 0) > 0 ? "output" : nil
          guard let key, !value.contains(key) else { return false }
          value.append(key); return true
        }
        if drop { throw LostResponse() }
        return try Response(status: response.status, headers: response.headers, body: .json(snapshot))
      }
      if native, request.method == .get, request.url.query?.contains("channel=") == true {
        let snapshot = try await response.body.json(OperationSnapshot.self)
        if snapshot.channelEnd, snapshot.verdict == nil, let channel = snapshot.channel {
          let ready = earlyEOF.withLock { value in value.insert(channel); return value.count == 2 }
          if ready { try Data().write(to: exitGate) }
        }
        return try Response(status: response.status, headers: response.headers, body: .json(snapshot))
      }
      return response
    } })
    await hub.configureV2(service)
    let minted = try await space.mintExec(machine: record.id, group: .shared)
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: native ? ["/bin/sh", "-c", "printf hi; printf stderr >&2; exec 1>&- 2>&-; while [ ! -f '\(exitGate.path)' ]; do sleep .01; done; exit 7"] : ["echo-test"]))
    let backend = execBackend(space: space, hub: hub)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      tasks.addTask { try await service.run() }
      let transport = try await backend.connect(minted.id)
      tasks.addTask { await endpoint.run(transport) }
      defer { tasks.cancelAll() }
      if !fastExit, !native { try await outgoing.sendStdin(Array("input".utf8)) }; await outgoing.closeStdin()
      var stdout = Data(); var stderr = Data(); var status: MachineContract.ExitStatus?
      for try await event in outgoing.events {
        switch event {
        case let .output(stream, _, bytes):
          if stream == .stdout { stdout.append(contentsOf: bytes.bytes) } else { stderr.append(contentsOf: bytes.bytes) }
        case let .exit(value): status = value
        case let .failed(error): Issue.record("normal exec failed: \(error)")
        case .truncated: Issue.record("normal exec truncated")
        case .timedOut: Issue.record("normal exec timed out")
        }
      }
      #expect(stdout == Data((native ? "hi" : fastExit ? "fast" : "input").utf8)); #expect(stderr == Data("stderr".utf8)); #expect(status == .exited(code: 7))
      #expect(try await space.execRecord(minted.id)?.terminal == .exited(code: 7))
      if native { #expect(earlyEOF.withLock { $0 } == ["stdout", "stderr"]) }
      if lossy {
        // The terminal acknowledgement follows the caller's exit, and is retried once its first answer was lost.
        await acknowledgedAgain.wait()
        let faults = lost.withLock { $0 }
        #expect(Set(faults) == ["ack", "output", "stdin"])
        #expect(faults.count { $0 == "stdin" } >= 2)
      }
      await agent.shutdown(); await service.shutdown()
    }
  }

  @Test func rosterAndStatusUsePersistedPresenceRatherThanTunnelBinding() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "presence-v2", group: .shared)
    let hub = MachineHub(space: space)
    let handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: true, machineV2Hub: MachineV2Hub(space: space))
    for state: MachineV2Presence in [.attached, .lost, .detached] {
      try await space.recordMachineV2Presence(record.id.rawValue, group: .shared, state: state, description: state == .attached ? .init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: []) : nil, reason: "test")
      #expect(await hub.attachedMachines().contains(record.id) == (state == .attached))
      guard case let .response(response) = try await handler(Request(url: URL(string: "https://test.invalid/v1/machine-v2/" + record.id.rawValue)!)) else { Issue.record("status upgraded"); return }
      let status = try await response.body.json(JSONValue.self)
      #expect(status.object?["state"] == .string(state.rawValue))
      #expect(status.object?["attached"] == .bool(state == .attached))
      #expect(status.object?["observedAt"] != nil); #expect(status.object?["reason"] == "test")
    }
  }
}

extension MachineToolV2RoutingTests {
  @Test func missingKindStaysTypedThroughNormalHttpToolsAndExecMint() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "missing-kind-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
    await hub.configureV2(service)
    let handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: true)
    let request = Request(url: URL(string: "https://test.invalid/v1/tools/read")!, method: .post, body: try .json(JSONValue.object(["path": .string("machines://" + record.id.rawValue + "/file")])))
    guard case let .response(response) = try await handler(request) else { Issue.record("tool upgraded"); return }
    let body = try await response.body.json(JSONValue.self)
    #expect(body.object?["code"] == "unknownKind")
    #expect(body.object?["message"]?.stringValue?.contains("read.v1") == true)
    let mint = Request(url: URL(string: "https://test.invalid/v1/exec")!, method: .post, body: try .json(ExecMintInput(machine: record.id)))
    guard case let .response(refusal) = try await handler(mint) else { Issue.record("mint upgraded"); return }
    #expect(try await refusal.body.json(ErrorEnvelope.self).error.code == .unknownKind)
    #expect(try await space.liveExecs().isEmpty)
    await service.shutdown()
  }
}

extension MachineToolV2RoutingTests {
  @Test func execPreflightDefersKnownUnlinkedKindsToTheMachineGate() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "gated-kind-v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [], availability: .init { ["exec.v1": .unavailable(reason: "edition")] }, authorize: { _, _ in })
    let hub = MachineHub(space: space)
    let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in FetchClient { try await agent.handler($0) } })
    await hub.configureV2(service)
    try await hub.requireExecKind(record.id)
    #expect(try await space.liveExecs().isEmpty)
    await service.shutdown()
  }
}
