#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct OperationProtocol.OperationError

/// Why the agent or a worker stops a running exec; its verdict carries the reason.
enum StopReason: String {
  case leaving, retired, refused
}

/// Why a request for an operation cannot be answered now: the message of its `supervisorUnavailable` error.
enum Unavailable: String {
  /// The worker holding it is not connected, or a recovered worker that may hold it has an unreadable inventory.
  case workerNotConnected
  /// The worker is not the current one, so it admits no start.
  case workerNotCurrent
  /// Its worker or supervisor did not answer in time.
  case supervisorTimeout

  func error(_ operation: UUID?) -> OperationError { OperationError(.supervisorUnavailable, message: rawValue, operation: operation) }
}

/// Why an operation's outcome is unknown for good: the `reason` in the details of its `unknownOperation` error.
enum UnknownOutcome: String {
  /// Its worker dropped it before it settled.
  case workerLost
  /// A worker that died with an unreadable inventory may have held it.
  case workerUnaccounted
  /// An earlier agent's version-1 supervisor holds it.
  case supervisorNotAdopted

  func error(_ operation: UUID, message: String) -> OperationError {
    OperationError(.unknownOperation, message: message, operation: operation, details: ["outcome": "unknown", "reason": .string(rawValue)])
  }
}
