public enum JSError: Error, Sendable, Equatable {
  case exception(message: String, stack: String?, detail: String? = nil)
  case unsupportedValue(String)
  case terminated
  case stalled
}
