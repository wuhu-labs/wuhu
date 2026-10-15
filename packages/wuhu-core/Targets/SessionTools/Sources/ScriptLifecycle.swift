import struct SessionDomain.SessionID

public struct ScriptLifecycle: Sendable {
  let started: @Sendable (SessionID, String) async throws -> Void
  let ended: @Sendable (SessionID, String) async -> Void
  public init(started: @escaping @Sendable (SessionID, String) async throws -> Void, ended: @escaping @Sendable (SessionID, String) async -> Void) {
    self.started = started; self.ended = ended
  }
}
