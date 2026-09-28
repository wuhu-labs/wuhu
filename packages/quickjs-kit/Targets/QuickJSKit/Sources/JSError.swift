public enum JSError: Error, Sendable, Equatable {
  case exception(message: String, stack: String?)
  case unsupportedValue(String)
  case terminated
  case stalled
}
