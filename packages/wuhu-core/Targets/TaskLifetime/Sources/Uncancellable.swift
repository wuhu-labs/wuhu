public func uncancellable<Value: Sendable>(
  _ reason: StaticString,
  @_inheritActorContext @_implicitSelfCapture operation: @escaping @isolated(any) @Sendable () async -> Value,
) async -> Value {
  await Task { await operation() }.value
}

public func uncancellable<Value: Sendable>(
  _ reason: StaticString,
  @_inheritActorContext @_implicitSelfCapture operation: @escaping @isolated(any) @Sendable () async throws -> Value,
) async throws -> Value {
  try await Task { try await operation() }.value
}
