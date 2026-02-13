import Foundation

public struct WuhuLLMRetryPolicy: Sendable {
  public var maxRetries: Int
  public var initialBackoffSeconds: Double
  public var maxBackoffSeconds: Double
  public var jitterFraction: Double
  public var sleep: @Sendable (UInt64) async throws -> Void

  public init(
    maxRetries: Int = 5,
    initialBackoffSeconds: Double = 0.5,
    maxBackoffSeconds: Double = 8.0,
    jitterFraction: Double = 0.2,
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
  ) {
    self.maxRetries = maxRetries
    self.initialBackoffSeconds = initialBackoffSeconds
    self.maxBackoffSeconds = maxBackoffSeconds
    self.jitterFraction = jitterFraction
    self.sleep = sleep
  }
}
