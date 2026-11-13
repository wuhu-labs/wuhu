public extension SessionStore {
  /// A generation's preamble bytes, put and named by hash before the session's hash-only prompt step.
  func stageBlob(_ bytes: [UInt8]) async throws -> String {
    try await bucket.put(bytes)
  }
}
