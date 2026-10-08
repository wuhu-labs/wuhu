@testable import CLIKit
import Foundation
import Testing

@Suite struct TimestampFormattingTests {
  @Test(arguments: [12345, -12345, 30, -30, 90, -90])
  func fixedOffsetsKeepCoreFoundationMinuteRounding(offset: Int) throws {
    let zone = try #require(TimeZone(secondsFromGMT: offset))
    let date = Date(timeIntervalSince1970: 1_767_225_600.999)
    let previous = ISO8601DateFormatter()
    previous.timeZone = zone
    previous.formatOptions = [.withInternetDateTime]
    #expect(isoFormatted(date, in: zone) == previous.string(from: date))
  }

  @Test(arguments: ["UTC", "Asia/Kolkata", "America/St_Johns", "America/New_York"], [
    -0.125, 1_767_225_600.999,
    1_772_953_199.999, 1_772_953_200.001,
    1_793_512_799.999, 1_793_512_800.001,
  ])
  func transcriptTimestampsMatchThePreviousFormatter(zone: String, epoch: Double) throws {
    let timeZone = try #require(TimeZone(identifier: zone))
    let date = Date(timeIntervalSince1970: epoch)
    let previous = ISO8601DateFormatter()
    previous.timeZone = timeZone
    previous.formatOptions = [.withInternetDateTime]
    #expect(isoFormatted(date, in: timeZone) == previous.string(from: date))
  }

  @Test(arguments: [-0.125, 1_767_225_600.999, 1_772_953_200.001])
  func fileTimestampsKeepTheCurrentTimezone(epoch: Double) {
    let previous = ISO8601DateFormatter()
    previous.timeZone = .current
    previous.formatOptions = [.withInternetDateTime]
    #expect(formatTimestamp(epoch) == previous.string(from: Date(timeIntervalSince1970: epoch)))
  }
}
