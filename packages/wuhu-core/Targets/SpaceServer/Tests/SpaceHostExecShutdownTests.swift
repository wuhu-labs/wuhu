import Credentials
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import MachineChannel
import MachineContract
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
      let (machine, key) = try await addMachine(server)
      let runtime = await SessionRuntime.assemble(space: space, hub: server.hub, credentials: .unavailable)
      _ = SpaceServer.handler(space: space, hub: server.hub, sessions: runtime, dev: true)
      let session = try await space.sessions.createSession(
        group: .shared, title: "owed end", kind: .agent, createdBy: "owner",
        model: .init(provider: "testing", model: "test-model", effort: "high"),
      )
      let counts = ArchiveRelayCounts()
      let started = Gate()
      let release = Gate()
      let endpoint = ChannelEndpoint()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await server.run() }
        let socket = try await connectMachine(server, key: key)
        defer { socket.close(); group.cancelAll() }
        group.addTask { await endpoint.run(ArchiveMachineTransport(base: WebSocketTransport(socket), counts: counts)) }
        group.addTask {
          for await exec in endpoint.incomingExecs {
            started.open()
            for await _ in exec.kills {
              await release.wait()
              await exec.exit(.signaled(signal: 15))
              break
            }
          }
        }
        try await awaitAttached(server, machine)
        let outcome = try await runtime.inProcessWorker!.execute(session: session, call: ToolCall(
          id: "archive-live", name: "exec", arguments: .object([
            "machine": .string(machine.rawValue), "cwd": .string("/"), "command": .string("wait"), "wait_seconds": .number(0.01),
          ]),
        ), state: .init(folderRoots: ["machines://\(machine.rawValue)/": nil]))
        guard case .exec = outcome.payload else { Issue.record("expected a running exec"); return }
        await started.wait()
        let record = try #require(try await space.execRecord(caller: session.rawValue, toolCallID: .init("archive-live")))
        #expect(record.toolEndOwed)
        let token = runtime.tokens.sessionToken(session)
        try await runtime.service.archive(session)
        #expect(try await space.sessions.record(session).lifecycle != .live)
        #expect(try await space.execRecord(record.id)?.toolEndOwed == false)
        #expect(runtime.tokens.session(ofBearer: token) == nil)
        release.open()
        try await until("the archived exec is killed and terminally acknowledged") {
          counts.state.withLock { $0.kills == 1 && $0.acks == 1 }
        }
        let executor = SessionRuntime.toolExecutor(owner: runtime.owner)
        await executor.adoptExecJobs(of: session)
        await executor.adoptExecJobs(of: session)
        #expect(executor.runningExecJobs(of: session).isEmpty)
        #expect(try await space.owedExecs().isEmpty)
        #expect(counts.state.withLock { $0.kills == 1 && $0.acks == 1 })
        await runtime.workers.shutdown()
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
        func http(_ path: String, method: Fetch.Method = .get, body: JSONValue? = nil) async throws -> Response {
          var request = Request(url: URL(string: "https://exec.test\(path)")!, method: method)
          if let body { request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json") }
          return try await api(request)
        }
        let added = try await http("/v1/machine", method: .post, body: .object(["name": .string("box")])).json(MachineAddOutput.self)
        let key = Curve25519.Signing.PrivateKey()
        let consumed = try await http("/v1/enroll/consume", method: .post, body: .object(["token": .string(added.token), "pubkey": .string(key.pubkeyLabel)]))
        #expect(consumed.status == .ok)
        let challenge = try await http("/v1/machine/challenge").json(MachineChallengeOutput.self).challenge
        var headers = RequestHeaders()
        headers.set("connection", "Upgrade")
        headers.set("upgrade", "websocket")
        headers.set("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        headers.set("sec-websocket-version", "13")
        headers.set(MachineConnect.pubkeyHeader, key.pubkeyLabel)
        headers.set(MachineConnect.challengeHeader, challenge)
        headers.set(MachineConnect.signatureHeader, try key.signature(for: MachineConnect.signingPayload(challenge: challenge)).base64EncodedString())
        let upgrade = try await ServeTesting.upgrade(host.handler, Request(url: URL(string: "https://exec.test/v1/machine/connect")!, headers: headers))
        guard case let .webSocket(machine, serve) = upgrade else { Issue.record("expected machine socket"); try await host.shutdown(); return }
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await host.run() }
          group.addTask { await serve() }
          let session = try await host.space.sessions.createSession(group: .shared, title: "live exec", kind: .agent, createdBy: "owner", model: .init(provider: "testing", model: "test-model", effort: "high"))
          _ = try await host.space.sessions.enqueue(session, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("exec-wake"), content: .init(text: "run wait"))))
          var started = false
          for await message in machine.inbound {
            if case let .binary(bytes) = message, try FrameCodec.decode(bytes).opcode == .execStart {
              started = true
              break
            }
          }
          #expect(started)
          try await host.shutdown()
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

private final class ArchiveRelayCounts: Sendable {
  let state = Mutex((kills: 0, acks: 0))
}

private struct ArchiveMachineTransport: FrameTransport {
  let base: any FrameTransport
  let inbound: AsyncStream<[UInt8]>

  init(base: any FrameTransport, counts: ArchiveRelayCounts) {
    self.base = base
    inbound = AsyncStream { continuation in
      let task = Task {
        for await bytes in base.inbound {
          if let frame = try? FrameCodec.decode(bytes) {
            if frame.opcode == .kill { counts.state.withLock { $0.kills += 1 } }
            if frame.opcode == .ack, let ack = try? frame.payload(Ack.self), ack.terminal == true {
              counts.state.withLock { $0.acks += 1 }
            }
          }
          continuation.yield(bytes)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func send(_ bytes: [UInt8]) async throws { try await base.send(bytes) }
  func close() { base.close() }
}
