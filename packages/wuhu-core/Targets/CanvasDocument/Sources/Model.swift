import Loro
import WmdDocument

/// An item's or a connector's id: 6 base-36 characters, unique in the board. Agents and
/// connectors name items by it, never by their tree node.
public struct CanvasID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue.utf8.count == Self.length, rawValue.utf8.allSatisfy(Self.isDigit) else { return nil }
    self.rawValue = rawValue
  }

  public static func random(avoiding taken: Set<CanvasID>) -> CanvasID {
    var generator = SystemRandomNumberGenerator()
    return random(avoiding: taken, using: &generator)
  }

  public static func random(avoiding taken: Set<CanvasID>, using generator: inout some RandomNumberGenerator) -> CanvasID {
    while true {
      let digits = (0 ..< length).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] }
      let id = CanvasID(rawValue: String(decoding: digits, as: UTF8.self))!
      if !taken.contains(id) { return id }
    }
  }

  public static func < (lhs: CanvasID, rhs: CanvasID) -> Bool { lhs.rawValue < rhs.rawValue }
  public var description: String { self.rawValue }

  static let length = 6
  private static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)
  private static func isDigit(_ byte: UInt8) -> Bool { (0x30 ... 0x39).contains(byte) || (0x61 ... 0x7A).contains(byte) }
}

/// One item as stored: `x` and `y` are relative to its section's origin (the board's at top level).
public struct CanvasItem: Hashable, Sendable {
  public var id: CanvasID
  public var kind: CanvasKind
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double
  /// nil for free text, which has no colour.
  public var color: CanvasColor?
  /// A section's title; a file card's is unused.
  public var text: Inline
  /// The space path a file card shows.
  public var path: String?
  /// The section holding the item.
  public var parent: CanvasID?

  public init(
    id: CanvasID, kind: CanvasKind, x: Double, y: Double, w: Double, h: Double, color: CanvasColor? = nil, text: Inline = Inline(),
    path: String? = nil, parent: CanvasID? = nil,
  ) {
    self.id = id
    self.kind = kind
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.color = color
    self.text = text
    self.path = path
    self.parent = parent
  }
}

public struct CanvasConnector: Hashable, Sendable {
  public var id: CanvasID
  public var from: CanvasID
  public var to: CanvasID
  /// nil is auto: the midpoint of the side facing the other item.
  public var fromSide: CanvasSide?
  public var toSide: CanvasSide?
  public var style: ConnectorStyle
  /// How far an elbow's middle segment sits from halfway between its ends; 0 for a straight connector.
  public var offset: Double
  public var arrow: ConnectorArrow
  public var label: Inline

  public init(
    id: CanvasID, from: CanvasID, to: CanvasID, fromSide: CanvasSide? = nil, toSide: CanvasSide? = nil, style: ConnectorStyle = .straight,
    offset: Double = 0, arrow: ConnectorArrow = .end, label: Inline = Inline(),
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.fromSide = fromSide
    self.toSide = toSide
    self.style = style
    self.offset = offset
    self.arrow = arrow
    self.label = label
  }
}

/// A board as readers see it. Anything outside the schema is skipped: an unknown kind, a node
/// under a non-section, a section inside a section, a repeated id, a connector to a missing item.
public struct CanvasBoard: Hashable, Sendable {
  /// Top-level siblings in sibling order, each section followed by its children in theirs.
  public var items: [CanvasItem]
  /// By id.
  public var connectors: [CanvasConnector]

  public init(items: [CanvasItem] = [], connectors: [CanvasConnector] = []) {
    self.items = items
    self.connectors = connectors
  }

  public init(doc: LoroDoc) {
    self = Self.read(doc).board
  }

  public func item(_ id: CanvasID) -> CanvasItem? {
    self.items.first { $0.id == id }
  }

  /// The item's frame in board points.
  public func frame(of item: CanvasItem) -> CanvasRect {
    let origin = item.parent.flatMap(self.item).map { (x: $0.x, y: $0.y) } ?? (x: 0, y: 0)
    return CanvasRect(x: origin.x + item.x, y: origin.y + item.y, w: item.w, h: item.h)
  }

