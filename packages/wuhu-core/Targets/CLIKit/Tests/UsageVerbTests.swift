#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import CLIKit
import struct SpaceContract.ProviderDescriptor
import Testing

struct UsageVerbTests {
  @Test func aWindowPrintsItsResetOnlyWhenTheServerReportsOne() throws {
    let provider = try JSONDecoder().decode(ProviderDescriptor.self, from: Data(#"""
    {"id":"claude","dialect":"responses","models":[],"usage":{"observedAt":1760000000,"windows":[
      {"name":"five_hour","usedPercent":0},
      {"name":"seven_day_overage_included","usedPercent":50,"resetsAt":1760600000}
    ]}}
    """#.utf8))
    let lines = try #require(renderedUsage(provider, now: Date(timeIntervalSince1970: 1_760_000_000))).split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[1] == "  five_hour 0%")
    #expect(lines[2].hasPrefix("  seven_day_overage_included 50% resets "))
  }
}
