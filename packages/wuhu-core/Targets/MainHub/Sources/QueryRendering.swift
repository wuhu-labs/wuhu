import SpaceCore
import SpaceTools

private let queryRowCap = 500

public func renderedRows(_ rows: Rows) -> String {
  let limited = Rows(
    columns: rows.columns,
    decltypes: rows.decltypes,
    rows: Array(rows.rows.prefix(queryRowCap)),
  )
  var output = Wire.queryOutput(limited).jsonString()
  if rows.rows.count > queryRowCap {
    output += "\n(showing the first \(queryRowCap) of \(rows.rows.count) rows)"
  }
  return output
}
