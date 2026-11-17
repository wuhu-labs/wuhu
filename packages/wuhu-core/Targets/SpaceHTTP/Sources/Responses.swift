#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import HTTPTypes
import JSONValue
import OrderedCollections

/// A JSON body with its content type and length: the one shape every route answers in.
public func jsonResponse(_ value: JSONValue, status: Status = .ok) -> Response {
  let data = Data(value.jsonString().utf8)
  var headers = Headers()
  headers[.contentType] = "application/json"
  headers[.contentLength] = String(data.count)
  return Response(status: status, headers: headers, body: .bytes(data, contentType: "application/json"))
}

/// A refusal the clients parse: a code, a message and, where they help, a hint and the reason.
public func errorResponse(_ status: Status, code: String, message: String, hint: String? = nil, reason: String? = nil) -> Response {
  var fields: OrderedDictionary<String, JSONValue> = ["code": .string(code), "message": .string(message)]
  fields["hint"] = hint.map(JSONValue.string)
  fields["reason"] = reason.map(JSONValue.string)
  return jsonResponse(.object(fields), status: status)
}
