#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import struct SpaceFS.SpacePath

/// A markdown file whose frontmatter `template:` says how its instances are named; an instance is
/// the file without that key, and without its frontmatter when nothing else is left in it.
public struct DocumentTemplate: Codable, Hashable, Sendable {
  public enum Naming: Codable, Hashable, Sendable {
    /// `<prefix>-<n>.md`, `n` one past the largest among the folder's files, zero-padded to `pad`.
    case incr(prefix: String, pad: Int)
    /// The date, `yyyy-mm-dd` or `yyyy/mm/dd` with `folders`, then `-HH-MM` with `minute`.
    case date(folders: Bool, minute: Bool)
  }

  public var naming: Naming
  public var instance: String

  /// nil when the file has no `template:` object naming a known strategy.
  public init?(markdown text: String, at path: SpacePath) {
    guard let attribute = DocIndex.parse(markdown: text, at: path).customAttrs.first(where: { $0.name == "template" }),
          case let .jsonObject(json) = attribute.value, let object = JSONValue.parse(json)?.object,
          let naming = Self.naming(object)
    else { return nil }
    let (frontmatter, body) = splitFrontmatter(text)
    let kept = Self.removingTopLevelKey("template", from: frontmatter ?? "")
    self.naming = naming
    instance = kept.allSatisfy(\.isWhitespace) ? body : "---\n\(kept)\n---\n\(body)"
  }

  /// The instance's path relative to its folder, whose files' names are `files`.
  public func name(among files: some Sequence<String>, at now: Date, in timeZone: TimeZone) -> String {
    switch naming {
    case let .incr(prefix, pad):
      let largest = files.compactMap { Self.number(in: $0, prefix: prefix) }.max() ?? 0
      return "\(prefix)-\(Self.padded(largest + 1, pad)).md"
    case let .date(folders, minute):
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
      let (year, month, day) = (Self.padded(parts.year!, 4), Self.padded(parts.month!, 2), Self.padded(parts.day!, 2))
      let time = minute ? "-\(Self.padded(parts.hour!, 2))-\(Self.padded(parts.minute!, 2))" : ""
      return folders ? "\(year)/\(month)/\(day)\(time).md" : "\(year)-\(month)-\(day)\(time).md"
    }
  }

  private static func naming(_ object: OrderedDictionary<String, JSONValue>) -> Naming? {
    switch object["strategy"]?.stringValue {
    case "incr":
      guard let prefix = object["prefix"]?.stringValue, !prefix.isEmpty,
            prefix.allSatisfy({ $0.isUppercase && $0.isLetter && $0.isASCII })
      else { return nil }
      return .incr(prefix: prefix, pad: object["pad"]?.intValue ?? 1)
    case "date":
      return .date(folders: object["folders"]?.boolValue ?? false, minute: object["specificity"]?.stringValue == "minute")
    default:
      return nil
    }
  }

  private static func number(in name: String, prefix: String) -> Int? {
    guard name.hasPrefix("\(prefix)-"), name.hasSuffix(".md") else { return nil }
    let digits = name.dropFirst(prefix.count + 1).dropLast(3)
    guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
  }

  private static func padded(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  private static func removingTopLevelKey(_ key: String, from yaml: String) -> String {
    var kept: [Substring] = []
    var inKey = false
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
      if line == "\(key):" || line.hasPrefix("\(key): ") || line.hasPrefix("\(key):\t") {
        inKey = true
      } else if inKey, line.isEmpty || line.first == " " || line.first == "\t" {
        continue
      } else {
        inKey = false
        kept.append(line)
      }
    }
    return kept.joined(separator: "\n")
  }
}
