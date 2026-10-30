import Clocks

extension TestClock {
  /// Yields until a sleep is pending. A sleep started by another task registers only once that task runs, and an advance before
  /// then moves past it unseen.
  public func sleeping() async {
    while (try? checkSleeps()) != nil { await Task.yield() }
  }
}
