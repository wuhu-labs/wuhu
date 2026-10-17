import enum MachineContract.ExecOutputStream
import Synchronization

/// Output of one incoming exec read ahead of the caller's window, so whoever reads the output keeps reading while a send waits
/// and an output budget sees an overrun even when the caller is not reading. Both streams share one queue and leave it in the
/// order they arrived, so the caller's combined cursor counts bytes in arrival order. Only output within the exec's `maxOutput`
/// is queued, and only up to `ceiling`: a larger budget gets no queue and its sends hold the reader, so the read-ahead stays
/// bounded.
public final class ExecOutputQueue: Sendable {
  /// The largest `maxOutput` read ahead of the caller's window.
  public static let ceiling = 16 << 20

  private struct Piece: Sendable {
    let stream: ExecOutputStream
    let bytes: [UInt8]
  }

  private struct State {
    var overran = false
    var ended: Set<ExecOutputStream> = []
  }

  private let exec: IncomingExec
  private let pieces: AsyncStream<Piece>
  private let feed: AsyncStream<Piece>.Continuation
  private let state = Mutex(State())

  public init?(_ exec: IncomingExec) {
    guard let limit = exec.start.maxOutput, limit <= Self.ceiling else { return nil }
    self.exec = exec
    (pieces, feed) = AsyncStream<Piece>.makeStream()
  }

  /// Queues admitted output behind everything queued before it, on either stream.
  public func enqueue(_ bytes: [UInt8], to stream: ExecOutputStream) {
    guard !bytes.isEmpty else { return }
    feed.yield(Piece(stream: stream, bytes: bytes))
  }

  /// Ends the queue at an overrun: what is queued is sent while the window has room, without waiting for the caller, and the
  /// first shortfall cuts the output there.
  public func overrun() async {
    guard state.withLock({ state in defer { state.overran = true }; return !state.overran }) else { return }
    feed.finish()
    await exec.drainOutput()
  }

  /// Notes that one stream has ended; the queue ends once both have.
  public func finish(_ stream: ExecOutputStream) {
    let both = state.withLock { state in
      state.ended.insert(stream)
      return state.ended.count == 2
    }
    if both { feed.finish() }
  }

  /// Sends the queue in arrival order until it ends. After an overrun it then stops the output and returns true; otherwise it
  /// returns false.
  public func run() async throws -> Bool {
    var failure: (any Error)?
    do { for await piece in pieces { try await exec.send(piece.stream, piece.bytes) } }
    catch { failure = error }
    let stops = state.withLock { $0.overran }
    if stops { await exec.stopOutput() }
    if let failure { throw failure }
    return stops
  }
}
