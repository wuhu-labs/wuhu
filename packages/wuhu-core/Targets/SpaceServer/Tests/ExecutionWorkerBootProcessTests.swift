#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import ExecutionOwner
import Fetch
import SpaceCore
@testable import SpaceServer
import Testing
import WorkerOwner
import WorkerProtocol

@Suite(.sessionFixtures(timeLimit: .minutes(1))) struct ExecutionWorkerBootProcessTests {
  @Test(arguments: ["stale-credential", "wrong-executable", "transport-failure", "reused-pid", "authenticated-ack", "authenticated-no-ack"], [1, 2])
  func bootFenceAuthenticatesOrChecksOSIdentityBeforeSignallingARealWorker(kind: String, version: Int) async throws {
    try await withSessionDeps {
      let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])).standardizedFileURL.path
      let space = try Space.inMemory()
      let connection = try await WorkerConnection.start(executable: binary, owner: InProcessExecutionOwnerClient(space: space), spawn: { _, _, _ in throw CancellationError() }, activity: { _ in }, exited: {})
      defer { connection.lifetime.cancel() }
      let generation = UUID()
      let directory = version == 1 ? "/private/fixture" : "/private/" + String(repeating: "long-canonical-config-path/", count: 8)
      let location = version == 2 ? ExecutionWorkerSocketLocation(space: "space", generation: generation) : nil
      let manifest = ExecutionWorkerManifest(version: version, space: "space", generation: generation, incarnation: UUID(), processID: connection.processID, birth: kind == "reused-pid" ? "different-birth-identity" : try processBirthIdentity(connection.processID), credentials: .init(current: String(repeating: "a", count: 72), successor: String(repeating: "b", count: 72)), sockets: location)
      try manifest.validate(directory: directory, space: "space")
      let endpoint = try WorkerEndpoint(token: manifest.credentials.current, hello: ExecutionWorkerBootstrap.hello(release: "fixture").retainingReplies(UUID()), invoke: { call in
        #expect(call.operation == "execution.shutdown")
        return .bool(kind == "authenticated-ack")
      }, upload: { _, _ in }, download: { _ in .empty })
      let fetch = FetchClient { request in
        #expect(request.url.host?.removingPercentEncoding == manifest.workerSocket(directory: directory))
        if kind.hasPrefix("authenticated-") { return try await endpoint.handler(request) }
        if kind == "reused-pid" { Issue.record("A reused PID must not be authenticated") }
        throw WorkerProtocolError(kind == "transport-failure" ? .unavailable : .unauthorized, message: "fixture")
      }
      let process = ExecutionWorkerBootProcess(fetch: fetch, executable: kind == "wrong-executable" ? "/dev/null" : binary)
      let outcome = await process.terminate(manifest, directory: directory)
      #if os(Linux)
        switch (kind, outcome) {
        case ("stale-credential", .staleCredentialExited), ("wrong-executable", .unsafeProcessIdentity), ("transport-failure", .unconfirmed), ("reused-pid", .exited), ("authenticated-ack", .exited), ("authenticated-no-ack", .exited): break
        default: Issue.record("Unexpected OS worker fence result")
        }
        let terminated = switch outcome { case .exited, .staleCredentialExited: true; default: false }
        if terminated, kind != "reused-pid" {
          await connection.lifetime.value
          if case .absent = ExecutionWorkerBootProcess.inspect(manifest) {} else { Issue.record("Worker survived pidfd termination") }
        } else {
          #expect(try processBirthIdentity(connection.processID) != "different-birth-identity")
          _ = try await connection.client.negotiate(ExecutionWorkerBootstrap.hello(release: "test"))
        }
      #else
        if kind == "reused-pid" {
          if case .exited = outcome {} else { Issue.record("Reused process was not treated as old-worker gone") }
        } else if kind == "authenticated-ack" {
          if case .acknowledgedWithoutPIDHandle = outcome {} else { Issue.record("Authenticated macOS shutdown must be a typed partial fence") }
        } else {
          if case .unconfirmed = outcome {} else { Issue.record("macOS must not signal without a PID handle") }
        }
        #expect(try processBirthIdentity(connection.processID) != "different-birth-identity")
      #endif
      await connection.stop()
    }
  }
}
