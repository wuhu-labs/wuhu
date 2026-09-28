import DocIndex
import Foundation
import GRDB
import JSONValue
import struct SpaceContract.GroupID
import SpaceFS
import StructuredQueries
import StructuredQueriesSQLite

enum Templates {
  enum Strategy {
    case incr(prefix: String, pad: Int)
    case date(folders: Bool, minute: Bool)
  }

  struct Spec {
    let strategy: Strategy
    let instanceContent: String
  }

  static func parse(_ text: String, path: SpacePath) throws -> Spec {
    let meta = DocIndex.parse(markdown: text, at: path)
    guard let attr = meta.customAttrs.first(where: { $0.name == "template" }),
          case let .jsonObject(json) = attr.value,
          let object = JSONValue.parse(json), object.object != nil
    else { throw SpaceError.templateInvalid(path.rawValue) }

    let strategy = try parseStrategy(object, path: path)
    let (frontmatter, body) = splitFrontmatter(text)
    let stripped = removeTopLevelKey(frontmatter ?? "", key: "template")
    let content = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? body
      : "---\n\(stripped)\n---\n\(body)"
    return Spec(strategy: strategy, instanceContent: content)
  }

  static func allocateName(_ spec: Spec, in directory: SpacePath, group: GroupID, now: Date, in db: Database) throws -> String {
    switch spec.strategy {
    case let .incr(prefix, pad):
      let children = try FSHeadRow.where {
        $0.grp.eq(group.rawValue) && $0.parentPath.eq(directory.rawValue) && $0.kind.eq("file")
      }.fetchAll(db)
      let maxID = children.compactMap { incrementalID($0.path, prefix: prefix) }.max() ?? 0
      let padded = String(maxID + 1)
      let width = max(pad, padded.count)
      return "\(prefix)-\(String(repeating: "0", count: width - padded.count))\(padded).md"
    case let .date(folders, minute):
      return dateName(now: now, folders: folders, minute: minute)
    }
  }

  private static func parseStrategy(_ object: JSONValue, path: SpacePath) throws -> Strategy {
    switch object.object?["strategy"]?.stringValue {
    case "incr":
      let prefix = object.object?["prefix"]?.stringValue ?? ""
      guard !prefix.isEmpty, prefix.allSatisfy({ $0.isUppercase && $0.isLetter && $0.isASCII }) else {
        throw SpaceError.templateInvalid(path.rawValue)
      }
      return .incr(prefix: prefix, pad: object.object?["pad"]?.intValue ?? 1)
    case "date":
      return .date(
        folders: object.object?["folders"]?.boolValue ?? false,
        minute: object.object?["specificity"]?.stringValue == "minute",
      )
    default:
      throw SpaceError.templateInvalid(path.rawValue)
    }
  }

  private static func incrementalID(_ path: String, prefix: String) -> Int? {
    let name = SpacePath.lastComponent(of: path)
    guard name.hasPrefix("\(prefix)-"), name.hasSuffix(".md") else { return nil }
    let digits = name.dropFirst(prefix.count + 1).dropLast(3)
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
  }

  private static func dateName(now: Date, folders: Bool, minute: Bool) -> String {
    // Date-names are human labels, minted in local time; instants elsewhere stay UTC.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
    let year = String(format: "%04d", parts.year ?? 0)
    let month = String(format: "%02d", parts.month ?? 0)
    let day = String(format: "%02d", parts.day ?? 0)
    let time = minute ? String(format: "-%02d-%02d", parts.hour ?? 0, parts.minute ?? 0) : ""
    return folders ? "\(year)/\(month)/\(day)\(time).md" : "\(year)-\(month)-\(day)\(time).md"
  }

  private static func splitFrontmatter(_ content: String) -> (yaml: String?, body: String) {
    let stripped = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
    let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first, first == "---" else { return (nil, content) }
    var closeIndex: Int?
    for index in 1 ..< lines.count where lines[index] == "---" || lines[index] == "..." {
      closeIndex = index
      break
    }
    guard let close = closeIndex else { return (nil, content) }
    return (lines[1 ..< close].joined(separator: "\n"), lines[(close + 1)...].joined(separator: "\n"))
  }

  private static func removeTopLevelKey(_ yaml: String, key: String) -> String {
    let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var result: [String] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if line == "\(key):" || line.hasPrefix("\(key): ") || line.hasPrefix("\(key):\t") {
        index += 1
        while index < lines.count, lines[index].isEmpty || lines[index].first == " " || lines[index].first == "\t" {
          index += 1
        }
        continue
      }
      result.append(line)
      index += 1
    }
    return result.joined(separator: "\n")
  }
}
