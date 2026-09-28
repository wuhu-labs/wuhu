import Foundation
import GRDB
import JSONValue

enum CSV {
  static func renderRow(_ fields: [String]) -> String {
    fields.map(escape).joined(separator: ",")
  }

  static func jsonLiteral(from value: DatabaseValue) -> String {
    switch value.storage {
    case .null: "null"
    case let .int64(int): String(int)
    case let .double(double): JSONValue.number(double).jsonString()
    case let .string(text): JSONValue.string(text).jsonString()
    case let .blob(data): JSONValue.string(data.base64EncodedString()).jsonString()
    }
  }

  static func field(from value: DatabaseValue) -> String {
    switch value.storage {
    case .null: ""
    case let .int64(int): String(int)
    case let .double(double): String(double)
    case let .string(text): text
    case let .blob(data): data.base64EncodedString()
    }
  }

  static func parse(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var field = ""
    var row: [String] = []
    var inQuotes = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if inQuotes {
        if character == "\"" {
          if index + 1 < characters.count, characters[index + 1] == "\"" {
            field.append("\"")
            index += 2
            continue
          }
          inQuotes = false
        } else {
          field.append(character)
        }
        index += 1
        continue
      }
      switch character {
      case "\"": inQuotes = true
      case ",":
        row.append(field)
        field = ""
      case "\n":
        row.append(field)
        rows.append(row)
        field = ""
        row = []
      case "\r": break
      default: field.append(character)
      }
      index += 1
    }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }

  private static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
