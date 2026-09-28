#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import JSONValue
import Serve

func jsonResponse(_ value: JSONValue, status: Status = .ok) -> Response {
  let data = Data(value.jsonString().utf8)
  var headers = Headers()
  headers[.contentType] = "application/json"
  headers[.contentLength] = String(data.count)
  return Response(status: status, headers: headers, body: .bytes(data, contentType: "application/json"))
}

func errorResponse(_ status: Status, code: String, message: String, hint: String? = nil) -> Response {
  var payload: JSONValue = .object(["code": .string(code), "message": .string(message)])
  if case var .object(fields) = payload, let hint {
    fields["hint"] = .string(hint)
    payload = .object(fields)
  }
  return jsonResponse(payload, status: status)
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
