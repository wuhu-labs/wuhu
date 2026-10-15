import ServerTelemetry
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
import Dependencies
import protocol ExecutionOwner.ExecutionOwnerClient
import struct Fetch.Body
import FetchAsyncHTTPClient
import enum JSONValue.JSONValue
import class NIOPosix.MultiThreadedEventLoopGroup
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import Subprocess
import WorkerOwner
import WorkerProtocol

struct WorkerConnection: Sendable {
  let processID: Int32
  let client: WorkerClient
  let lifetime: Task<Void, Never>
  var ownerTransport: WorkerOwnerTransport? = nil

  static func start(
    executable: String,
    owner: any ExecutionOwnerClient,
    spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned,
    runtime: WorkerRuntimeOwner? = nil,
    machines: Bool = false,
    credentialFence: ExecutionWorkerCredentialFence? = nil,
    activity: @escaping @Sendable (ExecutionWorkerActivity) async throws -> Void,
    exited: @escaping @Sendable () async -> Void,
  ) async throws -> Self {
    let directory = "/tmp/wuhu-execution-" + UUID().uuidString
    guard mkdir(directory, 0o700) == 0 else { throw WorkerProtocolError(.unavailable, message: "Cannot create private execution directory") }
    let bootstrap = ExecutionWorkerBootstrap(parentSocket: directory + "/parent.sock", workerSocket: directory + "/worker.sock", token: UUID().uuidString + UUID().uuidString, tracesAttempts: owner.tracesAttempts, machines: machines, telemetry: ServerTracing.enabled)
    let parent = ParentExecutionEndpoint(owner: owner, runtime: runtime, spawn: .init(spawn: spawn))
    let (ready, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let hello = ExecutionWorkerBootstrap.hello(release: "parent")
    let emitSpan = ServerTracing.emitter
    let bytes = OwnerByteEndpoint(invoke: { call in
      if call.operation == "telemetry.spans" {
        let spans = try JSONDecoder().decode([FinishedSpan].self, from: Data(call.payload.jsonString().utf8))
        guard spans.count <= 64 else { throw WorkerProtocolError(.capacityExceeded, message: "Telemetry batch exceeds limit") }
        for span in spans {
          if let emitSpan { emitSpan(span) } else { ServerTracing.emit(span) }
        }
        return .bool(true)
      }
      if call.operation == "worker.activity" {
        try await activity(ExecutionWorkerActivity(call: call))
        return .object(["value": .bool(true), "fault": .null])
      }
      if call.operation == "worker.ready" {
        guard let value = call.payload.intValue, let pid = Int32(exactly: value), pid > 0 else { throw WorkerProtocolError(.invalidMessage, message: "Invalid worker admission") }
        continuation.yield(pid)
        return .bool(true)
      }
      return try await parent.invoke(call)
    }, upload: parent.upload, download: { call in
      if call.operation == "worker.lease" {
        return .stream(AsyncStream<Data> { _ in })
      }
      return try await parent.stream(call)
    }, acknowledged: parent.acknowledge)
    let credentials = try WorkerCredentials(token: bootstrap.token, admission: { credentialFence?.admits($0) ?? true })
    let endpoint = bytes.endpoint(credentials: credentials, hello: hello)
    let transport: WorkerOwnerTransport
    do { transport = try await WorkerOwnerTransport.bind(socket: bootstrap.parentSocket, handler: endpoint.handler) }
    catch { _ = rmdir(directory); throw error }
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 4096
    let control = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let byteClient = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let client = try WorkerClient(socket: bootstrap.workerSocket, credentials: credentials, control: .asyncHTTPClient(control, timeout: nil), bytes: .asyncHTTPClient(byteClient, timeout: nil))
    let input = try JSONEncoder().encode(bootstrap)
    let lifetime = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await transport.run() }
        group.addTask {
          var options = PlatformOptions()
          options.processGroupID = 0
          options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
          _ = try? await Subprocess.run(.path(.init(executable)), arguments: ["_execution-worker"], environment: .custom([:]), platformOptions: options, input: .array(Array(input)), output: .discarded, error: .discarded)
          await client.close()
        }
        _ = await group.next()
        group.cancelAll()
      }
      continuation.finish()
      await client.close()
      await bytes.shutdown()
      await parent.shutdown()
      await transport.stop()
      try? await control.shutdown()
      try? await byteClient.shutdown()
      _ = unlink(bootstrap.workerSocket)
      _ = rmdir(directory)
      await exited()
    }
    do {
      @Dependency(\.continuousClock) var clock
      let processID = try await withThrowingTaskGroup(of: Int32.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          var iterator = ready.makeAsyncIterator()
          guard let pid = await iterator.next() else { throw WorkerProtocolError(.unavailable, message: "Execution worker exited before admission") }
          return pid
        }
        group.addTask { [clock] in
          try await clock.sleep(for: .seconds(30))
          throw WorkerProtocolError(.unavailable, message: "Execution worker admission timed out")
        }
        return try await group.next()!
      }
      _ = try await client.negotiate(hello)
      return Self(processID: processID, client: client, lifetime: lifetime, ownerTransport: transport)
    } catch {
      lifetime.cancel()
      await lifetime.value
      throw error
    }
  }

  func stop() async {
    @Dependency(\.continuousClock) var clock
    await withTaskGroup(of: Void.self) { group in
      group.addTask { _ = try? await client.call(.init(operation: "execution.shutdown")) }
      group.addTask { [clock] in try? await clock.sleep(for: .seconds(2)) }
      _ = await group.next()
      group.cancelAll()
    }
    lifetime.cancel()
    await lifetime.value
  }
}
