#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import SpaceContract

func formatList(_ output: ListOutput) -> String {
  let sizeWidth = output.entries.map { String($0.size).count }.max() ?? 1
  return output.entries.map { entry in
    "\(marker(entry.kind)) \(String(entry.size).leftPadded(to: sizeWidth)) \(entry.name)\n"
  }.joined()
}

func formatStat(_ entry: Entry) -> String {
  var fields = [
    "kind=\(kindWord(entry.kind))",
    "size=\(entry.size) B",
  ]
  if let lineCount = entry.lineCount {
    fields.append("lines=\(lineCount)")
  }
  fields.append("token=\(entry.token)")
  fields.append("mtime=\(formatTimestamp(entry.mtime))")
  fields.append("name=\(entry.name)")
  return fields.joined(separator: " ")
}

func formatGrep(_ output: GrepOutput) -> String {
  var text = output.matches.map { match in
    "\(match.path):\(match.line):\(match.text)\n"
  }.joined()
  if let cursor = output.cursor {
    text += "cursor \(cursor)\n"
  }
  return text
}

func formatHistory(_ output: HistoryOutput) -> String {
  output.entries.map { entry in
    var parts = [String(entry.rev), entry.change.rawValue, trimDouble(entry.mtime)]
    if let to = entry.to {
      parts.append("to=\(to)")
    }
    if let fromRev = entry.fromRev {
      parts.append("fromRev=\(fromRev)")
    }
    return parts.joined(separator: " ") + "\n"
  }.joined()
}

func formatQuery(_ output: QueryOutput) -> String {
  var lines: [String] = []
  if !output.columns.isEmpty {
    lines.append(output.columns.joined(separator: "\t"))
  }
  for row in output.rows {
    lines.append(row.map(formatCell).joined(separator: "\t"))
  }
  return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
}

private func marker(_ kind: EntryKind) -> String {
  switch kind {
  case .directory: "d"
  case .file: "-"
  case .table: "t"
  case .symlink: "l"
  }
}

private func kindWord(_ kind: EntryKind) -> String {
  switch kind {
  case .directory: "directory"
  case .file: "file"
  case .table: "table"
  case .symlink: "symlink"
  }
}

func formatTimestamp(_ seconds: Double) -> String {
  isoFormatted(Date(timeIntervalSince1970: seconds), in: .current)
}

private func formatCell(_ value: JSONValue) -> String {
  if let string = value.stringValue {
    return string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }
  return value.jsonString()
}

private func trimDouble(_ value: Double) -> String {
  let rounded = value.rounded()
  if rounded == value {
    return String(Int(rounded))
  }
  return String(value)
}

private extension String {
  func leftPadded(to width: Int) -> String {
    guard self.count < width else { return self }
    return String(repeating: " ", count: width - self.count) + self
  }
}
