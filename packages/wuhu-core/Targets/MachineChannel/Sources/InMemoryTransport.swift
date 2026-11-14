import Synchronization

public final class InMemoryTransport: FrameTransport, Sendable {
  public let inbound: AsyncStream<[UInt8]>
  private let core: Core
  private let peer: AsyncStream<[UInt8]>.Continuation

  private init(inbound: AsyncStream<[UInt8]>, core: Core, peer: AsyncStream<[UInt8]>.Continuation) {
    self.inbound = inbound
    self.core = core
    self.peer = peer
  }

  public static func pair() -> (InMemoryTransport, InMemoryTransport) {
    let (aInbound, aContinuation) = AsyncStream<[UInt8]>.makeStream()
    let (bInbound, bContinuation) = AsyncStream<[UInt8]>.makeStream()
    let core = Core(continuations: [aContinuation, bContinuation])
    return (
      InMemoryTransport(inbound: aInbound, core: core, peer: bContinuation),
      InMemoryTransport(inbound: bInbound, core: core, peer: aContinuation),
    )
  }

  public func send(_ frame: [UInt8]) async throws {
    guard !core.isSevered else { throw ChannelError.severed }
    peer.yield(frame)
  }

  public func close() {
    core.sever()
  }

  public func sever() {
    core.sever()
  }
}

private final class Core: Sendable {
  private let state: Mutex<Bool>
  private let continuations: [AsyncStream<[UInt8]>.Continuation]

  var isSevered: Bool { state.withLock { $0 } }

  init(continuations: [AsyncStream<[UInt8]>.Continuation]) {
    state = Mutex(false)
    self.continuations = continuations
  }

  func sever() {
    let wasSevered = state.withLock { state in
      let was = state
      state = true
      return was
    }
    if !wasSevered { for continuation in continuations { continuation.finish() } }
  }
}
