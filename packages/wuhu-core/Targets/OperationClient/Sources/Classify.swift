import struct OperationProtocol.OperationError

/// What a driver does with a failed exchange. The one place errors are sorted: everything not listed as transient ends the
/// operation with the error as its diagnostic, including codes this build does not know.
enum Disposition: Equatable, Sendable {
  /// Says nothing about the operation: retry with backoff while the machine's lease allows.
  case retry
  /// The operation is gone or the machine broke the protocol: conclude with this diagnostic.
  case conclude
}

func disposition(_ code: OperationError.Code) -> Disposition {
  switch code {
  case .transport, .requestDeadline, .requestCancelled, .machineUnavailable, .supervisorUnavailable, .capacityExceeded,
       .storeUnavailable:
    .retry
  case .unknownMachine, .machineNotAuthorized, .unknownOperation, .unknownChannel, .offsetExpired, .invalidOffset, .invalidResponse,
       .invalidInput, .unsupportedProtocol, .resultTooLarge, .recordTooLarge, .inputTooLarge, .leaving, .operationEnded,
       .operationExists, .invocationConflict:
    .conclude
  default:
    .conclude
  }
}
