#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import protocol ExecutionOwner.ExecutionOwnerClient
import enum JSONValue.JSONValue
import struct WorkerProtocol.WorkerCall
import class WorkerProtocol.WorkerCredentials
import struct WorkerProtocol.WorkerHello
import class WorkerProtocol.WorkerListener
import struct WorkerProtocol.WorkerProtocolError

struct ParentExecSuccessor: Sendable {
  let execution: ParentExecutionHandoff
  let listener: WorkerListener

  enum Stage: Sendable { case imported, restoringReplies, adopted, ready }

  // Both descriptors are consumed, including failures before either importer runs.
  static func take(carrier: Int32, listener descriptor: Int32, identity: ParentExecCheckpoint.Identity, socket: String, listenerIdentity: WorkerListener.InheritedIdentity, owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, credentials: WorkerCredentials, hello: WorkerHello, control: (@Sendable (WorkerCall) async throws -> JSONValue)? = nil, stage: @Sendable (Stage) async throws -> Void = { _ in }) async throws -> Self {
    var ownsCarrier = true, ownsListener = true
    var execution: ParentExecutionHandoff?
    var listener: WorkerListener?
    defer {
      if ownsCarrier { _ = close(carrier) }
      if ownsListener, descriptor != carrier { _ = close(descriptor) }
    }
    do {
      guard carrier != descriptor else { throw unavailable() }
      for fd in [carrier, descriptor] {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { throw unavailable() }
      }
      ownsCarrier = false
      let checkpoint = try ParentCheckpointCarrier.take(carrier, expecting: identity)
      try await stage(.imported)
      try await stage(.restoringReplies)
      let restored = try await ParentExecutionHandoff.restoreExec(checkpoint.execution, owner: owner, runtime: runtime, control: control)
      execution = restored
      let endpoint = try await restored.endpoint(credentials: credentials, hello: hello)
      ownsListener = false
      let adopted = try await WorkerListener.adopt(descriptor, socket: socket, expecting: listenerIdentity, initiallyAccepting: false, handler: endpoint.handler)
      listener = adopted
      try await stage(.adopted)
      try await stage(.ready)
      try Task.checkCancellation()
      try await adopted.resumeAccepting()
      return Self(execution: restored, listener: adopted)
    } catch {
      await listener?.shutdown()
      await execution?.shutdown()
      throw error
    }
  }

  func shutdown() async {
    await listener.shutdown()
    await execution.shutdown()
  }

  private static func unavailable() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Invalid exec handoff descriptors")
  }
}
