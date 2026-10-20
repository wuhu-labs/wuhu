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
import Testing

@Suite(.deterministicDependencies, .sessionFixtures(timeLimit: .minutes(1))) struct SpaceHostExecShutdownTests {
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
        _ = try await host.space.fs(.shared).write("/models.json", Data(testModelsJSON.utf8), ifMatch: nil)
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
