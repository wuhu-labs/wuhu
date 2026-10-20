import JSONValue
import SpaceCore
import SpaceTools

private let queryRowCap = 500

/// The query tool's `{columns, rows}` output as the model reads it: at most
/// 500 rows, and a line saying how many there were.
public func renderedQuery(_ output: JSONValue) -> String {
  guard case var .object(fields) = output, case let .array(rows)? = fields["rows"], rows.count > queryRowCap else {
    return output.jsonString()
  }
  fields["rows"] = .array(Array(rows.prefix(queryRowCap)))
  return JSONValue.object(fields).jsonString() + "\n(showing the first \(queryRowCap) of \(rows.count) rows)"
}

public func renderedRows(_ rows: Rows) -> String {
  renderedQuery(Wire.queryOutput(rows))
}
