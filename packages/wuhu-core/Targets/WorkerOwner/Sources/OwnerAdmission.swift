#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct WorkerProtocol.WorkerProtocolError

actor OwnerAdmission {
  private struct Context: Sendable { let admission: UUID; let ticket: UUID }
  @TaskLocal private static var context: Context?
  private let identity = UUID()
  private var closed = false
  private var paused: Bool
  private var active: [UUID: Bool] = [:]
  private var drained: [AsyncStream<Void>.Continuation] = []
  init(paused: Bool = false) { self.paused = paused }

  func run<Value: Sendable>(reusingRequest: Bool = false, _ operation: @Sendable (UUID) async throws -> Value) async throws -> Value {
    guard !paused else { throw WorkerProtocolError(.unavailable, message: "Parent endpoint admission is paused") }
    if reusingRequest, let context = Self.context, context.admission == identity, active[context.ticket] != nil {
      return try await Self.$context.withValue(nil) { try await operation(context.ticket) }
    }
    let ticket = UUID()
    active[ticket] = false
    defer {
      active[ticket] = nil
      if active.isEmpty {
        for continuation in drained { continuation.finish() }
        drained.removeAll()
      }
    }
    return try await Self.$context.withValue(reusingRequest ? nil : Context(admission: identity, ticket: ticket)) { try await operation(ticket) }
  }

  func reader(_ ticket: UUID) throws {
    guard !paused, active[ticket] != nil else { throw WorkerProtocolError(.unavailable, message: "Parent reader admission is paused") }
    active[ticket] = true
  }

  func freeze() throws {
    guard !paused, active.values.allSatisfy({ $0 }) else { throw WorkerProtocolError(.unavailable, message: "Parent has active non-transferable calls") }
    paused = true
  }

  func drain() async {
    guard !active.isEmpty else { return }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    drained.append(continuation)
    for await _ in stream {}
  }

  func close() { closed = true; paused = true }

  func resume() throws {
    guard !closed else { throw WorkerProtocolError(.unavailable, message: "Parent endpoint is retired") }
    paused = false
  }
}
