import enum MachineContract.ExecOutputStream
import Synchronization

/// Output of one incoming exec read ahead of the caller's window, one queue per stream, so whoever reads the output keeps reading
/// while a send waits and an output budget sees an overrun even when the caller is not reading. Only output within the exec's
/// `maxOutput` is queued, and only up to `ceiling`: a larger budget gets no queue and its sends hold the reader, so the read-ahead
/// stays bounded. The streams share the budget, so an overrun on either drains both before the output stops.
public final class ExecOutputQueue: Sendable {
  /// The largest `maxOutput` read ahead of the caller's window.
  public static let ceiling = 16 << 20

  private struct Lane: Sendable {
    let chunks: AsyncStream<[UInt8]>
    let feed: AsyncStream<[UInt8]>.Continuation
    init() { (chunks, feed) = AsyncStream<[UInt8]>.makeStream() }
  }

  private struct State {
    var overran = false
    var drained = 0
  }

  private let exec: IncomingExec
  private let stdout = Lane()
  private let stderr = Lane()
  private let state = Mutex(State())

  public init?(_ exec: IncomingExec) {
    guard let limit = exec.start.maxOutput, limit <= Self.ceiling else { return nil }
    self.exec = exec
  }

  private func lane(_ stream: ExecOutputStream) -> Lane {
    switch stream {
    case .stdout: stdout
    case .stderr: stderr
    }
  }

  /// Queues admitted output behind everything queued on its stream before it.
  public func enqueue(_ bytes: [UInt8], to stream: ExecOutputStream) {
    guard !bytes.isEmpty else { return }
    lane(stream).feed.yield(bytes)
  }

  /// Ends both queues at an overrun: what is queued is sent while the window has room, without waiting for the caller, and the
  /// first shortfall cuts the output there.
  public func overrun() async {
    guard state.withLock({ state in defer { state.overran = true }; return !state.overran }) else { return }
    stdout.feed.finish()
    stderr.feed.finish()
    await exec.drainOutput()
  }

  /// Ends one stream's queue once that stream has ended.
  public func finish(_ stream: ExecOutputStream) {
    lane(stream).feed.finish()
  }

  /// Sends one stream's queue in order until it ends. After an overrun, the stream that drains last stops the output and returns
  /// true; every other call returns false.
  public func run(_ stream: ExecOutputStream) async throws -> Bool {
    var failure: (any Error)?
    do { for await bytes in lane(stream).chunks { try await exec.send(stream, bytes) } }
    catch { failure = error }
    let stops = state.withLock { state in state.drained += 1; return state.drained == 2 && state.overran }
    if stops { await exec.stopOutput() }
    if let failure { throw failure }
    return stops
  }
}
