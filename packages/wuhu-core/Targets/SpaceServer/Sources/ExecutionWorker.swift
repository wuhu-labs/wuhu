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
import class AsyncHTTPClient.HTTPClient
import struct Credentials.CredentialResolver
import Dependencies
import struct Fetch.FetchClient
import FetchAsyncHTTPClient
import InferenceKit
import LoopCore
import class NIOPosix.MultiThreadedEventLoopGroup
import WorkerOwner
import WorkerProtocol
import enum WuhuAI.InferenceError

public enum ExecutionWorker {
  public static func run(bootstrap data: Data, release: String) async throws {
    guard data.count <= 16 << 10 else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution bootstrap exceeds limit") }
    let bootstrap = try JSONDecoder().decode(ExecutionWorkerBootstrap.self, from: data)
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    let control = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let bytes = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let result: Result<Void, any Error>
    do {
      try await run(bootstrap: bootstrap, release: release, control: .asyncHTTPClient(control, timeout: nil), bytes: .asyncHTTPClient(bytes, timeout: nil))
      result = .success(())
    } catch { result = .failure(error) }
    try await control.shutdown()
    try await bytes.shutdown()
    try result.get()
  }

  static func run(bootstrap: ExecutionWorkerBootstrap, release: String, control: FetchClient, bytes: FetchClient) async throws {
    let parent = try WorkerClient(socket: bootstrap.parentSocket, token: bootstrap.token, control: control, bytes: bytes)
    let hello = ExecutionWorkerBootstrap.hello(release: release)
    _ = try await parent.negotiate(hello)
    let owner = RemoteExecutionOwner(client: parent, tracesAttempts: bootstrap.tracesAttempts)
    let sockets = ResponsesSocketRegistry()
    let attempts = AttemptHub()
    let usage = UsageBoard()
    let catalog = groupCatalog(owner: owner)
    let budget = budgetResolver(owner: owner)
    let config = LoopConfig(
      executeTool: { _ in throw InferenceError.invalidInput(status: 501, body: "Tool execution is not enabled in the test-only execution worker") },
      inference: kernelInference(owner: owner, catalog: catalog, groupCatalog: catalog, sockets: sockets, attempts: attempts, usage: usage),
      compact: { id, transcript in await mechanicalCompaction(of: transcript, images: budget(id).images) },
      budget: budget,
      prepareCompaction: compactionPlacement(owner: owner, catalog: catalog, usage: usage),
      invalidateInference: { await sockets.invalidate($0) },
      executionActivity: { id, pass, active in
        _ = try await parent.call(ExecutionWorkerActivity(session: id, pass: pass, active: active).call())
      },
    )
    let execution = await SessionExecution(owner: owner, loopConfig: config)
    let operations = SessionExecutionEndpoint(execution: execution)
    let endpoint = try OwnerByteEndpoint(invoke: operations.invoke).endpoint(token: bootstrap.token, hello: hello)
    let listener = try await WorkerListener.bind(socket: bootstrap.workerSocket, handler: endpoint.handler)
    let outcome: Result<Void, any Error>
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask { await listener.run() }
        group.addTask { await sockets.run() }
        let lease = try await parent.stream(.init(operation: "worker.lease"))
        _ = try await parent.call(.init(operation: "worker.ready", payload: .integer(Int(getpid()))))
        for try await _ in lease.asyncBytes() {}
      }
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await execution.shutdown()
    await listener.shutdown()
    try outcome.get()
  }
}
