import struct SessionDomain.SessionID

public struct AttemptEventSink: Sendable {
  private let receive: @Sendable (SessionID, AttemptEvent) async throws -> Void
  public init(_ receive: @escaping @Sendable (SessionID, AttemptEvent) async throws -> Void) { self.receive = receive }
  public func publish(session: SessionID, _ event: AttemptEvent) async throws { try await receive(session, event) }
}
