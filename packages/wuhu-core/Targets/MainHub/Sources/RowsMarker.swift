#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import SpaceCore
import SpaceTools

/// A handler's input for an observation's rows: `{rows: [{column: value}]}`.
public func handlerInput(_ rows: Rows) -> JSONValue {
  guard case let .object(snapshot) = Wire.queryOutput(rows), case let .array(values)? = snapshot["rows"] else { preconditionFailure("a query's output has rows") }
  return .object(["rows": .array(values.map { value in
    guard case let .array(cells) = value else { preconditionFailure("query rows are arrays") }
    var object: OrderedDictionary<String, JSONValue> = [:]
    for (column, cell) in zip(rows.columns, cells) { object[column] = cell }
    return .object(object)
  })])
}

/// A handler's input for a timer that came due at `fireTime`.
public func handlerInput(fireTime: Date) -> JSONValue {
  .object(["fireTime": .string(fireTime.ISO8601Format())])
}
