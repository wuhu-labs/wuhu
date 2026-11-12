import ControlledTime
import Dependencies
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

@Suite(.deterministicDependencies(clock: VirtualClock()), .timeLimit(.minutes(3))) struct MachineToolV2RoutingTests {
  @Test func normalFilesystemSearchAndExecPreflightUseOperations() async throws {
    let folder = try ScratchFolder("v2-normal-tools")
    let a = folder.url.appending(path: "z.txt")
    let b = folder.url.appending(path: "a.txt")
    try Data("needle one\nneedle two\nneedle three".utf8).write(to: a)
    try Data("other".utf8).write(to: b)
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "normal_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
    let hub = MachineHub(space: space)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }
      defer { tasks.cancelAll() }
      try await withMachineBox(space: space, hub: hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
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
      }
      await agent.shutdown()
    }
  }

  @Test(arguments: [false, true], [1, 2])
  func disappearedOperationRestartsOnceThenReportsRangeLoss(_ search: Bool, _ losses: Int) async throws {
    let folder = try ScratchFolder("v2-lost-operation")
    let path = folder.url.appending(path: "file.txt")
    try Data("needle".utf8).write(to: path)
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "lost_operation_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: fileOperationKinds(), authorize: { _, _ in })
    let admitted = Mutex<[String]>([])
    let hub = MachineHub(space: space)
    let client = FetchClient { request in
      let response = try await agent.handler(request)
      if request.url.path.contains("/operations/") {
        if request.method == .post, UUID(uuidString: request.url.lastPathComponent) != nil { admitted.withLock { $0.append(request.url.path) } }
        if request.method == .get, admitted.withLock({ $0.prefix(losses).contains(request.url.path) }) {
          return try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound, headers: response.headers)
        }
      }
      return response
    }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await agent.run() }; defer { tasks.cancelAll() }
      try await withMachineBox(space: space, hub: hub, machine: record.id, client: client) {
        do {
          let seam = machineSeam(hub: hub)
          if search {
            let page = try await seam.search(record.id, SearchQuery(mode: .grep, pattern: "needle", root: path.path, scope: "test"))
            #expect(page.hits.map(\.path) == [path.path])
          } else {
            let result = try await seam.vfs(record.id, .read(path: path.path))
            guard case let .file(_, bytes) = result else { Issue.record("Replacement read failed"); return }
            #expect(String(decoding: bytes.bytes, as: UTF8.self) == "needle")
          }
          #expect(losses == 1)
        } catch let ToolRunError.failed(code, message, _, _) {
          #expect(losses == 2)
          #expect(code == .unavailable); #expect(message.contains("rangeLost"))
        }
      }
      #expect(admitted.withLock { $0.count } == 2)
      await agent.shutdown()
    }
  }

  @Test func machineWithoutABoxIsUnavailable() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "offline_v2", group: .shared)
    let hub = MachineHub(space: space)
    do { _ = try await hub.vfs(machine: record.id, op: .stat(path: "/")); Issue.record("missing box admitted a file call") }
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
  @Test func obsoleteInputFaultDoesNotBlockTerminalAckRetry() async throws {
    try await withCellExecFixture { f in
      @Dependency(\.timeControl) var time
      let exec = MachineExec(id: "finished-input", operation: UUID(), createdAt: f.now, group: .shared, argv: ["held"], stdin: true)
      let stream = try await f.running(exec)
      let terminal = BoxPurpose.terminal("stdout")
      let tag = BoxTag.operation(exec.operation, terminal)
      f.answer(exec, .control, verdict: .init(.completed, result: ["termination": ["tag": "exit", "code": 0]]))
      try await f.wait { f.count(tag) == 1 }
      f.box.send(.init(tag: tag, answer: .transport(.init(.transport))))
      try await f.wait { f.space.worker.cell(f.cell).operation(exec.id)?.flights[terminal]?.waiting == false }
      let row = try #require(f.space.worker.cell(f.cell).operation(exec.id))
      #expect(row.snapshot?.verdict != nil)
      #expect(row.flights[.input] == nil)
      #expect(!row.terminal)
      let before = f.now
      let advanced = Gate()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { [time] in
          let machine = MachineID(rawValue: f.cell.key)
          let id = ExecID(rawValue: exec.id)
          try await advanceRoutedRetry(space: f.space, machine: machine, exec: id, purpose: .input, retried: Gate(), time: time)
          #expect(f.now == before)
          try await advanceRoutedRetry(space: f.space, machine: machine, exec: id, purpose: terminal, retried: Gate(), time: time)
          advanced.open()
        }
        defer { tasks.cancelAll() }
        try await f.wait { advanced.isOpen }
      }
      try await f.wait { f.count(tag) == 2 }
      stream.close()
    }
  }

  @Test(arguments: ["echo", "fast", "early-eof", "lossy"])
  func normalExecBackendBridgesStdinBothOutputsAndExit(mode: String) async throws {
    try await withDependencies {
      $0.installTimeControl()
    } operation: {
      @Dependency(\.timeControl) var time
      let phase = Mutex("setup")
      let trace = Mutex<[String]>([])
      let faults = AsyncStream<(BoxPurpose, Gate)>.makeStream()
      let retryWaiters = Mutex<[BoxPurpose: Gate]>([:])
      let fastExit = mode == "fast"
      let native = mode == "early-eof"
      let lossy = mode == "lossy"
      let earlyEOF = Mutex<Set<String>>([])
      let lost = Mutex<[String]>([])
      let acknowledgedAgain = Gate()
      let folder = try ScratchFolder("exec-early-eof")
      let exitGate = folder.url.appending(path: "exit")
      let space = try Space.inMemory()
      let (record, _) = try await space.addMachineV2(name: "exec_v2", group: .shared)
      let agent = try OperationAgent(machine: record.id.rawValue, kinds: [native ? .init(ExecKind()) : .init(RoutedEcho(fastExit: fastExit))], authorize: { _, _ in })
      let hub = MachineHub(space: space)
      let client = FetchClient { request in
        trace.withLock { value in
          value.append("request \(request.method) \(request.url.path) \(request.url.query ?? "")")
          value = Array(value.suffix(32))
        }
        let purpose: BoxPurpose?
        if request.method == .put, request.url.path.hasSuffix("/inputs/stdin") {
          purpose = .input
        } else if request.method == .get,
                  let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems,
                  let channel = query.first(where: { $0.name == "channel" })?.value
        {
          purpose = query.contains(where: { $0.name == "terminalAck" }) ? .terminal(channel) : .output(channel)
        } else { purpose = nil }
        if let purpose { retryWaiters.withLock { $0.removeValue(forKey: purpose) }?.open() }
        func lose(_ purpose: BoxPurpose) throws -> Never {
          let retried = Gate()
          retryWaiters.withLock { $0[purpose] = retried }
          faults.continuation.yield((purpose, retried))
          throw LostResponse()
        }
        if fastExit, request.method == .put, request.url.path.hasSuffix("/inputs/stdin") {
          var response = try Response.json(ErrorEnvelope(OperationError(.operationEnded)), status: .conflict)
          response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
          response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
          response.headers[.init("X-Wuhu-Agent-Instance")!] = UUID().uuidString
          return response
        }
        let response = try await agent.handler(request)
        trace.withLock { value in
          value.append("response \(response.status) \(request.method) \(request.url.path) \(request.url.query ?? "")")
          value = Array(value.suffix(32))
        }
        if lossy, request.url.query?.contains("terminalAck=") == true, lost.withLock({ $0.contains("ack") }) { acknowledgedAgain.open() }
        if lossy, request.method == .put, request.url.path.hasSuffix("/inputs/stdin") {
          let attempt = lost.withLock { value in value.append("stdin"); return value.count(where: { $0 == "stdin" }) }
          if attempt % 2 == 1 { try lose(.input) }
        }
        if lossy, request.method == .get, request.url.query?.contains("channel=") == true, response.status == .ok {
          let snapshot = try await response.body.json(OperationSnapshot.self)
          let drop = lost.withLock { value in
            let key = request.url.query?.contains("terminalAck=") == true ? "ack" : (snapshot.payload?.count ?? 0) > 0 ? "output" : nil
            guard let key, !value.contains(key) else { return false }
            value.append(key); return true
          }
          if drop {
            try lose(#require(purpose))
          }
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
      }
      let minted = try await space.reserveExec(machine: record.id, group: .shared)
      try await withTaskCancellationHandler {
        let endpoint = ChannelEndpoint()
        let outgoing = await endpoint.startExec(.init(id: minted.id, cwd: "/tmp", command: native ? ["/bin/sh", "-c", "printf hi; printf stderr >&2; exec 1>&- 2>&-; while [ ! -f '\(exitGate.path)' ]; do sleep .01; done; exit 7"] : ["echo-test"]))
        phase.withLock { $0 = "initial box describe" }
        try await withMachineBox(space: space, hub: hub, machine: record.id, client: client) { @Sendable [time] in
          try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask { await agent.run() }
            tasks.addTask { [time] in
              for await (purpose, retried) in faults.stream {
                trace.withLock { value in value.append("driving retry \(purpose)"); value = Array(value.suffix(32)) }
                try await advanceRoutedRetry(space: space, machine: record.id, exec: minted.id, purpose: purpose, retried: retried, time: time)
                trace.withLock { value in value.append("retry driven \(purpose)"); value = Array(value.suffix(32)) }
              }
            }
            phase.withLock { $0 = "connecting caller" }
            let transport = try await connectExecCaller(minted.id, space: space, hub: hub)
            tasks.addTask { await endpoint.run(transport) }
            defer { tasks.cancelAll() }
            phase.withLock { $0 = "sending stdin and EOF" }
            if !fastExit, !native { try await outgoing.sendStdin(Array("input".utf8)) }; await outgoing.closeStdin()
            phase.withLock { $0 = "collecting caller events" }
            var stdout = Data(); var stderr = Data(); var status: MachineContract.ExitStatus?
            for try await event in outgoing.events {
              trace.withLock { value in
                value.append("caller \(event)")
                value = Array(value.suffix(32))
              }
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
              phase.withLock { $0 = "waiting for terminal ACK reconciliation" }
              while !acknowledgedAgain.isOpen {
                try Task.checkCancellation()
                let settled = try await space.worker.call(MachineCell.ID(record.id.rawValue)) { cell in
                  let row = cell.operation(minted.id.rawValue)!
                  return (retired: row.terminal, drained: row.drained && row.diagnostic == nil)
                }
                if settled.retired {
                  // The box forgets only after both terminal ACKs apply, so a drained operation's 404 also settles a lost ACK answer.
                  #expect(settled.drained)
                  #expect(trace.withLock { $0.contains { $0.hasPrefix("response 404") } })
                  break
                }
              }
              try Task.checkCancellation()
              let faults = lost.withLock { $0 }
              #expect(Set(faults) == ["ack", "output", "stdin"])
              #expect(faults.count { $0 == "stdin" } >= 2)
            }
            phase.withLock { $0 = "agent shutdown" }
            await agent.shutdown()
            phase.withLock { $0 = "joining caller/retry taskgroup" }
          }
          phase.withLock { $0 = "closing BoxLink" }
        }
        phase.withLock { $0 = "closing space" }
        try await space.close()
      } onCancel: {
        let row = space.worker.cell(MachineCell.ID(record.id.rawValue)).operation(minted.id.rawValue)
        let pendingInput = row.flatMap { space.machineBuffers.input($0.request.operation, accepted: $0.stdin) }
        Issue.record("routed exec cancelled: mode=\(mode), phase=\(phase.withLock { $0 }), row=\(String(describing: row)), pendingInput=\(String(describing: pendingInput)), lost=\(lost.withLock { $0 }), retryWaiters=\(retryWaiters.withLock { $0.map { String(describing: $0.key) } }), earlyEOF=\(earlyEOF.withLock { $0 })\n\(trace.withLock { $0.joined(separator: "\n") })")
        if native {
          do { try Data().write(to: exitGate) }
          catch { Issue.record("could not release native exit gate: \(error)") }
        }
      }
    }
  }

  @Test func rosterAndStatusUsePersistedPresenceRatherThanTunnelBinding() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "presence_v2", group: .shared)
    let hub = MachineHub(space: space)
    let handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: true, listenerRoutes: machineListenerRoutes(space: space, hub: hub))
    for state: MachineV2Presence in [.attached, .lost] {
      try await space.worker.call(MachineCell.ID(record.id.rawValue)) { cell in
        try cell.ensurePresence()
        var presence = cell.presence
        presence.state = state.rawValue
        let description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [])
        presence.leaseMs = description.limits.leaseMs
        presence.pollHoldMs = description.limits.pollHoldMs
        presence.pollBytes = description.limits.pollBytes
        presence.resultBytes = description.limits.resultBytes
        presence.execStdoutWindow = nil
        presence.execStderrWindow = nil
        try cell.save(MachineDescriptionRow(description: description))
        presence.observed = cell.now
        try cell.save(presence)
      }
      #expect(await hub.attachedMachines().contains(record.id) == (state == .attached))
      guard case let .response(response) = try await handler(Request(url: URL(string: "https://test.invalid/v1/machine-v2/" + record.id.rawValue)!)) else { Issue.record("status upgraded"); return }
      let status = try await response.body.json(JSONValue.self)
      #expect(status.object?["state"] == .string(state.rawValue))
      #expect(status.object?["attached"] == .bool(state == .attached))
      #expect(status.object?["observedAt"] != nil)
      #expect(status.object?["reason"] == (state == .lost ? "leaseSilence" : nil))
    }
  }
}

