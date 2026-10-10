#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

final class Latch: Sendable {
  private let open = Box(false)
  func release() { open.withLock { $0 = true } }
  func wait(unless killed: @Sendable () -> Bool = { false }) async {
    while !open.value, !killed() {
      try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
  }
}
