import protocol ExecutionOwner.ExecutionOwnerClient
import enum JSONValue.JSONValue
import WorkerOwner
import WorkerProtocol

actor WorkerParentBinding {
  private enum State { case active, busy, paused, stopped }
  private var handoff: ParentExecutionHandoff
  private let transport: WorkerOwnerTransport
  private let credentials: WorkerCredentials
  private let hello: WorkerHello
  private var state = State.active
  private var staged: ParentExecutionHandoff?
  private var identity: ParentExecutionIdentity?
  private var shutdownTask: Task<Void, Never>?

  init(handoff: ParentExecutionHandoff, transport: WorkerOwnerTransport, credentials: WorkerCredentials, hello: WorkerHello) {
    self.handoff = handoff; self.transport = transport; self.credentials = credentials; self.hello = hello
  }

  func prepare() async throws {
    guard case .active = state else { throw unavailable() }
    state = .busy
    do {
      try await handoff.prepare()
      try requireBusy()
      state = .paused
    } catch {
      if case .busy = state { state = .active }
      throw error
    }
  }

  func resume() async throws {
    guard case .paused = state else { throw unavailable() }
    state = .busy
    do {
      try await handoff.resume()
      try requireBusy()
      state = .active
    } catch {
      await shutdown()
      throw error
    }
  }

  func replace(owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil, control: @escaping @Sendable (WorkerCall) async throws -> JSONValue) async throws {
    guard case .paused = state else { throw unavailable() }
    state = .busy
    do {
      let replacement = try await handoff.transfer(to: owner, runtime: runtime, spawn: spawn, control: control)
      guard case .busy = state else { await replacement.shutdown(); throw unavailable() }
      handoff = replacement
      try Task.checkCancellation()
      try await replacement.resume()
      let endpoint = try await replacement.endpoint(credentials: credentials, hello: hello)
      try requireBusy()
      try await transport.replace(handler: endpoint.handler)
      try requireBusy()
      state = .active
    } catch {
      await shutdown()
      throw error
    }
  }

  func bindIdentity(_ identity: ParentExecutionIdentity) throws {
    guard case .active = state, self.identity == nil else { throw unavailable() }
    self.identity = identity
  }

  func replaceSerialized(owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil, control: @escaping @Sendable (WorkerCall) async throws -> JSONValue) async throws {
    guard case .paused = state else { throw unavailable() }
    state = .busy
    let original = handoff
    do {
      guard let identity else {
        try await original.resume()
        throw unavailable()
      }
      _ = try await original.restoreSerialized(identity: identity, to: owner, runtime: runtime, spawn: spawn, control: control, install: { replacement in
        try await self.install(replacement)
      })
    } catch {
      if case .busy = state { state = .active }
      throw error
    }
  }

  private func install(_ replacement: ParentExecutionHandoff) async throws {
    try requireBusy()
    let endpoint = try await replacement.endpoint(credentials: credentials, hello: hello)
    try requireBusy()
    try Task.checkCancellation()
    staged = replacement
    do { try await transport.replace(handler: endpoint.handler) }
    catch { staged = nil; throw error }
    handoff = replacement
    staged = nil
    if case .busy = state { state = .active }
  }

  func exportExec() async throws -> (ParentExecTransfer, WorkerListener.ListenerExport) {
    try await prepare()
    do {
      guard let identity else { throw AdminExecError.refused("workerIdentity") }
      let transfer = try await handoff.exportExec(identity: identity)
      let listener = try await transport.exportExec()
      return (transfer, listener)
    } catch {
      try await resume()
      throw error
    }
  }

  func probeExec() async throws { try await transport.probeExec(credentials: credentials, hello: hello) }

  func rollbackExec() async throws {
    try await resume()
    try await transport.resumeExec()
  }

  func shutdown() async {
    if let shutdownTask { await shutdownTask.value; return }
    state = .stopped
    let handoff = handoff, staged = staged, transport = transport
    let task = Task {
      await transport.stop()
      await handoff.shutdown()
      await staged?.shutdown()
    }
    shutdownTask = task
    await task.value
  }

  private func requireBusy() throws {
    guard case .busy = state else { throw unavailable() }
  }

  private func unavailable() -> WorkerProtocolError {
    .init(.unavailable, message: "Parent binding state does not allow this operation")
  }
}
