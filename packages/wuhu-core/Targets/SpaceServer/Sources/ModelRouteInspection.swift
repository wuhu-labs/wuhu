#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct SessionDomain.SessionModelRoute

func modelRouteInspectionJSON(_ route: SessionModelRoute) throws -> JSONValue {
  let encoder = JSONValueEncoder()
  encoder.dateEncodingStrategy = .iso8601
  var object = try encoder.encode(route).object!
  object["evidence"] = .array(try route.evidence.map { evidence in
    var member = try encoder.encode(evidence).object!
    member["observedAt"] = evidence.observedAt.map { .string(Date(timeIntervalSince1970: $0).ISO8601Format()) }
    member["windows"] = .array(try evidence.windows.map { window in
      var output = try encoder.encode(window).object!
      output["resetsAt"] = window.resetsAt.map { .string(Date(timeIntervalSince1970: $0).ISO8601Format()) }
      return .object(output)
    })
    return .object(member)
  })
  return .object(object)
}
