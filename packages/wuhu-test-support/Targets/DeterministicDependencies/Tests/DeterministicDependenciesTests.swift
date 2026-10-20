import Dependencies
import DeterministicDependencies
import Foundation
import Testing

@Suite(.deterministicDependencies)
struct DeterministicDependencyTests {
  @Test func values() {
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid
    #expect(now == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(uuid() == UUID(0))
    #expect(uuid() == UUID(1))
  }
}

@Test func missingDependencyReportsAnIssue() {
  withKnownIssue {
    @Dependency(\.uuid) var uuid
    _ = uuid()
  }
}
