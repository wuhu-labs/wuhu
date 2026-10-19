import JSONValue
import OrderedCollections

public func jsonObject(_ pairs: [(String, JSONValue?)]) -> JSONValue {
  var fields: OrderedDictionary<String, JSONValue> = [:]
  for (name, value) in pairs {
    if let value { fields[name] = value }
  }
  return .object(fields)
}
