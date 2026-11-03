#if os(macOS) || os(Linux)
  import Foundation
  import Synchronization
  import Testing
  import TestRunner

  struct RunnerParallelismTests {
    private static let probe = "WUHU_RUNNER_WIDTH_PROBE"
    private static let width = "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
    private static let cases = 32
    private static let counts = Mutex((started: 0, inFlight: 0))

    /// Each case holds its slot until `width` cases are in flight at once, so a run passes only when
    /// the runner reaches that width and is never seen exceeding it.
    @Test(.timeLimit(.minutes(1)), arguments: 0 ..< cases)
    func widthProbe(index _: Int) async throws {
      guard let value = ProcessInfo.processInfo.environment[Self.probe] else { return }
      let width = try #require(Int(value))
      let inFlight = Self.counts.withLock { counts in
        counts.started += 1
        counts.inFlight += 1
        return counts.inFlight
      }
      #expect(inFlight <= width)
      repeat {
        await Task.yield()
      } while Self.counts.withLock({ $0.inFlight < width && $0.started < Self.cases })
      Self.counts.withLock { $0.inFlight -= 1 }
    }

    @Test func `the runner bounds how many test cases run at once`() throws {
      guard ProcessInfo.processInfo.environment[Self.probe] == nil else { return }
      let width = try #require(ProcessInfo.processInfo.environment[Self.width].flatMap { Int($0) })
      try #require(1 < width && width < Self.cases)
      let test = "RunnerParallelismTests/widthProbe(index:)"

      let bounded = try TestBinaryRun(test: test, environment: [Self.probe: "\(width)"])
      #expect(bounded.status == 0, "\(bounded.output)")
      let unbounded = try TestBinaryRun(test: test, environment: [Self.probe: "\(Self.cases)", Self.width: "\(Self.cases)"])
      #expect(unbounded.status == 0, "the probe must be able to reach \(Self.cases) at once: \(unbounded.output)")
      let exceeding = try TestBinaryRun(test: test, environment: [Self.probe: "\(width)", Self.width: "\(Self.cases)"])
      #expect(exceeding.status != 0, "an unbounded runner must overrun the probe's width: \(exceeding.output)")
    }
  }
#endif
