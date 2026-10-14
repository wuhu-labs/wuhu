#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchExchangeRecording
import enum JSONValue.JSONValue
import OperationClient
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import struct OperationProtocol.WriteRequest
import Testing

private func canonicalBody(_ bytes: Data?) throws -> Data? {
  guard let bytes else { return nil }
  let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

private func canonicalAddress(_ url: URL) -> String {
  var address = URLComponents(url: url, resolvingAgainstBaseURL: false)!
  address.scheme = "http"; address.host = "recording"
  address.queryItems = address.queryItems?.filter { $0.name != "holdMs" && $0.name != "limit" }.sorted { $0.name < $1.name }
  if address.queryItems?.isEmpty == true { address.queryItems = nil }
  return address.url!.absoluteString
}

private actor ClientReplayTransport {
  let replay: FetchExchangeRecorder
  let description: MachineDescription
  init(_ recording: ExchangeRecording) throws {
    let exchanges = try recording.exchanges.map { exchange in
      RecordedExchange(request: .init(method: exchange.request.method, url: canonicalAddress(URL(string: exchange.request.url!)!), headers: exchange.request.headers, body: try canonicalBody(exchange.request.body)), response: exchange.response)
    }
    replay = FetchExchangeRecorder(replay: .init(exchanges: exchanges))
    description = MachineDescription(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec])
  }

  nonisolated var client: FetchClient { FetchClient { try await self.fetch($0) } }
  func fetch(_ request: Request) async throws -> Response {
    var response: Response
    if request.url.path == "/machine/v2/machines/test" { response = try .json(description) }
    else {
      let body = try await request.body?.bytes(upTo: 128 * 1024)
      var headers = Headers()
      if body != nil { headers[.contentType] = request.body?.contentType }
      let normalized = Request(url: URL(string: canonicalAddress(request.url))!, method: request.method, headers: headers, body: try canonicalBody(body).map { .bytes($0, contentType: request.body?.contentType) })
      response = try await replay.client(normalized)
    }
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.init("X-Wuhu-Agent-Instance")!] = response.headers[.init("X-Wuhu-Agent-Instance")!] ?? description.instance.uuidString
    return response
  }

  func complete() async throws { try await replay.assertComplete() }
}

@Suite struct RecordingReplayTests {
  @Test(arguments: ["backpressure", "daemon-detach", "process-group-stop", "agent-restart", "coordinator-cursor-handoff", "lease-expiry", "old-supervisor-new-agent", "service-manager", "recovery-isolation"])
  func productionClientCommitsRecordedOutputAndEvidenceOffline(_ name: String) async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings/" + name + ".json")
    let recording = try JSONDecoder().decode(ExchangeRecording.self, from: Data(contentsOf: url))
    let transport = try ClientReplayTransport(recording)
    let first = try #require(recording.exchanges.first)
    let id = try #require(UUID(uuidString: URL(string: first.request.url!)!.path.split(separator: "/")[5].description))
    let store = MemoryOperationStore()
    let owner = OperationOwner(scope: "recordings", key: name)
    func newClient() throws -> OperationClient {
      try OperationClient(origin: URL(string: "http://recording")!, fetch: transport.client, store: store, ids: { id }, abort: { _ in }, trace: { _ in })
    }
    var client = try newClient(); let description = try await client.describe("test")
    if first.request.method != "POST" {
      _ = try await store.claim(owner, record: ClientRecord(id: id, correlation: id, machine: "test", start: StartRequest(kind: "exec.v1", input: [:]), description: description))
    }
    var output = Data(); var terminal: OperationSnapshot?; var coordinatorRestarted = false
    do {
      for exchange in recording.exchanges {
        let address = URLComponents(string: exchange.request.url!)!
        let channel = address.queryItems?.first { $0.name == "channel" }?.value
        if exchange.request.method == "POST" {
          let start = try JSONDecoder().decode(StartRequest.self, from: exchange.request.body!)
          #expect(try await client.start("test", request: start, owner: owner) == id)
        } else if address.path.contains("/inputs/") {
          let write = try JSONDecoder().decode(WriteRequest.self, from: exchange.request.body!)
          let receipt = try await client.write(id, channel: "stdin", payload: write.payload, end: write.end)
          #expect(try await store.read(id).accepted["stdin"] == receipt.acceptedThrough)
        } else {
          let snapshot: OperationSnapshot
          if address.path.hasSuffix("/stop") {
            let stop = try JSONDecoder().decode(StopRequest.self, from: exchange.request.body!)
            snapshot = try await client.stop(id, reason: stop.reason)
          } else { snapshot = try await client.poll(id, channel: channel) }
          if snapshot.verdict != nil { terminal = snapshot }
          if channel == "stdout" {
            #expect(try await store.read(id).committed["stdout"] == snapshot.through)
            for payload in try await client.takeOutput(id, channel: "stdout") { output.append(payload.data ?? Data()) }
            if name == "coordinator-cursor-handoff" && !output.isEmpty && !coordinatorRestarted {
              await client.shutdown(); client = try newClient(); _ = try await client.describe("test"); coordinatorRestarted = true
            }
          }
        }
      }
      try await transport.complete()
      await client.shutdown()
    } catch { await client.shutdown(); throw error }
    #expect(terminal?.verdict != nil)
    switch name {
    case "backpressure": #expect(output == Data(repeating: 0, count: 320_000))
    case "daemon-detach": #expect(output == Data("direct".utf8))
    case "agent-restart": #expect(output == Data("***hello-after-restart".utf8))
    case "coordinator-cursor-handoff": #expect(output == Data("coordinatortail".utf8)); #expect(coordinatorRestarted)
    case "recovery-isolation": #expect(output == Data("recoverabletail".utf8))
    case "old-supervisor-new-agent":
      #expect(output == Data(repeating: 0, count: 300_000) + Data(String(repeating: "pending-input-", count: 3000).utf8))
      let provenance = try #require(recording.effects.first { $0.name == "oldSupervisor" })
      #expect(provenance.output["sha"]?.count == 40)
      #expect(provenance.output["newAgent"]?.count == 40)
      #expect(provenance.output["sha"] != provenance.output["newAgent"])
      let oldSHA = try #require(provenance.output["sha"])
      #expect(provenance.output["oldVersion"]?.contains("(" + oldSHA + ",") == true)
      #expect(provenance.output["oldBinarySHA256"]?.count == 64)
      #expect(provenance.output["newBinarySHA256"]?.count == 64)
      #expect(provenance.output["oldBinarySHA256"] != provenance.output["newBinarySHA256"])
    case "service-manager":
      #expect(output == Data(repeating: 0, count: 300_000) + Data("systemd-pending-input".utf8))
      let effect = try #require(recording.effects.first { $0.name == "systemdRestart" })
      #expect(effect.output["killMode"] == "process")
      #expect(effect.output["sameSupervisor"] == "True")
    case "process-group-stop", "lease-expiry":
      #expect(terminal?.verdict?.tag == .stopped)
      #expect(terminal?.verdict?.result == ["termination": ["tag": "signal", "signal": 9]])
    default: Issue.record("Unknown fixture")
    }
    #expect(recording.effects.contains { $0.name == "buildProvenance" && $0.output["newAgent"]?.count == 40 })
  }
}
