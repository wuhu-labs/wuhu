import Credentials
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import FetchTunnel
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import MachineContract
import OperationProtocol
import OperationRuntime
import Scratch
import Serve
import ServeTesting
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct SpaceHostExecShutdownTests {
  @Test func archiveKillsAndAcknowledgesAWorkerExecBeforeForgettingItsEnd() async throws {
    try await withSessionDeps {
      let space = try makeMachineSpace()
      _ = try await space.fs(.settings).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
      let server = TestServer(space: space, clock: ContinuousClock())
      let (machine, _) = try await addMachine(server)
      let side = ShutdownProcessSide()
      defer { side.release.open() }
      let agent = try OperationAgent(machine: machine.rawValue, kinds: [.init(ShutdownProcess(side: side))], authorize: { _, _ in })
      let counts = Mutex((stops: 0, acknowledgements: 0))
      let service = MachineV2Service(space: space, hub: MachineV2Hub(space: space), key: SymmetricKey(size: .bits256), failure: nil, fetch: { _ in
        FetchClient { request in
          if request.method == .put, request.url.path.hasSuffix("/stop") { counts.withLock { $0.stops += 1 } }
          let response = try await agent.handler(request)
          if request.url.query?.contains("terminalAck=") == true, response.status == .ok {
            counts.withLock { $0.acknowledgements += 1 }
          }
          return response
        }
      })
      await server.hub.configureV2(service)
      let runtime = await SessionRuntime.assemble(space: space, hub: server.hub, credentials: .unavailable)
      _ = SpaceServer.handler(space: space, hub: server.hub, sessions: runtime, dev: true)
      let session = try await space.sessions.createSession(
        group: .shared, title: "owed end", kind: .agent, createdBy: "owner",
        model: .init(provider: "testing", model: "test-model", effort: "high"),
      )
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await agent.run() }
        group.addTask { try await service.run() }
        defer { group.cancelAll(); side.release.open() }
        let outcome = try await runtime.inProcessWorker!.execute(session: session, call: ToolCall(
          id: "archive-live", name: "exec", arguments: .object([
            "machine": .string(machine.rawValue), "cwd": .string("/"), "command": .string("wait"), "wait_seconds": .number(0.01),
          ]),
        ), state: .init(folderRoots: ["machines://\(machine.rawValue)/": nil]))
        guard case .exec = outcome.payload else { Issue.record("expected a running exec"); return }
        await side.started.wait()
        let record = try #require(try await space.execRecord(caller: session.rawValue, toolCallID: .init("archive-live")))
        #expect(record.toolEndOwed)
        let token = runtime.tokens.sessionToken(session)
        try await runtime.service.archive(session)
        #expect(try await space.sessions.record(session).lifecycle != .live)
        #expect(try await space.execRecord(record.id)?.toolEndOwed == false)
        #expect(runtime.tokens.session(ofBearer: token) == nil)
        await side.stopped.wait()
        #expect(side.reason.withLock { $0 } == "callerCancelled")
        #expect(counts.withLock { $0.stops == 1 && $0.acknowledgements == 0 })
        side.release.open()
        try await until("the archived exec is killed and terminally acknowledged") {
          counts.withLock { $0.stops == 1 && $0.acknowledgements > 0 }
        }
        let operations = try await service.operations(group: .shared)
        try await until("the archived operation is settled") { await operations.running == 0 }
        let executor = SessionRuntime.toolExecutor(owner: runtime.owner)
        await executor.adoptExecJobs(of: session)
        await executor.adoptExecJobs(of: session)
        #expect(executor.runningExecJobs(of: session).isEmpty)
        #expect(try await space.owedExecs().isEmpty)
        #expect(counts.withLock { $0.stops == 1 })
        await runtime.workers.shutdown()
        await service.shutdown()
        await agent.shutdown()
      }
    }
  }

  @Test func shutdownDrainsLiveInProcessExecCaller() async throws {
    try await withSessionDeps {
      try await withDependencies {
        $0.fetch = FetchClient { _ in
          let events = [
            ("message_start", #"{"message":{"usage":{"input_tokens":10}}}"#),
            ("content_block_start", #"{"index":0,"content_block":{"type":"tool_use","id":"exec-call","name":"exec","input":{"machine":"box","cwd":"/","command":"wait","wait_seconds":90}}}"#),
            ("content_block_stop", #"{"index":0}"#),
            ("message_delta", #"{"delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#),
            ("message_stop", "{}"),
          ]
          let sse = events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined(separator: "")
          return Response(status: .ok, body: .bytes(Data(sse.utf8), contentType: "text/event-stream"))
        }
      } operation: {
        let folder = try scratchURL("host-live-exec")
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("config")
        let deployment = DeploymentRecord(origin: "https://exec.test", tlsFingerprint: "test", certificate: .provided)
        let host = try await SpaceHost.open(folder: folder, deployment: deployment, configDirectory: config, allowEnvironmentCredentials: false, dev: true)
        try await CredentialsStore(configDirectory: config, spaceID: host.id).save(CredentialsFile(providers: ["testing": .apiKey("test-key")]))
        _ = try await host.space.fs(.settings).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
        let api = ServeTesting.client(upgrading: host.handler)
        @Sendable func http(_ path: String, method: Fetch.Method = .get, body: JSONValue? = nil) async throws -> Response {
          var request = Request(url: URL(string: "https://exec.test\(path)")!, method: method)
          if let body { request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json") }
          return try await api(request)
        }
        let added = try await http("/v1/machine-v2", method: .post, body: .object(["name": .string("box")])).json(MachineAddOutput.self)
        let key = Curve25519.Signing.PrivateKey()
        let consumed = try await http("/v1/machine-v2/enroll", method: .post, body: .object(["token": .string(added.token), "pubkey": .string(key.pubkeyLabel)]))
        #expect(consumed.status == .ok)
        let challenge = try await http("/v1/machine-v2/challenge").json(MachineChallengeOutput.self).challenge
        var headers = RequestHeaders()
        headers.set("connection", "Upgrade")
        headers.set("upgrade", "websocket")
        headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        headers.set("sec-websocket-version", "13")
        headers.set("sec-websocket-protocol", TunnelTransport.webSocketSubprotocol)
        headers.set(MachineV2Connect.pubkeyHeader, key.pubkeyLabel)
        headers.set(MachineV2Connect.challengeHeader, challenge)
        headers.set(MachineV2Connect.machinesHeader, added.id.rawValue)
        headers.set(MachineV2Connect.signatureHeader, try key.signature(for: MachineV2Connect.signingPayload(challenge: challenge, machines: [added.id.rawValue])).base64EncodedString())
        let upgrade = try await host.handler(Request(url: URL(string: "https://exec.test/v1/machine-v2/connect")!, headers: headers))
        guard case let .boundedWebSocket(_, _, serve) = upgrade else { Issue.record("expected machine tunnel"); try await host.shutdown(); return }
        let side = ShutdownProcessSide()
        defer { side.release.open() }
        let agent = try OperationAgent(machine: added.id.rawValue, kinds: [.init(ShutdownProcess(side: side))], authorize: { _, _ in })
        let link = ShutdownTunnelLink()
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await host.run() }
          group.addTask { await serve(link.server) }
          group.addTask { await agent.run() }
          group.addTask {
            do { try await Tunnel.serve(over: link.machine, handler: agent.handler) }
            catch TunnelError.connectionClosed {}
            catch TunnelError.cancelled {}
          }
          defer { group.cancelAll(); side.release.open(); link.machine.abort() }
          try #require(try await realPollUntil {
            try await http("/v1/machine/box/status").json(MachineStatus.self).attached
          }, "the machine tunnel must be attached before the worker starts its exec")
          let session = try await host.space.sessions.createSession(group: .shared, title: "live exec", kind: .agent, createdBy: "owner", model: .init(provider: "testing", model: "test-model", effort: "high"))
          _ = try await host.space.sessions.enqueue(session, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("exec-wake"), content: .init(text: "run wait"))))
          try #require(try await realPollUntil { side.startedFlag.withLock { $0 } }, "the worker must start its operation through the attached tunnel")
          let drained = Mutex(false)
          let shutdown = Task {
            try await host.shutdown()
            drained.withLock { $0 = true }
          }
          #expect(try await realPollUntil { drained.withLock { $0 } }, "host shutdown must drain its live caller without waiting for the machine process verdict")
          side.release.open()
          await agent.shutdown()
          try await shutdown.value
          try await group.waitForAll()
        }
        let replacement = try await SpaceHost.open(folder: folder, deployment: deployment, configDirectory: config, allowEnvironmentCredentials: false)
        #expect(replacement.id == host.id)
        try await replacement.shutdown()
        try await host.shutdown()
      }
    }
  }
}

