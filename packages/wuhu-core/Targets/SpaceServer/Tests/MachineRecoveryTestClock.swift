import Clocks
import struct OperationProtocol.OperationClock

struct MachineRecoveryTestClock: Sendable {
  private let time: TestClock<Duration>
  let clock: OperationClock

  init() {
    let time = TestClock<Duration>(); let origin = time.now
    self.time = time
    clock = .init(now: { origin.duration(to: time.now) }, sleep: { try await time.sleep(for: $0) })
  }

  func advance(_ duration: Duration) async { await time.advance(by: duration) }
}
