#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Fetch.Body
import struct WorkerProtocol.WorkerProtocolError

actor ParentExecutionLeases {
  private var continuations: [UUID: AsyncStream<Data>.Continuation] = [:]
  private var paused = false
  private var stopped = false

  func open() throws -> Body {
    guard !paused, !stopped else { throw WorkerProtocolError(.unavailable, message: "Parent lease admission is closed") }
    guard continuations.count < 256 else { throw WorkerProtocolError(.capacityExceeded, message: "Too many parent leases") }
    let id = UUID()
    let (stream, continuation) = AsyncStream<Data>.makeStream()
    continuation.onTermination = { _ in Task { await self.remove(id) } }
    continuations[id] = continuation
    return .stream(stream)
  }

  private func remove(_ id: UUID) { continuations[id] = nil }

  func suspend() {
    paused = true
    let active = continuations.values
    continuations.removeAll()
    for continuation in active { continuation.finish() }
  }

  func resume() { if !stopped { paused = false } }
  func stop() { stopped = true; suspend() }
}
