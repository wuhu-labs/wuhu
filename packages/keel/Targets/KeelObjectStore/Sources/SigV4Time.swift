#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

enum SigV4Time {
  static func stamps(from date: Date) -> (amzDate: String, dateStamp: String) {
    let seconds = Int(date.timeIntervalSince1970.rounded(.down))
    let daySeconds = 86400
    var days = seconds / daySeconds
    var remainder = seconds % daySeconds
    if remainder < 0 {
      remainder += daySeconds
      days -= 1
    }
    let (year, month, day) = civilFromDays(days)
    let hour = remainder / 3600
    let minute = (remainder % 3600) / 60
    let second = remainder % 60

    let ymd = pad(year, 4) + pad(month, 2) + pad(day, 2)
    let hms = pad(hour, 2) + pad(minute, 2) + pad(second, 2)
    return (amzDate: "\(ymd)T\(hms)Z", dateStamp: ymd)
  }

  private static func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  private static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
    let z = z + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
  }
}