extension MachineToolV2RoutingTests {
  @Test func missingKindStaysTypedThroughNormalHttpToolsAndExecMint() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "missing_kind_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [], authorize: { _, _ in })
    let hub = MachineHub(space: space)
    try await withMachineBox(space: space, hub: hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
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
    }
  }
}

extension MachineToolV2RoutingTests {
  @Test func execPreflightDefersKnownUnlinkedKindsToTheMachineGate() async throws {
    let space = try Space.inMemory()
    let (record, _) = try await space.addMachineV2(name: "gated_kind_v2", group: .shared)
    let agent = try OperationAgent(machine: record.id.rawValue, kinds: [], availability: .init { ["exec.v1": .unavailable(reason: "edition")] }, authorize: { _, _ in })
    let hub = MachineHub(space: space)
    try await withMachineBox(space: space, hub: hub, machine: record.id, client: FetchClient { try await agent.handler($0) }) {
      try await hub.requireExecKind(record.id)
      #expect(try await space.liveExecs().isEmpty)
    }
  }
}

private func advanceRoutedRetry(space: Space, machine: MachineID, exec: ExecID, purpose: BoxPurpose, retried: Gate, time: TimeControl) async throws {
  let cell = MachineCell.ID(machine.rawValue)
  while !retried.isOpen {
    try Task.checkCancellation()
    let state = try await space.worker.call(cell) { cell in
      let row = cell.operation(exec.rawValue)!
      return (terminal: row.terminal, hasVerdict: row.snapshot?.verdict != nil, waiting: row.flights[purpose]?.waiting, due: row.flights[purpose]?.due)
    }
    if state.terminal || purpose == .input && state.hasVerdict { return }
    if state.waiting == false, let due = state.due {
      @Dependency(\.date) var date
      await time.advance(to: max(date.now, Date(timeIntervalSince1970: Double(due + 1) / 1000)))
      try await space.worker.call(cell) { try $0.wake() }
      return
    }
    await Task.yield()
  }
}
