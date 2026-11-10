#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import Loro

/// A block as it sits in the movable list; `position` counts every item, readable or not.
struct Placed {
  var position: UInt32
  var block: Block
}

/// Blocks a client wrote outside the schema are skipped, never repaired: the agent view cannot
/// say them, and a merge leaves them where they are.
func project(_ doc: LoroDoc) -> (content: Content, placed: [Placed]) {
  var frontmatter: [String: JSONValue] = [:]
  let map = doc.getMap(id: WmdSchema.Key.frontmatter)
  for key in map.keys() {
    if let value = map.get(key: key)?.asValue() { frontmatter[key] = json(value) }
  }
  let placed = placed(in: doc.getMovableList(id: WmdSchema.Key.blocks))
  return (Content(frontmatter: frontmatter, blocks: placed.map(\.block)), placed)
}

func placed(in list: LoroMovableList) -> [Placed] {
  (0 ..< list.len()).compactMap { position in
    list.get(index: position)?.asLoroMap().flatMap(block(of:)).map { Placed(position: position, block: $0) }
  }
}

private func block(of map: LoroMap) -> Block? {
  guard let kind = WmdSchema.Kind(map) else { return nil }
  let text = map.get(key: WmdSchema.Key.text)?.asLoroText()
  return switch kind {
  case let .heading(level): .heading(level: level, text: Inline(text))
  case .paragraph: .paragraph(Inline(text))
  case .code: .code(text?.toString() ?? "")
  case let .list(level, style): .list(level: level, style: style, text: Inline(text))
  case let .view(view, sql): .view(view: view, config: map.get(key: WmdSchema.Key.config)?.asValue().map(json) ?? .object([:]), sql: sql)
  }
}

extension Inline {
  /// The text with its `bold`, `italic`, `link` and `code` marks; nil reads as empty.
  public init(_ text: LoroText?) {
    guard let text else {
      self.init()
      return
    }
    self.init(text.toDelta().compactMap { delta in
      guard case let .insert(string, attributes) = delta else { return nil }
      return InlineRun(text: string, marks: marks(attributes ?? [:]))
    })
  }
}

private func marks(_ attributes: [String: LoroValue]) -> InlineMarks {
  if attributes[WmdSchema.Key.code] == .bool(value: true) { return .code }
  let link: String? = if case let .string(url)? = attributes[WmdSchema.Key.link] { url } else { nil }
  return .text(bold: attributes[WmdSchema.Key.bold] == .bool(value: true), italic: attributes[WmdSchema.Key.italic] == .bool(value: true), link: link)
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
