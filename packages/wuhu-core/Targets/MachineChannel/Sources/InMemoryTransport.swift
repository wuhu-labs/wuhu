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

  public static func pair(severAfterSends: Int? = nil) -> (InMemoryTransport, InMemoryTransport) {
    let (aInbound, aContinuation) = AsyncStream<[UInt8]>.makeStream()
    let (bInbound, bContinuation) = AsyncStream<[UInt8]>.makeStream()
    let core = Core(budget: severAfterSends, continuations: [aContinuation, bContinuation])
    return (
      InMemoryTransport(inbound: aInbound, core: core, peer: bContinuation),
      InMemoryTransport(inbound: bInbound, core: core, peer: aContinuation),
    )
  }

  public func send(_ frame: [UInt8]) async throws {
    switch core.admit() {
    case .deliver: peer.yield(frame)
    case .refuse: throw ChannelError.severed
    }
  }

  public func close() {
    core.sever()
  }

  public func sever() {
    core.sever()
  }
}

private final class Core: Sendable {
  struct State {
    var severed: Bool = false
    var budget: Int?
  }

  enum Admission {
    case deliver
    case refuse
  }

  private let state: Mutex<State>
  private let continuations: [AsyncStream<[UInt8]>.Continuation]

  init(budget: Int?, continuations: [AsyncStream<[UInt8]>.Continuation]) {
    state = Mutex(State(budget: budget))
    self.continuations = continuations
  }

  func admit() -> Admission {
    enum Verdict { case deliver, refuse, trip }
    let verdict = state.withLock { state -> Verdict in
      if state.severed { return .refuse }
      guard var budget = state.budget else { return .deliver }
      budget -= 1
      state.budget = budget
      guard budget <= 0 else { return .deliver }
      state.severed = true
      return .trip
    }
    switch verdict {
    case .deliver: return .deliver
    case .refuse: return .refuse
    case .trip:
      finishAll()
      return .refuse
    }
  }

  func sever() {
    let wasSevered = state.withLock { state in
      let was = state.severed
      state.severed = true
      return was
    }
    if !wasSevered { finishAll() }
  }

  private func finishAll() {
    for continuation in continuations { continuation.finish() }
  }
}
