import class WorkerProtocol.WorkerListener

struct ParentExecSource: Sendable {
  let execution: ParentExecutionHandoff
  let listener: WorkerListener

  struct Export: Sendable {
    let carrier: ParentCheckpointCarrier
    let listener: WorkerListener.ListenerExport
  }

  // The coordinator serializes prepare/rollback/finish and confirms successor readiness out of band.
  func prepare(identity: ParentExecCheckpoint.Identity) async throws -> Export {
    try await execution.prepare()
    var paused = false
    do {
      try await listener.pauseAccepting()
      paused = true
      let carrier = try await execution.execCarrier(identity: identity)
      let exported = try await listener.exportListener()
      return Export(carrier: carrier, listener: exported)
    } catch {
      let resumeListener = paused
      try await Task {
        try await execution.resume()
        if resumeListener { try await listener.resumeAccepting() }
      }.value
      throw error
    }
  }

  func rollback() async throws {
    try await execution.resume()
    try await listener.resumeAccepting()
  }

  func finish() async throws -> WorkerListener.CleanupOwnership {
    let ownership = try await listener.finishHandoff()
    await execution.shutdown()
    return ownership
  }
}
