#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Loro

enum Key {
  static let frontmatter = "frontmatter"
  static let blocks = "blocks"
  static let kind = "kind"
  static let level = "level"
  static let style = "style"
  static let text = "text"
  static let view = "view"
  static let config = "config"
  static let sql = "sql"
  static let bold = "bold"
  static let italic = "italic"
  static let link = "link"
}

func configure(_ doc: LoroDoc) {
  let styles = StyleConfigMap()
  styles.insert(key: Key.bold, value: StyleConfig(expand: .after))
  styles.insert(key: Key.italic, value: StyleConfig(expand: .after))
  styles.insert(key: Key.link, value: StyleConfig(expand: .none))
  doc.configTextStyle(textStyle: styles)
}

/// A block as it sits in the movable list; `position` counts every item, readable or not.
struct Placed {
  var position: UInt32
  var block: Block
}

/// Blocks a client wrote outside the schema are skipped, never repaired: the agent view cannot
/// say them, and a merge leaves them where they are.
func project(_ doc: LoroDoc) -> (content: Content, placed: [Placed]) {
  var frontmatter: [String: JSONValue] = [:]
  let map = doc.getMap(id: Key.frontmatter)
  for key in map.keys() {
    if let value = map.get(key: key)?.asValue() { frontmatter[key] = json(value) }
  }
  let list = doc.getMovableList(id: Key.blocks)
  var placed: [Placed] = []
  for position in 0 ..< list.len() {
    guard let item = list.get(index: position)?.asLoroMap(), let block = block(of: item) else { continue }
    placed.append(Placed(position: position, block: block))
  }
  return (Content(frontmatter: frontmatter, blocks: placed.map(\.block)), placed)
}

private func block(of map: LoroMap) -> Block? {
  guard case let .string(kind)? = map.get(key: Key.kind)?.asValue() else { return nil }
  let text = map.get(key: Key.text)?.asLoroText()
  switch kind {
  case "h1", "h2", "h3": return .heading(level: Int(String(kind.dropFirst()))!, text: inline(of: text))
  case "paragraph": return .paragraph(inline(of: text))
  case "code": return .code(text?.toString() ?? "")
  case "list":
    guard let level = listLevel(map.get(key: Key.level)?.asValue()),
          case let .string(raw)? = map.get(key: Key.style)?.asValue(), let style = ListStyle(rawValue: raw) else { return nil }
    return .list(level: level, style: style, text: inline(of: text))
  case "view":
    guard case let .string(view)? = map.get(key: Key.view)?.asValue(),
          case let .string(sql)? = map.get(key: Key.sql)?.asValue() else { return nil }
    return .view(view: view, config: map.get(key: Key.config)?.asValue().map(json) ?? .object([:]), sql: sql)
  default: return nil
  }
}

/// loro-crdt stores a JS number as a double, so a level the web wrote arrives as one.
private func listLevel(_ value: LoroValue?) -> Int? {
  switch value {
  case let .i64(level)? where level >= 0: Int(level)
  case let .double(level)? where level >= 0 && level == level.rounded() && level < 64: Int(level)
  default: nil
  }
}

private func inline(of text: LoroText?) -> Inline {
  guard let text else { return Inline() }
  return Inline(text.toDelta().compactMap { delta in
    guard case let .insert(string, attributes) = delta else { return nil }
    return Run(text: string, marks: marks(attributes ?? [:]))
  })
}

private func marks(_ attributes: [String: LoroValue]) -> Marks {
  var marks = Marks()
  marks.bold = attributes[Key.bold] == .bool(value: true)
  marks.italic = attributes[Key.italic] == .bool(value: true)
  if case let .string(url)? = attributes[Key.link] { marks.link = url }
  return marks
}

func json(_ value: LoroValue) -> JSONValue {
  switch value {
  case .null, .container, .binary: .null
  case let .bool(flag): .bool(flag)
  case let .double(number): .number(number)
  case let .i64(number): .integer(Int(number))
  case let .string(string): .string(string)
  case let .list(items): .array(items.map(json))
  case let .map(entries): .object(.init(uniqueKeysWithValues: entries.sorted { $0.key < $1.key }.map { ($0.key, json($0.value)) }))
  }
}

func loro(_ value: JSONValue) -> LoroValue {
  switch value {
  case .null: .null
  case let .bool(flag): .bool(value: flag)
  case let .integer(number): .i64(value: Int64(number))
  case let .number(number): .double(value: number)
  case let .string(string): .string(value: string)
  case let .array(items): .list(value: items.map(loro))
  case let .object(entries): .map(value: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, loro($0.value)) }))
  }
}
