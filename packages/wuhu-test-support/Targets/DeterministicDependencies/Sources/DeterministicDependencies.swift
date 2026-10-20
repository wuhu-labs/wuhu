import Dependencies
import DependenciesTestSupport
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Testing

extension Trait where Self == _DependenciesTrait {
  public static var deterministicDependencies: Self {
    .dependencies { Self.install(into: &$0) }
  }

  public static func deterministicDependencies(clock: any Clock<Duration>) -> Self {
    .dependencies {
      Self.install(into: &$0)
      $0.continuousClock = clock
    }
  }

  private static func install(into values: inout DependencyValues) {
    values.uuid = .incrementing
    values.date = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    values.withRandomNumberGenerator = WithRandomNumberGenerator(SeededGenerator())
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64 = 1

  mutating func next() -> UInt64 {
    self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return self.state
  }
}
