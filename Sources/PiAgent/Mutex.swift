import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

final class Mutex<State>: @unchecked Sendable {
  private var mutex = pthread_mutex_t()
  private var state: State

  init(initialState: State) {
    state = initialState
    var attr = pthread_mutexattr_t()
    pthread_mutexattr_init(&attr)
    pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_NORMAL))
    pthread_mutex_init(&mutex, &attr)
    pthread_mutexattr_destroy(&attr)
  }

  deinit {
    pthread_mutex_destroy(&mutex)
  }

  @discardableResult
  func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
    pthread_mutex_lock(&mutex)
    defer { pthread_mutex_unlock(&mutex) }
    return try body(&state)
  }

  func snapshot() -> State {
    withLock { $0 }
  }
}
