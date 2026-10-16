import protocol ExecutionOwner.ExecutionOwnerClient
import enum JSONValue.JSONValue
import Logging
import struct WorkerProtocol.WorkerCall

/// Owns a close-on-exec, unlinked carrier containing only the audited credential-free checkpoint subset. Keep it alive while borrowing its descriptor; map duplicates only into the intended replacement image.
public final class ParentExecTransfer: Sendable {
  private let carrier: ParentCheckpointCarrier
  public var descriptor: Int32 { carrier.descriptor }

  init(_ carrier: ParentCheckpointCarrier) { self.carrier = carrier }

  /// Consumes the descriptor on success and refusal. Expected identity and fresh services come from the trusted same-process exec coordinator, not the carrier.
  public static func take(_ descriptor: Int32, expecting identity: ParentExecutionIdentity, owner: any ExecutionOwnerClient, runtime: WorkerRuntimeOwner? = nil, spawn: ParentSpawnEndpoint? = nil, control: (@Sendable (WorkerCall) async throws -> JSONValue)? = nil) async throws -> ParentExecutionHandoff {
    let checkpoint = try ParentCheckpointCarrier.take(descriptor, expecting: identity.value)
    return try await ParentExecutionHandoff.restoreExec(checkpoint.execution, owner: owner, runtime: runtime, spawn: spawn, control: control)
  }
}

extension ParentExecutionHandoff {
  public func exportExec(identity: ParentExecutionIdentity) async throws -> ParentExecTransfer {
    do { return try await ParentExecTransfer(execCarrier(identity: identity.value)) }
    catch let error as ParentCheckpointCarrierError {
      Logger(label: "wuhu.parent-exec").error("Checkpoint export refused", metadata: ["reason": "\(error.code)"])
      throw error
    }
  }
}
