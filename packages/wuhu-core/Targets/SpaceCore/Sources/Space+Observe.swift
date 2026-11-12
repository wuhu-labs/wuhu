import JSONValue
import struct SpaceContract.GroupID
import SpaceFS

extension Space {
  /// A group's file changes, one journal revision per frame, from `from` on (from the current revision when there is none). A refused attach throws before a stream exists; the stream finishes when the watch ends or the worker drains.
  public func observeFS(glob: String, from: Rev? = nil, group: GroupID, as principal: Principal) async throws -> AsyncStream<FSCommit> {
    guard let worker = runtime.observing() else { throw ObservationsUnavailable() }
    let after: Rev
    if let from {
      after = from
    } else {
      after = Rev(try await currentRevision())
    }
    let (stream, continuation) = AsyncStream<FSCommit>.makeStream()
    guard let peer = worker.attach(FileStream.self, to: ObservationJob.address, opening: .init(glob: glob, group: group, after: after.value, principal: principal), output: { output in
      switch output {
      case let .frame(commit): continuation.yield(commit)
      case .closed: continuation.finish()
      }
    }) else { throw ObservationsUnavailable() }
    continuation.onTermination = { _ in peer.close() }
    return stream
  }

  /// A statement's rows as they are, then each changed snapshot after `throttle`. A refused attach throws before a stream exists; the stream finishes when the watch ends or the worker drains.
  public nonisolated func observeRows(
    _ sql: String, parameters: [JSONValue] = [], throttle: Duration, viewer: String? = nil, as principal: Principal,
  ) throws -> AsyncThrowingStream<Rows, any Error> {
    let opening = RowsStream.Opening(sql: sql, parameters: parameters, throttle: throttle, viewer: viewer, principal: principal)
    guard let worker = runtime.observing() else { throw ObservationsUnavailable() }
    let (stream, continuation) = AsyncThrowingStream<Rows, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    guard let peer = worker.attach(RowsStream.self, to: ObservationJob.address, opening: opening, output: { output in
      switch output {
      case let .frame(rows): continuation.yield(rows)
      case .closed: continuation.finish()
      }
    }) else { throw ObservationsUnavailable() }
    continuation.onTermination = { _ in peer.close() }
    return stream
  }
}
