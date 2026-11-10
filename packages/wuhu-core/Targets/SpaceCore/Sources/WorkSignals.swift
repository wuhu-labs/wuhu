import SessionDomain
import Synchronization

/// How the store tells the worker that a session's cell has mail, after the write that posted it commits. Unbound, or lost, the worker's scan finds the mail.
final class WorkSignals: Sendable {
  private let poke = Mutex<(@Sendable (SessionID) -> Void)?>(nil)

  func bind(_ poke: @escaping @Sendable (SessionID) -> Void) {
    self.poke.withLock { $0 = poke }
  }

  func post(_ session: SessionID) {
    poke.withLock { $0 }?(session)
  }
}

extension SessionStore {
  /// `poke` has the session's cell look at its mail; the worker that hosts the cells binds it.
  public func onMail(_ poke: @escaping @Sendable (SessionID) -> Void) {
    signals.bind(poke)
  }
}