private final class ShutdownProcessSide: Sendable {
  let started = Gate()
  let startedFlag = Mutex(false)
  let stopped = Gate()
  let release = Gate()
  let reason = Mutex<String?>(nil)
}

private struct ShutdownProcess: OperationKind {
  let side: ShutdownProcessSide
  struct Input: Decodable, Sendable { let argv: [String]; let cwd: String; let stdin: Bool }
  let descriptor = ComputerKindSchemas.exec

  func run(_ input: Input, channels: OperationChannels, cancellation: OperationCancellation) async throws -> JSONValue {
    side.startedFlag.withLock { $0 = true }
    side.started.open()
    @Dependency(\.continuousClock) var clock
    while await cancellation.reason() == nil { try await clock.sleep(for: .milliseconds(2)) }
    let reason = await cancellation.reason()
    side.reason.withLock { $0 = reason }
    side.stopped.open()
    await side.release.wait()
    return ["termination": ["tag": "signal", "signal": 15]]
  }
}

private struct ShutdownTunnelLink {
  let server: TunnelTransport
  let machine: TunnelTransport

  init() {
    let (toServer, intoServer) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let (toMachine, intoMachine) = AsyncThrowingStream<Bytes, any Error>.makeStream()
    let serverReader = ShutdownTunnelReader(toServer), machineReader = ShutdownTunnelReader(toMachine)
    let abort: @Sendable () -> Void = { intoServer.finish(); intoMachine.finish() }
    server = TunnelTransport(receive: { try await serverReader.next() }, send: { intoMachine.yield($0) }, abort: abort)
    machine = TunnelTransport(receive: { try await machineReader.next() }, send: { intoServer.yield($0) }, abort: abort)
  }
}

private actor ShutdownTunnelReader {
  var iterator: AsyncThrowingStream<Bytes, any Error>.Iterator
  init(_ stream: AsyncThrowingStream<Bytes, any Error>) { iterator = stream.makeAsyncIterator() }
  func next() async throws -> Bytes? {
    var iterator = self.iterator
    let result = try await iterator.next(isolation: self)
    self.iterator = iterator
    return result
  }
}
