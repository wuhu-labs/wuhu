import DequeModule
import Synchronization

/// A typed live connection to an addressable, opened by whoever owns the transport: a router, a test. `Incoming` frames go to the addressable, `Outgoing` frames come back. `Opening` is what the transport says once, as it attaches: who is at the other end, where they left off. Nothing about a socket is durable: membership lives in the worker that took the socket, a frame can be lost with a failed incarnation, and a close is best effort. Declare one as an empty enum: `enum Chat: Socket { enum Incoming { … }; enum Outgoing { … } }`.
public protocol Socket: SendableMetatype {
  associatedtype Opening: Sendable = Void
  associatedtype Incoming: Sendable = Never
  associatedtype Outgoing: Sendable
}

/// What the transport hears from the addressable.
public enum SocketOutput<S: Socket>: Sendable {
  case frame(S.Outgoing)
  case closed
}

/// The transport's end of a socket. Frames reach the addressable one at a time, in the order they were sent.
public struct Peer<S: Socket>: Sendable {
  let attachment: Attachment

  public func send(_ frame: S.Incoming) {
    attachment.enqueue(.frame(frame))
  }

  /// The addressable hears `closed` after the frames sent before it.
  public func close() {
    attachment.hangUp()
  }
}

/// A socket as an addressable's code sees it, for the length of one call. `send` and `close` are outputs: they leave once everything written before them is durable; if that epoch fails they are dropped and the socket is closed. On a socket that is gone they do nothing.
public struct SocketHandle<S: Socket> {
  let attachment: Attachment
  let reach: Reach

  public var id: Int {
    attachment.id
  }

  public var opening: S.Opening {
    attachment.opening as! S.Opening
  }

  public func send(_ frame: S.Outgoing) {
    reach.incarnation.output(.frame(attachment, frame))
  }

  public func close() {
    reach.incarnation.output(.close(attachment))
  }
}

/// What reaches the `_socket` that `@Cell` generates from the cell's `attached`, `receive(_:from:)` and `closed` methods.
public struct SocketEvent {
  public enum Kind {
    case attached
    case frame(any Sendable)
    case closed
  }

  public let kind: Kind
  let attachment: Attachment
  let reach: Reach

  public func socket<S: Socket>(_: S.Type) -> SocketHandle<S>? {
    attachment.socket == ObjectIdentifier(S.self) ? SocketHandle(attachment: attachment, reach: reach) : nil
  }

  /// A frame nobody handles is a programming error; an unheard `attached` or `closed` is not.
  public func unhandled() {
    if case .frame = kind { preconditionFailure("\(attachment.address) has no handler for \(attachment.name) frames") }
  }
}

/// A socket's entry in its worker's registry: the inbound queue, delivered serially, and the way back to the transport.
final class Attachment: Sendable {
  enum Inbound: Sendable {
    case attached
    case frame(any Sendable)
    case closed
  }

  private struct State {
    var gone = false
    var greeted = false
    /// Whether the peer's frames are still for the addressable to hear: its own close ends that, a hang-up does not.
    var frames = true
    var queue = Deque<Inbound>()
    var delivering = false
  }

  let id: Int
  let address: String
  let socket: ObjectIdentifier
  let name: String
  let opening: any Sendable
  private let worker: Worker
  private let output: @Sendable ((any Sendable)?) -> Void
  private let state = Mutex(State())

  init<S: Socket>(id: Int, address: String, worker: Worker, _: S.Type, opening: S.Opening, output: @escaping @Sendable (SocketOutput<S>) -> Void) {
    self.id = id
    self.address = address
    self.worker = worker
    self.opening = opening
    socket = ObjectIdentifier(S.self)
    name = "\(S.self)"
    self.output = { frame in output(frame.map { .frame($0 as! S.Outgoing) } ?? .closed) }
  }

  /// Whether its cell has begun hearing `attached`: only then is it among the cell's sockets, so nothing the cell publishes can come before what `attached` sends.
  var greeted: Bool {
    state.withLock { $0.greeted }
  }

  func greet() {
    state.withLock { $0.greeted = true }
  }

  /// A frame or an attach for the addressable to take.
  func enqueue(_ inbound: Inbound) {
    let starts = state.withLock { state in
      guard !state.gone else { return false }
      state.queue.append(inbound)
      defer { state.delivering = true }
      return !state.delivering
    }
    guard starts else { return }
    deliver()
  }

  /// The peer hangs up: the addressable hears what it sent, then `closed`.
  func hangUp() {
    worker.detach(self)
    if let starts = ending(droppingFrames: false), starts { deliver() }
  }

  /// The addressable closes its own socket: what is queued behind the call that closed it is dropped, its peer hears it, and it hears `closed`.
  func close() {
    guard let starts = ending(droppingFrames: true) else { return }
    worker.detach(self)
    output(nil)
    if starts { deliver() }
  }

  /// Whether the addressable still wants `inbound`: a frame that left the queue before its own close, waiting for the lane, is not for it to hear.
  func takes(_ inbound: Inbound) -> Bool {
    state.withLock { state in
      if case .frame = inbound { return state.frames }
      return true
    }
  }

  /// The addressable closed it in a step that landed: what the peer queued behind that call is not for it to hear, the step's own frame aside.
  func discardFrames() {
    state.withLock { state in
      state.frames = false
      state.queue.removeAll { if case .frame = $0 { true } else { false } }
    }
  }

  /// Ends the queue with `closed`, saying whether the caller must deliver it; nil when the socket was already over.
  private func ending(droppingFrames: Bool) -> Bool? {
    state.withLock { state in
      guard !state.gone else { return nil }
      state.gone = true
      if droppingFrames { state.queue.removeAll() }
      state.queue.append(.closed)
      defer { state.delivering = true }
      return !state.delivering
    }
  }

  private func deliver() {
    worker.task { [self] in
      while let next = next() {
        await worker.deliver(next, from: self)
      }
    }
  }

  private func next() -> Inbound? {
    state.withLock { state in
      while let next = state.queue.popFirst() {
        if case .frame = next, !state.frames { continue }
        return next
      }
      state.delivering = false
      return nil
    }
  }

  /// An outbound frame, on the lane of the addressable that sent it.
  func push(_ frame: any Sendable) {
    if !state.withLock({ $0.gone }) { output(frame) }
  }

  /// The addressable, or the runtime, ends the socket.
  func end() {
    let wasGone = state.withLock { state in
      defer {
        state.gone = true
        state.queue.removeAll()
      }
      return state.gone
    }
    guard !wasGone else { return }
    worker.detach(self)
    output(nil)
  }
}
