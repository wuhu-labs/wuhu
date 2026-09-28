public enum FetchError: Error, Sendable, Equatable {
  case unimplemented
  case unexpectedStatus(Status)
  case bodyLimitExceeded(limit: Int)
  case bodyAlreadyConsumed
  case invalidTextEncoding
  case transportFailure(kind: TransportFailureKind)
}

public enum TransportFailureKind: String, Sendable, Equatable {
  case idleTimeout
  case readTimeout
  case connectTimeout
  case deadlineExceeded
  case connectionClosed
  case poolTimeout
  case io
  case channel

  public var isTimeout: Bool {
    switch self {
    case .idleTimeout, .readTimeout, .connectTimeout, .deadlineExceeded, .poolTimeout:
      true
    case .connectionClosed, .io, .channel:
      false
    }
  }
}
