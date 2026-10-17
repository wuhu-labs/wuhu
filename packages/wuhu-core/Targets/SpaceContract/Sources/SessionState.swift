public enum SessionLifecyclePayload: String, Sendable, Hashable {
  case live, archived, unknown
}

public enum SessionHoldPayload: String, Sendable, Hashable {
  case normal, interrupted, unknown
}

public enum SessionWorkPayload: String, Sendable, Hashable {
  case noWork = "no_work"
  case hasWork = "has_work"
  case errored, unknown
}
