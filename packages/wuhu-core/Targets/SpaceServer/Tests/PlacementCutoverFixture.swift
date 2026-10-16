#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import AsyncHTTPClient
import Fetch
import JSONValue
import NIOPosix
import ServeNIO
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Subprocess
import Synchronization
import Testing
import WorkerProtocol

struct PlacementCutoverFixture: Sendable {
  let files: PersistenceFixture
  let folder: URL
  let space: Space
  let binary: String
  let port: Int
  let spaceID: String

  static func make(providerPort: Int) async throws -> Self {
    let files = try PersistenceFixture(root: #require(ProcessInfo.processInfo.environment["TEST_TMPDIR"]))
    let folder = URL(fileURLWithPath: files.base + "/space")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let space = try Space.open(file: folder.appendingPathComponent("space.sqlite"))
    let model = "{\"offline\":{\"dialect\":\"anthropic\",\"baseURL\":\"http://127.0.0.1:\(providerPort)\",\"opaqueReplay\":\"none\",\"models\":{\"small\":{\"maxInput\":100000,\"maxOutput\":1000,\"efforts\":[\"none\"],\"defaultEffort\":\"none\"}}}}"
    _ = try await space.fs(.shared).write("/models.json", Data(model.utf8), ifMatch: nil)
    let reservation = try await ServeNIOServer.bind(port: 0, handler: { _ in .text("reserved") })
    let port = try #require(reservation.localAddress?.port)
    await reservation.shutdown()
    return try await Self(files: files, folder: folder, space: space, binary: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path, port: port, spaceID: space.identity().rawValue)
  }

  func session(_ title: String, kind: SessionKind = .agent, parent: SessionID? = nil) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: title, kind: kind, parent: parent, createdBy: parent?.rawValue ?? "owner", executor: .kernel(.init(provider: "offline", model: "small", effort: "none")))
  }

  func enqueue(_ id: SessionID, _ text: String) async throws {
    _ = try await space.sessions.enqueue(id, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("fixture"), content: .init(text: text))))
  }

  func write(_ path: String, _ source: String) async throws {
    _ = try await space.fs(.shared).write(path, Data(source.utf8), ifMatch: nil)
  }

  func exists(_ path: String) async -> Bool { (try? await space.fs(.shared).stat(path)) != nil }

  func worker() async throws -> ExecutionWorkerManifest? {
    let root = files.config + "/workers/" + spaceID
    for entry in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
      if let store = try? await ExecutionWorkerManifestStore.open(directory: root + "/" + entry, space: spaceID), let manifest = try? await store.load() { return manifest }
    }
    return nil
  }

  func completed(_ id: SessionID) async throws -> Bool {
    try await space.sessions.transcript(id).items.contains { item in
      if case let .assistant(entry) = item { entry.content.contains(.text("cutover finished")) } else { false }
    }
  }

  func serve(_ placement: String? = nil, stopSignal: Int32 = SIGTERM, body: @escaping @Sendable (Int32) async throws -> Void) async throws {
    var environment: [Environment.Key: String] = ["PATH": "/usr/bin:/bin", "HOME": files.base, "WUHU_CONFIG_DIR": files.config, "OFFLINE_API_KEY": "fixture"]
    for key in ["SDKROOT", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_LIBRARY_PATH"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[Environment.Key(stringLiteral: key)] = value }
    }
    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(2)), .send(signal: .kill, toProcessGroup: true, allowedDurationToNextStep: .seconds(1))]
    let label = placement ?? "default"
    let log = files.base + "/" + label + ".log"
    let selection = placement.map { " --execution-placement \($0)" } ?? ""
    let command = "exec '\(binary)' serve '\(folder.path)' --port \(port) --public-read\(selection) 2> '\(log)'"
    do {
      let result = try await Subprocess.run(.path("/bin/sh"), arguments: ["-c", command], environment: .custom(environment), platformOptions: options, input: .none, output: .discarded, error: .discarded) { process in
        try await ready()
        #expect(!FileManager.default.fileExists(atPath: folder.path + "/.admin-exec"))
        try await body(process.processIdentifier.value)
        #expect(kill(process.processIdentifier.value, stopSignal) == 0)
      }
      if stopSignal == SIGTERM { #expect(result.terminationStatus == .exited(0)) }
      else { #expect(result.terminationStatus != .exited(0)) }
    } catch {
      if let text = try? String(contentsOfFile: log, encoding: .utf8) { Issue.record("Cutover \(label) server log: \(text)") }
      throw error
    }
  }

  private func ready() async throws {
    var configuration = HTTPClient.Configuration()
    configuration.tlsConfiguration = .makeClientConfiguration()
    configuration.tlsConfiguration?.certificateVerification = .none
    let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let outcome: Result<Void, any Error>
    let last = Mutex("no readiness request")
    do {
      try await until("real production serve accepts TLS", timeout: .seconds(30)) {
        do {
          let response = try await client.execute(HTTPClientRequest(url: "https://127.0.0.1:\(port)/v1/server"), timeout: .seconds(1))
          _ = try await response.body.collect(upTo: 65536)
          last.withLock { $0 = "HTTP \(response.status.code)" }
          return response.status.code == 200
        } catch {
          last.withLock { $0 = String(describing: error) }
          return false
        }
      }
      outcome = .success(())
    } catch { Issue.record("TLS readiness: \(last.withLock { $0 })"); outcome = .failure(error) }
    try await client.shutdown()
    try outcome.get()
  }
}

func cutoverReply(source: String? = nil) -> Response {
  let block: JSONValue = source == nil ? ["type": "text", "text": ""] : ["type": "tool_use", "id": "cutover-script", "name": "run_script", "input": [:]]
  let delta: JSONValue = source.map { ["type": "input_json_delta", "partial_json": .string(JSONValue.object(["source": .string($0), "timeout_seconds": 10, "on_timeout": "kill"]).jsonString())] } ?? ["type": "text_delta", "text": "cutover finished"]
  let events: [(String, JSONValue)] = [
    ("message_start", ["message": ["usage": ["input_tokens": 10]]]),
    ("content_block_start", ["index": 0, "content_block": block]),
    ("content_block_delta", ["index": 0, "delta": delta]),
    ("content_block_stop", ["index": 0]),
    ("message_delta", ["delta": ["stop_reason": .string(source == nil ? "end_turn" : "tool_use")], "usage": ["output_tokens": 1]]),
    ("message_stop", [:]),
  ]
  return .init(status: .ok, body: .bytes(Data(events.map { "event: \($0.0)\ndata: \($0.1.jsonString())\n\n" }.joined().utf8), contentType: "text/event-stream"))
}
