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
import CProcessIdentity
import Dependencies
import protocol ExecutionOwner.ExecutionOwnerClient
import FetchAsyncHTTPClient
import enum JSONValue.JSONValue
import NIOPosix
import ServerTelemetry
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID
import struct SessionTools.Spawned
import struct SessionTools.SpawnOrder
import WorkerOwner
import WorkerProtocol

extension WorkerConnection {
  static func adoptExec(_ record: ExecWorkerRecord, configDirectory: String?, owner: any ExecutionOwnerClient, spawn: @escaping @Sendable (SessionID, ToolCallID, SpawnOrder) async throws -> Spawned, runtime: WorkerRuntimeOwner?, credentialFence: ExecutionWorkerCredentialFence?, activity: @escaping @Sendable (ExecutionWorkerActivity) async throws -> Void, exited: @escaping @Sendable () async -> Void) async throws -> Self {
    guard let configDirectory else { throw AdminExecError.refused("workerStorage") }
    let manifest = try await record.manifest(configDirectory: configDirectory, space: record.space)
    let storage = try await ExecutionWorkerRuntimeStorage.adoptExec(record: record, manifest: manifest)
    let credentials = try WorkerCredentials(token: manifest.credentials.current, admission: { credentialFence?.admits($0) ?? true })
    let hello = ExecutionWorkerBootstrap.hello(release: "parent-exec")
    let handoff = try await ParentExecTransfer.take(record.carrier, expecting: record.identity, owner: owner, runtime: runtime, spawn: .init(spawn: spawn), control: { call in
      if call.operation == "worker.activity" {
        try await activity(ExecutionWorkerActivity(call: call))
        return .object(["value": .bool(true), "fault": .null])
      }
      if call.operation == "telemetry.spans" {
        let spans = try JSONDecoder().decode([FinishedSpan].self, from: Data(call.payload.jsonString().utf8))
        guard spans.count <= 64 else { throw WorkerProtocolError(.capacityExceeded, message: "Telemetry batch exceeds limit") }
        for span in spans { ServerTracing.emit(span) }
        return .bool(true)
      }
      throw WorkerProtocolError(.invalidMessage, message: "Unknown adopted worker control")
    })
    let endpoint = try await handoff.endpoint(credentials: credentials, hello: hello)
    let transport = try await WorkerOwnerTransport.adoptExec(record, socket: manifest.sockets!.parent, handler: endpoint.handler)
    let binding = WorkerParentBinding(handoff: handoff, transport: transport, credentials: credentials, hello: hello)
    try await binding.bindIdentity(record.identity)
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 4096
    let control = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let bytes = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
    let client = try WorkerClient(socket: manifest.workerSocket(directory: record.directory), credentials: credentials, control: .asyncHTTPClient(control, timeout: .seconds(10)), bytes: .asyncHTTPClient(bytes, timeout: nil))
    _ = try await client.negotiate(hello)
    try await RemoteSessionExecution(client: client).checkExec(record.fence, acceptingExpired: true)
    try await requireExecTransferable(client)
    // This is the original parent's direct child, not crash adoption. A failed WNOHANG ownership check refuses before any signal or normal scheduling.
    var status: Int32 = 0
    guard waitpid(record.processID, &status, WNOHANG) == 0 else { throw AdminExecError.refused("workerChildOwnership") }
    try await transport.commitExec(socket: manifest.sockets!.parent, identity: record.listenerIdentity.value)
    let lifetime = Task {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await transport.run() }
        group.addTask { await waitForExecChild(processID: record.processID, birth: record.birth) }
        _ = await group.next()
        group.cancelAll()
      }
      await client.close()
      await binding.shutdown()
      try? await control.shutdown()
      try? await bytes.shutdown()
      try? await storage.cleanup()
      await exited()
    }
    return .init(processID: record.processID, client: client, lifetime: lifetime, ownerTransport: transport, parentBinding: binding, storage: storage)
  }

  static func requireExecTransferable(_ client: WorkerClient) async throws {
    let inventory = try await RemoteSessionExecution(client: client).inventory()
    guard inventory.scripts.isEmpty,
          inventory.assignments.allSatisfy({ !$0.yielding && $0.archiveReservation == nil }),
          inventory.pendingOwnerCalls.isEmpty else { throw AdminExecError.refused("workerLiveExecution") }
  }

  static func requireExecIdle(_ client: WorkerClient) async throws {
    let inventory = try await RemoteSessionExecution(client: client).inventory()
    guard inventory.scripts.isEmpty, inventory.inferences.values.allSatisfy(\.isEmpty),
          inventory.assignments.allSatisfy({ $0.passes.isEmpty && $0.effect == nil && !$0.yielding && $0.archiveReservation == nil }),
          inventory.pendingOwnerCalls.allSatisfy(\.terminal) else { throw AdminExecError.refused("workerLiveExecution") }
  }

  static func waitForExecChild(processID: Int32, birth: String?, terminate: Bool = false) async {
    let handle = process_watch_child(processID)
    defer { if handle >= 0 { _ = close(handle) } }
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled && !terminate {
      var status: Int32 = 0
      let result = waitpid(processID, &status, WNOHANG)
      if result == processID || result < 0 && errno != EINTR { return }
      if handle >= 0, process_child_exited(handle) < 0 { break }
      do { try await clock.sleep(for: .milliseconds(100)) } catch { break }
    }
    // Only this lifetime reaps the inherited direct child. An unreaped child/zombie pins its PID, unlike an arbitrary boot manifest.
    var status: Int32 = 0
    guard waitpid(processID, &status, WNOHANG) == 0, (birth == nil || (try? processBirthIdentity(processID)) == birth) else { return }
    _ = kill(-processID, SIGTERM)
    let reaping = Task {
      for attempt in 0 ..< 30 {
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        if result == processID || result < 0 && errno != EINTR { return }
        if attempt == 20 { _ = kill(-processID, SIGKILL) }
        try? await clock.sleep(for: .milliseconds(100))
      }
    }
    await reaping.value
  }
}
