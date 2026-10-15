#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import class AsyncHTTPClient.HTTPClient
import FetchAsyncHTTPClient
import Logging
import class NIOPosix.MultiThreadedEventLoopGroup
import ServerTelemetry
import struct SpaceCore.SessionStore

struct ExecutionWorkerBootReconciliation {
  static func prepare(sessions: SessionStore? = nil, reconcile: @Sendable () async -> ExecutionWorkerBootFence.Result) async throws -> ExecutionWorkerBootFence.Result {
    var fence = await reconcile()
    try Task.checkCancellation()
    if !fence.unresolved.isEmpty || !fence.unresolvedWorkers.isEmpty {
      guard !fence.unresolved.isEmpty, !fence.unresolvedWorkers.isEmpty,
            fence.unresolvedWorkers.allSatisfy({ $0.processID != nil }),
            let sessions, let owned = try await sessions.sessionsOwnedByWorkers(fence.unresolved)
      else { throw ExecutionWorkerBootRefusal(workers: fence.unresolvedWorkers) }
      fence.blockedSessions = owned
    }
    return fence
  }

  static func run(configDirectory: URL?, space: String, executable: String? = nil) async -> ExecutionWorkerBootFence.Result {
    guard let configDirectory else {
      report(.missing)
      return .init(counts: [.missing: 1], credentials: .init())
    }
    let root = configDirectory.appendingPathComponent("workers").appendingPathComponent(space).path
    let storage = ExecutionWorkerBootStorage(root: root, space: space)
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.timeout.connect = .seconds(2)
    let client = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let process = ExecutionWorkerBootProcess(fetch: .asyncHTTPClient(client, timeout: .seconds(2)), executable: executable ?? "/proc/self/exe")
    let result = await ExecutionWorkerBootFence.reconcile(effects: .init(
      inventory: { await storage.inventory() },
      read: { await storage.read($0) },
      process: { ExecutionWorkerBootProcess.inspect($0) },
      terminate: { await process.terminate($0, directory: $1) },
      cleanup: { try await storage.cleanup($0) },
      report: report,
    ))
    try? await client.shutdown()
    return result
  }

  static func report(_ outcome: ExecutionWorkerBootFence.Outcome) {
    #if os(Linux)
      let kind = "linux_pidfd"
    #else
      let kind = "macos_no_pid_handle"
    #endif
    ServerSpan(.executionWorkerFence).finish([.outcome: outcome.rawValue, .kind: kind, .count: "1"])
    Logger(label: "wuhu.execution-boot").info("execution worker boot reconciliation", metadata: ["outcome": "\(outcome.rawValue)", "kind": "\(kind)", "count": "1"])
  }
}
