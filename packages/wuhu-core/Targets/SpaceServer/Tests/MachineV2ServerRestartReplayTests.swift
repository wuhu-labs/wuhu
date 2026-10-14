#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import FetchExchangeRecording
import GRDB
import enum JSONValue.JSONValue
import OperationClient
import OperationProtocol
import Scratch
@testable import SpaceCore
@testable import SpaceServer
import Testing

private struct ServerRestartFixture: Decodable, Sendable {
  struct Provenance: Decodable, Sendable {
    struct File: Decodable, Sendable { let path: String; let sha256: String; let requestID: String }
    let sourceSHA: String
    let binarySHA256: String
    let files: [File]
  }

  struct Channel: Decodable, Sendable { let name: String; let committed: Offset; let accepted: Offset }
  let provenance: Provenance
  let operation: UUID
  let machine: String
  let correlation: UUID
  let dispatchConsumed: Bool
  let consumedPrefix: String
  let channelsBeforeRestart: [Channel]
  let startExchange: RecordedExchange
  let descriptionExchange: RecordedExchange
  let prefixExchange: RecordedExchange
  let recovery: ExchangeRecording
  let childStopped: Bool
  let serverSIGKILLReturncode: Int
}

private func restartReplayAddress(_ value: String) throws -> URL {
  guard var url = URLComponents(string: value) else { throw RecordingError.invalidHead }
  url.scheme = "http"; url.host = "recording"; url.port = nil
  var query: [URLQueryItem] = []
  for item in url.queryItems ?? [] {
    switch item.name {
    case "holdMs":
      guard item.value == "0" || item.value == "20000" else { throw RecordingError.requestMismatch }
      if item.value == "20000" { query.append(item) }
    case "limit":
      guard item.value == "65536" else { throw RecordingError.requestMismatch }
    default: query.append(item)
    }
  }
  url.queryItems = query.sorted { $0.name < $1.name }
  if url.queryItems?.isEmpty == true { url.queryItems = nil }
  guard let result = url.url else { throw RecordingError.invalidHead }
  return result
}

