import Dispatch
import Synchronization
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

final class AdminExecReadinessDeadline: Sendable {
  private enum State { case pending, committed, firing }
  private let state = Mutex(State.pending)
  private let timer: Mutex<any DispatchSourceTimer>

  init(timeout: @escaping @Sendable () -> Void) {
    timer = Mutex(DispatchSource.makeTimerSource(queue: .global()))
    timer.withLock { timer in
      timer.schedule(deadline: .now() + .seconds(30))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        let fire = self.state.withLock { current in
          guard case .pending = current else { return false }
          current = .firing
          return true
        }
        if fire { timeout() }
      }
      timer.resume()
    }
  }

  func commit() throws {
    let committed = state.withLock { current in
      guard case .pending = current else { return false }
      current = .committed
      return true
    }
    guard committed else { throw AdminExecError.refused("readinessTimeout") }
    timer.withLock { $0.cancel() }
  }

  deinit { timer.withLock { $0.cancel() } }
}
