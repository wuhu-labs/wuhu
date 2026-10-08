import Foundation
import SessionDomain
import Testing

@Suite struct HeaderFixedOffsetTests {
  @Test(arguments: ["Asia/Kolkata", "Europe/Amsterdam", "America/New_York", "GMT+0326"], [-2_208_988_800.0, 1_767_225_600.999])
  func keepsPreviousHistoricalOffsets(zoneName: String, epoch: Double) throws {
    let zone = try #require(TimeZone(identifier: zoneName))
    let date = Date(timeIntervalSince1970: epoch)
    let previous = ISO8601DateFormatter()
    previous.timeZone = zone
    previous.formatOptions = [.withInternetDateTime]
    let header = MessageHeader(sender: "alice", timestamp: date, timeZone: zone, source: .direct, kind: .message)
    #expect(header.render().contains("<timestamp>\(previous.string(from: date))</timestamp>"))
  }

  @Test(arguments: [-12600, 19800, 12345, -12345, 30, -30, 90, -90], [-0.125, 1_767_225_600.999])
  func keepsPreviousFixedOffsets(offset: Int, epoch: Double) throws {
    let zone = try #require(TimeZone(secondsFromGMT: offset))
    let date = Date(timeIntervalSince1970: epoch)
    let previous = ISO8601DateFormatter()
    previous.timeZone = zone
    previous.formatOptions = [.withInternetDateTime]
    let header = MessageHeader(sender: "alice", timestamp: date, timeZone: zone, source: .direct, kind: .message)
    #expect(header.render().contains("<timestamp>\(previous.string(from: date))</timestamp>"))
  }
}
