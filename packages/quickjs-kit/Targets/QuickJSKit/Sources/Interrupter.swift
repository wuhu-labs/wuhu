import Synchronization

extension JSEngine {
  public final class Interrupter: Sendable {
    let flag = Atomic<Bool>(false)

    public init() {}

    public func interrupt() {
      flag.store(true, ordering: .relaxed)
    }

    public func reset() {
      flag.store(false, ordering: .relaxed)
    }
  }
}
