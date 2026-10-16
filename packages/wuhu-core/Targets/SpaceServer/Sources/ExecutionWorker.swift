import enum JSONValue.JSONValue
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
import struct Credentials.CredentialResolver
import Dependencies
import struct Fetch.FetchClient
import FetchAsyncHTTPClient
import InferenceKit
import Logging
import LoopCore
import class NIOPosix.MultiThreadedEventLoopGroup
import struct SessionDomain.ToolCallID
import SessionTools
import WorkerOwner
import WorkerProtocol
import enum WuhuAI.InferenceError

public enum ExecutionWorker {
  public static func run(bootstrap data: Data, release: String) async throws {
    guard data.count <= 16 << 10 else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution bootstrap exceeds limit") }
    let bootstrap = try JSONDecoder().decode(ExecutionWorkerBootstrap.self, from: data)
    if bootstrap.imageLease == true {
      var state = stat()
      guard fstat(3, &state) == 0, state.st_uid == geteuid(), state.st_mode & S_IFMT == S_IFREG,
            state.st_mode & 0o7777 == 0o600, state.st_nlink == 1, state.st_size == 0,
            fcntl(3, F_SETFD, FD_CLOEXEC) == 0 else { throw WorkerProtocolError(.invalidConfiguration, message: "Worker image lease is unavailable") }
    }
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    configuration.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 4096
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
    let telemetry: SpanBuffer?
    if bootstrap.telemetry == true {
      try await parent.requireCapability("telemetry.spans.v1")
      let buffer = SpanBuffer()
      ServerTracing.install { buffer.append($0) }
      telemetry = buffer
    } else { telemetry = nil }
    defer { if telemetry != nil { ServerTracing.install(nil) } }
    let owner = RemoteExecutionOwner(client: parent, tracesAttempts: bootstrap.tracesAttempts, machines: bootstrap.machines)
    let sockets = ResponsesSocketRegistry()
    let mirror = WorkerUsageMirror(owner: owner)
    let usage = mirror.board
    let attempts = AttemptHub()
    @Dependency(\.date) var date
    let catalogs: @Sendable (Bool) async throws -> ProviderCatalog = { includeGroups in
      try await mirror.synchronize()
      return ProviderCatalog(
        document: try await ModelsDocument(json: owner.modelDocument(), groupsJSON: includeGroups ? owner.modelGroupDocument() : nil),
        credentials: CredentialResolver.bound { try await owner.providerCredentialBinding($0) },
        oidcToken: { try await owner.inferenceToken(audience: $0, session: $1) },
        oidcReadiness: { try await owner.inferenceReadiness(audience: $0) },
        oidcBindingIdentity: { try await owner.inferenceBindingIdentity(audience: $0, session: $1) },
        receiveCodexResponseHeaders: { provider, headers in
          await mirror.record(provider, plan: headers["x-codex-plan-type"], windows: codexUsage(headers: headers), at: date.now)
        },
      )
    }
    let catalog: @Sendable () async throws -> ProviderCatalog = { try await catalogs(true) }
    let providerCatalog: @Sendable () async throws -> ProviderCatalog = { try await catalogs(false) }
    let scripts = Scripts(owner: owner, lifecycle: owner.scriptLifecycle)
    scripts.configureDiscovery(toolRosters: sessionToolRosters())
    let tools = ToolExecutor(owner: owner, credentials: CredentialResolver.bound { try await owner.providerCredentialBinding($0) }, completionCatalog: catalog, scripts: scripts, stopScript: { try await owner.stopRuntimeScript($0, script: $1) })
    let handlers = WorkerHandlerEndpoint(handler: ScriptHandlerExecutor(scripts: scripts, tools: tools))
    let budget = budgetResolver(owner: owner)
    let config = LoopConfig(
      executeTool: { try await tools.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
      inference: kernelInference(
        owner: owner,
        catalog: providerCatalog,
        groupCatalog: catalog,
        sockets: sockets,
        attempts: attempts,
        usage: usage,
        eventSink: .init { session, event in
          attempts.publish(session: session, event)
          try await owner.attemptEvents.publish(session: session, event)
        },
        synchronizeUsage: { try await mirror.synchronize() },
        receiveUsage: { await mirror.record($0, plan: $1, windows: $2, at: $3) },
        committedWarming: { session, policy in
          do { try await owner.scheduleCacheWarming(session, intervalSeconds: policy.intervalSeconds) }
          catch { Logger(label: "wuhu.worker").error("Cache warming schedule failed") }
        },
      ),
      compact: { id, transcript in await mechanicalCompaction(of: transcript, images: budget(id).images) },
      budget: budget,
      prepareCompaction: compactionPlacement(owner: owner, catalog: catalog, usage: usage),
      killInterruptedTool: { invocation in
        guard invocation.call.name == "exec" else { return }
        await owner.killInterruptedExec(session: invocation.sessionID, toolCallID: ToolCallID(invocation.call.id))
      },
      invalidateInference: { await sockets.invalidate($0) },
      allowCacheWarming: { try await owner.allowsCacheWarming($0) },
      scheduleWake: { try await owner.scheduleReminder($0, at: $1) },
      executionActivity: { id, pass, active in
        try await ExecutionWorkerActivity(session: id, pass: pass, active: active).publish(using: parent)
      },
    )
    let execution = await SessionExecution(owner: owner, loopConfig: config)
    let exportSpans: @Sendable ([FinishedSpan]) async throws -> Void = { spans in
      let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(spans))
      _ = try await parent.call(.init(operation: "telemetry.spans", payload: payload, traceContext: nil))
    }
    let operations = SessionExecutionEndpoint(execution: execution, scripts: scripts, attempts: attempts, owner: parent, beforeShutdownReply: {
      await handlers.shutdown()
      if let telemetry { await telemetry.shutdown(export: exportSpans) }
    })
    let endpoint = try OwnerByteEndpoint(invoke: { call in
      if call.operation == "handler.execute" || call.operation == "owner.cancel" { return try await handlers.invoke(call) }
      if call.operation == "execution.stop-script" {
        return try await WorkerScriptControl.invoke(call, scripts: scripts)
      }
      return try await operations.invoke(call)
    }).endpoint(token: bootstrap.token, hello: hello)
    let listener = try await WorkerListener.bind(socket: bootstrap.workerSocket, handler: endpoint.handler)
    let outcome: Result<Void, any Error>
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        if let telemetry {
          group.addTask {
            await telemetry.run(export: exportSpans)
          }
        }
        group.addTask { await listener.run() }
        group.addTask { await sockets.run() }
        group.addTask { await scripts.run(announceRestart: false) }
        _ = try await parent.call(.init(operation: "worker.ready", payload: .integer(Int(getpid()))))
        try await keepOwnerLease(parent)
      }
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await handlers.shutdown()
    await execution.shutdown()
    if let telemetry { await telemetry.shutdown(export: exportSpans) }
    await listener.shutdown()
    try outcome.get()
  }

  static func keepOwnerLease(_ parent: WorkerClient) async throws {
    @Dependency(\.continuousClock) var clock
    try await keepOwnerLease(parent, clock: clock)
  }

  private static func keepOwnerLease<C: Clock<Duration>>(_ parent: WorkerClient, clock: C) async throws {
    var delay = Duration.milliseconds(100)
    while !Task.isCancelled {
      let opened = clock.now
      do {
        let lease = try await parent.stream(.init(operation: "worker.lease"))
        for try await _ in lease.asyncBytes() {}
      } catch let error as WorkerProtocolError where error.code == .unavailable {}
      if opened.duration(to: clock.now) >= .seconds(5) { delay = .milliseconds(100) }
      while !Task.isCancelled {
        Logger(label: "wuhu.worker-reconnect").warning("Owner lease disconnected; retrying", metadata: ["delay": "\(delay)"])
        try await clock.sleep(for: delay)
        delay = min(delay * 2, .seconds(5))
        do { try await parent.reconnect(); break }
        catch let error as WorkerProtocolError where error.code == .unavailable { continue }
      }
    }
  }
}
