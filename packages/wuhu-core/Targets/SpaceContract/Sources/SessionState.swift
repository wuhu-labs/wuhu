public enum SessionLifecyclePayload: String, Sendable, Hashable {
  case live, archived, unknown
}

public enum SessionHoldPayload: String, Sendable, Hashable, Codable {
  case normal, interrupted, unknown
}

public enum SessionWorkPayload: String, Sendable, Hashable, Codable {
  case noWork = "no_work"
  case hasWork = "has_work"
  case errored, unknown
}
