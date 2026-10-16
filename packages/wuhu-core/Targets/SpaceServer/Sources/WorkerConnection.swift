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
  var parentBinding: WorkerParentBinding? = nil
  var storage: ExecutionWorkerRuntimeStorage? = nil

  static func start(
    executable: String,
    owner: any ExecutionOwnerClient,
    spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned,
    runtime: WorkerRuntimeOwner? = nil,
    machines: Bool = false,
    persistence: ExecutionWorkerPersistence? = nil,
    incarnation: UUID = UUID(),
    credentialFence: ExecutionWorkerCredentialFence? = nil,
    activity: @escaping @Sendable (ExecutionWorkerActivity) async throws -> Void,
    exited: @escaping @Sendable () async -> Void,
  ) async throws -> Self {
    let storage = try await persistence?.allocate(incarnation: incarnation)
    let directory = storage?.location.directory ?? ("/tmp/wuhu-execution-" + UUID().uuidString)
    if storage == nil {
      guard mkdir(directory, 0o700) == 0 else { throw WorkerProtocolError(.unavailable, message: "Cannot create private execution directory") }
    }
    let bootstrap = ExecutionWorkerBootstrap(parentSocket: directory + "/parent.sock", workerSocket: directory + "/worker.sock", token: UUID().uuidString + UUID().uuidString, tracesAttempts: owner.tracesAttempts, machines: machines, telemetry: ServerTracing.enabled)
    let (ready, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (admitted, admission) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { admission.finish() }
    let hello = ExecutionWorkerBootstrap.hello(release: "parent")
    let emitSpan = ServerTracing.emitter
    let handoff = ParentExecutionHandoff(owner: owner, runtime: runtime, spawn: .init(spawn: spawn), control: { call in
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
        for await accepted in admitted { return .bool(accepted) }
        throw WorkerProtocolError(.unavailable, message: "Execution worker admission stopped")
      }
      throw WorkerProtocolError(.invalidMessage, message: "Unknown worker control")
    })
    let credentials = try WorkerCredentials(token: bootstrap.token, admission: { credentialFence?.admits($0) ?? true })
    let endpoint = try await handoff.endpoint(credentials: credentials, hello: hello)
    let transport: WorkerOwnerTransport
    do {
      transport = try await WorkerOwnerTransport.bind(socket: bootstrap.parentSocket, handler: endpoint.handler)
    } catch {
      if let storage { try? await storage.cleanup() } else { _ = rmdir(directory) }
      throw error
    }
    do { try await storage?.pinEndpoints() }
    catch {
      await transport.stop()
      try? await storage?.cleanup()
      throw error
    }
    let binding = WorkerParentBinding(handoff: handoff, transport: transport, credentials: credentials, hello: hello)
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
          _ = try? await Subprocess.run(.path(.init(executable)), arguments: ["_execution-worker"], environment: .custom([:]), platformOptions: options, input: .inputWriter, output: .discarded, error: .discarded) { execution in
            // The child cannot decode bootstrap or call the owner before its real OS identity is durable.
            try await storage?.persist(processID: execution.processIdentifier.value, token: bootstrap.token)
            try Task.checkCancellation()
            var offset = 0
            while offset < input.count {
              let written = try await execution.standardInputWriter.write(Array(input.dropFirst(offset)))
              guard written > 0 else { throw WorkerProtocolError(.unavailable, message: "Execution bootstrap input closed") }
              offset += written
            }
            try await execution.standardInputWriter.finish()
          }
          await client.close()
        }
        _ = await group.next()
        admission.finish()
        group.cancelAll()
      }
      continuation.finish()
      await client.close()
      await binding.shutdown()
      await transport.stop()
      try? await control.shutdown()
      try? await byteClient.shutdown()
      if let storage { try? await storage.cleanup() }
      else {
        _ = unlink(bootstrap.workerSocket)
        _ = rmdir(directory)
      }
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
      try await storage?.admit(processID: processID)
      if let storage { try await binding.bindIdentity(storage.checkpointIdentity()) }
      _ = try await client.negotiate(hello)
      admission.yield(true)
      return Self(processID: processID, client: client, lifetime: lifetime, ownerTransport: transport, parentBinding: binding, storage: storage)
    } catch {
      admission.finish()
      lifetime.cancel()
      await lifetime.value
      throw error
    }
  }

  func exportExec() async throws -> ExecWorkerExport {
    guard let storage, let parentBinding else { throw AdminExecError.refused("ephemeralWorker") }
    try await Self.requireExecIdle(client)
    let (transfer, listener) = try await parentBinding.exportExec()
    do {
      let record = try await storage.execRecord(carrier: transfer.descriptor, listener: listener)
      return .init(record: record, transfer: transfer, listener: listener)
    } catch { try await parentBinding.rollbackExec(); throw error }
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