private func restartReplayBody(_ body: Data?) throws -> Data? {
  guard let body else { return nil }
  let value = try JSONDecoder().decode(JSONValue.self, from: body)
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

private actor RestartReplayTransport {
  let replay: FetchExchangeRecorder
  private(set) var requests: [String] = []
  private(set) var failures: [String] = []
  init(exchanges: [RecordedExchange]) throws {
    let normalized = try exchanges.map { exchange in
      guard let method = exchange.request.method, let address = exchange.request.url,
            exchange.response.headers["x-wuhu-request-id"] == exchange.request.headers["x-wuhu-request-id"],
            exchange.response.headers["x-wuhu-correlation-id"] == exchange.request.headers["x-wuhu-correlation-id"],
            exchange.response.headers["x-wuhu-agent-instance"].flatMap(UUID.init(uuidString:)) != nil else { throw RecordingError.invalidHead }
      let headers = exchange.request.headers.filter { $0.key == "content-type" }
      return RecordedExchange(request: .init(method: method, url: try restartReplayAddress(address).absoluteString, headers: headers, body: try restartReplayBody(exchange.request.body)), response: exchange.response)
    }
    replay = FetchExchangeRecorder(replay: .init(exchanges: normalized))
  }

  nonisolated var client: FetchClient { FetchClient { try await self.fetch($0) } }
  private func fetch(_ request: Request) async throws -> Response {
    requests.append(request.method.rawValue + " " + request.url.absoluteString)
    do {
      let bytes = try await request.body?.bytes(upTo: 128 * 1024)
      var headers = Headers()
      if bytes != nil { headers[.contentType] = request.body?.contentType }
      let normalized = Request(
        url: try restartReplayAddress(request.url.absoluteString),
        method: request.method,
        headers: headers,
        body: try restartReplayBody(bytes).map { .bytes($0, contentType: request.body?.contentType) },
      )
      var response = try await replay.client(normalized)
      response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
      response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
      return response
    } catch { failures.append(String(describing: error)); throw error }
  }

  func assertComplete() async throws {
    #expect(failures.isEmpty)
    try await replay.assertComplete()
  }
}

@Suite struct MachineV2ServerRestartReplayTests {
  @Test func recordedRealServerRestartDrivesProductionRecoveryOffline() async throws {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings/machine-v2-server-restart.json")
    let fixture = try JSONDecoder().decode(ServerRestartFixture.self, from: Data(contentsOf: path))
    #expect(fixture.dispatchConsumed)
    #expect(fixture.childStopped)
    #expect(fixture.serverSIGKILLReturncode == -9)
    #expect(restartReplayHex(fixture.provenance.sourceSHA, count: 40))
    #expect(restartReplayHex(fixture.provenance.binarySHA256, count: 64))
    #expect(!fixture.provenance.files.isEmpty)
    #expect(fixture.provenance.files.allSatisfy { restartReplayHex($0.sha256, count: 64) && UUID(uuidString: $0.requestID) != nil })
    #expect(fixture.startExchange.request.method == "POST")
    #expect(fixture.startExchange.request.url?.contains(fixture.operation.uuidString) == true)
    #expect(fixture.consumedPrefix == "before")
    #expect(fixture.recovery.exchanges.allSatisfy { $0.request.method != "POST" })
    let start = try JSONDecoder().decode(StartRequest.self, from: #require(fixture.startExchange.request.body))
    let initialTransport = try RestartReplayTransport(exchanges: [fixture.descriptionExchange, fixture.prefixExchange])
    let folder = try ScratchFolder("machine-v2-real-restart-replay")
    let database = folder.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: database)
    let key = try await MachineV2KeyStore.loadOrCreate(directory: folder.url.appendingPathComponent("private-state"), space: space)
    let store = try await space.machineV2Store(group: .shared, key: key, problemsGroup: .shared)
    let original = try OperationClient(origin: URL(string: "http://recording")!, fetch: initialTransport.client, store: store, abort: { _ in }, trace: { _ in })
    let description = try await original.describe(fixture.machine)
    let record = ClientRecord(id: fixture.operation, correlation: fixture.correlation, machine: fixture.machine, start: start, description: description)
    let claim = try await store.claim(.init(scope: "recorded-dead-script", key: "server-restart"), record: record)
    #expect(claim.dispatch)
    #expect(try await space.writer.read { db in
      try Bool.fetchOne(db, sql: "SELECT dispatch_consumed FROM machine_v2_operations WHERE id = ?", arguments: [fixture.operation.uuidString]) == true
    })
    _ = try await original.poll(fixture.operation, channel: "stdout", holdMs: 20000)
    let prefix = try await original.takeOutput(fixture.operation, channel: "stdout").reduce(into: Data()) { $0.append($1.data ?? Data()) }
    #expect(prefix == Data(fixture.consumedPrefix.utf8))
    #expect(prefix.count == 6)
    #expect(try await store.read(fixture.operation).committed["stdout"] == .init(rawValue: 6))
    for channel in fixture.channelsBeforeRestart {
      #expect(channel.accepted == .zero)
      #expect(channel.committed == (channel.name == "stdout" ? .init(rawValue: 6) : .zero))
    }
    await original.shutdown()
    try await initialTransport.assertComplete()

    let reopened = try Space.open(file: database)
    let reopenedKey = try await MachineV2KeyStore.loadOrCreate(directory: folder.url.appendingPathComponent("private-state"), space: reopened)
    let restored = try await reopened.machineV2Store(group: .shared, key: reopenedKey, problemsGroup: .shared)
    let recoveryTransport = try RestartReplayTransport(exchanges: fixture.recovery.exchanges)
    let coordinator = MachineV2Coordinator(
      space: reopened,
      key: reopenedKey,
      problemsGroup: .shared,
      origin: URL(string: "http://recording")!,
      fetch: { _ in recoveryTransport.client },
      abort: { _, _ in },
    )
    try await coordinator.prepare()
    #expect(await recoveryTransport.requests.isEmpty)
    let prepared = try await restored.read(fixture.operation)
    #expect(prepared.committed["stdout"] == .init(rawValue: 6))
    #expect(prepared.stopReason == "serverRestart")
    #expect(prepared.output.isEmpty)
    for _ in 0 ... fixture.recovery.exchanges.count { try await coordinator.tick() }
    try await recoveryTransport.assertComplete()
    let final = try await restored.read(fixture.operation)
    #expect(final.unknown == nil)
    #expect(final.snapshot?.verdict?.tag == .stopped)
    #expect(final.snapshot?.verdict?.reason == "serverRestart")
    #expect(final.snapshot?.outputConsumed == true)
    #expect(final.output.isEmpty)
    #expect(final.committed["stdout"] == final.snapshot?.finalOffsets["stdout"])
    #expect(final.committed["stderr"] == final.snapshot?.finalOffsets["stderr"])
    let recordedTerminal = try JSONDecoder().decode(OperationSnapshot.self, from: #require(fixture.recovery.exchanges.last?.response.body))
    #expect(recordedTerminal.outputConsumed)
    #expect(final.snapshot?.verdict == recordedTerminal.verdict)
    #expect(final.committed["stdout"] == recordedTerminal.finalOffsets["stdout"])
    #expect(final.committed["stderr"] == recordedTerminal.finalOffsets["stderr"])
    let requests = await recoveryTransport.requests
    #expect(requests.allSatisfy { !$0.hasPrefix("POST ") })
    #expect(requests.contains { $0.hasPrefix("PUT ") && $0.contains("/stop") })
    #expect(requests.contains { $0.contains("channel=stdout") && $0.contains("after=6") })
    #expect(!requests.contains { $0.contains("channel=stdout") && $0.contains("after=0") })
    #expect(requests.contains { $0.contains("terminalAck=") })
    let before = requests.count
    try await coordinator.tick()
    #expect(await recoveryTransport.requests.count == before)
    await coordinator.shutdown()
  }
}

private func restartReplayHex(_ value: String, count: Int) -> Bool {
  value.utf8.count == count && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
}
