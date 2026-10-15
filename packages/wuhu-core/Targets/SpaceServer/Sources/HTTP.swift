#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import JSONValue
import OrderedCollections
import Serve

func jsonResponse(_ value: JSONValue, status: Status = .ok) -> Response {
  let data = Data(value.jsonString().utf8)
  var headers = Headers()
  headers[.contentType] = "application/json"
  headers[.contentLength] = String(data.count)
  return Response(status: status, headers: headers, body: .bytes(data, contentType: "application/json"))
}

// A client signs its bearer assertions by this clock, so no cache may keep an
// old reading.
func clockReading(_ response: Response, now: Date) -> Response {
  var response = response
  response.headers[.cacheControl] = "no-store"
  response.headers[.date] = httpDate(now)
  return response
}

// IMF-fixdate (RFC 9110 §5.6.7): "Tue, 14 Nov 2023 22:13:20 GMT".
func httpDate(_ date: Date) -> String {
  let seconds = Int(date.timeIntervalSince1970.rounded(.down))
  var days = seconds / 86400
  var time = seconds % 86400
  if time < 0 {
    time += 86400
    days -= 1
  }
  let weekday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][((days % 7) + 7) % 7]
  // Days to civil date, proleptic Gregorian (Hinnant's days_from_civil inverse).
  let shifted = days + 719_468
  let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
  let dayOfEra = shifted - era * 146_097
  let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
  let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
  let monthIndex = (5 * dayOfYear + 2) / 153
  let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
  let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
  let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
  let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
  let clock = "\(two(time / 3600)):\(two(time / 60 % 60)):\(two(time % 60))"
  return "\(weekday), \(two(day)) \(months[month - 1]) \(year) \(clock) GMT"
}

func errorResponse(_ status: Status, code: String, message: String, hint: String? = nil, reason: String? = nil) -> Response {
  var fields: OrderedDictionary<String, JSONValue> = ["code": .string(code), "message": .string(message)]
  fields["hint"] = hint.map(JSONValue.string)
  fields["reason"] = reason.map(JSONValue.string)
  return jsonResponse(.object(fields), status: status)
}

func plainStatus(_ status: Status) -> Response {
  Response(status: status, body: .string("\(status.code) \(status.reasonPhrase)\n"))
}

func queryValues(of url: URL) -> [String: String] {
  var values: [String: String] = [:]
  for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
    values[item.name] = item.value ?? ""
  }
  return values
}