  /// The board and the tree node of each item.
  static func read(_ doc: LoroDoc) -> (board: CanvasBoard, nodes: [CanvasID: TreeId]) {
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    var items: [CanvasItem] = []
    var nodes: [CanvasID: TreeId] = [:]
    func take(_ node: TreeId, parent: CanvasID?) -> CanvasItem? {
      guard let meta = try? tree.getMeta(target: node), let item = Self.item(meta, parent: parent), nodes[item.id] == nil else { return nil }
      if parent != nil, item.kind == .section { return nil }
      nodes[item.id] = node
      items.append(item)
      return item
    }
    for node in tree.children(parent: .root) ?? [] {
      guard let item = take(node, parent: nil), item.kind == .section else { continue }
      for child in tree.children(parent: .node(id: node)) ?? [] {
        _ = take(child, parent: item.id)
      }
    }
    let map = doc.getMap(id: CanvasSchema.Key.connectors)
    let connectors = map.keys().sorted().compactMap { key -> CanvasConnector? in
      guard let id = CanvasID(rawValue: key), nodes[id] == nil, let entry = map.get(key: key)?.asLoroMap(),
            let connector = Self.connector(id, entry), nodes[connector.from] != nil, nodes[connector.to] != nil else { return nil }
      return connector
    }
    return (CanvasBoard(items: items, connectors: connectors), nodes)
  }

  private static func item(_ meta: LoroMap, parent: CanvasID?) -> CanvasItem? {
    func value(_ key: String) -> LoroValue? { meta.get(key: key)?.asValue() }
    guard let id = CanvasSchema.string(value(CanvasSchema.Key.id)).flatMap(CanvasID.init(rawValue:)),
          let kind = CanvasSchema.string(value(CanvasSchema.Key.kind)).flatMap(CanvasKind.init(rawValue:)),
          let x = CanvasSchema.number(value(CanvasSchema.Key.x)), let y = CanvasSchema.number(value(CanvasSchema.Key.y)),
          let w = CanvasSchema.number(value(CanvasSchema.Key.w)), let h = CanvasSchema.number(value(CanvasSchema.Key.h)), w >= 0, h >= 0
    else { return nil }
    let path = CanvasSchema.string(value(CanvasSchema.Key.path))
    if kind == .file, path == nil { return nil }
    let color = kind.isColored ? CanvasSchema.string(value(CanvasSchema.Key.color)).flatMap(CanvasColor.init(rawValue:)) : nil
    return CanvasItem(
      id: id, kind: kind, x: x, y: y, w: w, h: h, color: color, text: Inline(meta.get(key: CanvasSchema.Key.text)?.asLoroText()),
      path: kind == .file ? path : nil, parent: parent,
    )
  }

  private static func connector(_ id: CanvasID, _ map: LoroMap) -> CanvasConnector? {
    func string(_ key: String) -> String? { CanvasSchema.string(map.get(key: key)?.asValue()) }
    guard let from = string(CanvasSchema.Key.from).flatMap(CanvasID.init(rawValue:)),
          let to = string(CanvasSchema.Key.to).flatMap(CanvasID.init(rawValue:)) else { return nil }
    return CanvasConnector(
      id: id, from: from, to: to,
      fromSide: string(CanvasSchema.Key.fromSide).flatMap(CanvasSide.init(rawValue:)),
      toSide: string(CanvasSchema.Key.toSide).flatMap(CanvasSide.init(rawValue:)),
      style: string(CanvasSchema.Key.style).flatMap(ConnectorStyle.init(rawValue:)) ?? .straight,
      offset: CanvasSchema.number(map.get(key: CanvasSchema.Key.offset)?.asValue()) ?? 0,
      arrow: string(CanvasSchema.Key.arrow).flatMap(ConnectorArrow.init(rawValue:)) ?? .end,
      label: Inline(map.get(key: CanvasSchema.Key.label)?.asLoroText()),
    )
  }
}
