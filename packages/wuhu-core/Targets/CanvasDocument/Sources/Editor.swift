import Loro
import WmdDocument

public enum CanvasEditError: Error, Hashable, Sendable {
  case unknown(CanvasID)
  /// Items go into sections only, and sections sit at the top level.
  case notASection(CanvasID)
  case nestedSection(CanvasID)
}

/// What a delete removed, the cascade included.
public struct CanvasDeletion: Hashable, Sendable {
  public var items: [CanvasID] = []
  public var connectors: [CanvasID] = []
}

/// Edits a board's Loro doc in board terms: frames are absolute board points, ids are board ids.
/// It only issues operations; the caller commits and exports. It indexes the board when made, so
/// make one per gesture or transaction, not across imports of other peers' updates.
public struct CanvasEditor {
  let doc: LoroDoc
  private let tree: LoroTree
  private let connectorMap: LoroMap
  private var nodes: [CanvasID: TreeId]
  private var taken: Set<CanvasID>

  public init(_ doc: LoroDoc) {
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    let connectorMap = doc.getMap(id: CanvasSchema.Key.connectors)
    let hidden = tree.nodes().compactMap { node in
      (try? tree.getMeta(target: node)).flatMap { CanvasSchema.string($0.get(key: CanvasSchema.Key.id)?.asValue()) }
    }
    self.doc = doc
    self.tree = tree
    self.connectorMap = connectorMap
    self.nodes = CanvasBoard.read(doc).nodes
    self.taken = Set((hidden + connectorMap.keys()).compactMap(CanvasID.init(rawValue:)))
  }

  // MARK: Items

  /// A new item on top of its siblings.
  @discardableResult
  public mutating func insert(
    _ kind: CanvasKind, frame: CanvasRect, color: CanvasColor?, text: Inline = Inline(), path: String? = nil, in section: CanvasID? = nil,
  ) throws -> CanvasID {
    try self.insert(kind, frame: frame, color: color, text: text, path: path, in: section, id: self.newID())
  }

  @discardableResult
  mutating func insert(
    _ kind: CanvasKind, frame: CanvasRect, color: CanvasColor?, text: Inline, path: String?, in section: CanvasID?, id: CanvasID,
  ) throws -> CanvasID {
    let parent = try self.parent(for: kind, in: section)
    let node = try self.tree.create(parent: parent)
    let meta = try self.tree.getMeta(target: node)
    let origin = try self.origin(of: parent)
    try meta.insert(key: CanvasSchema.Key.id, v: id.rawValue)
    try meta.insert(key: CanvasSchema.Key.kind, v: kind.rawValue)
    try meta.insert(key: CanvasSchema.Key.x, v: frame.x - origin.x)
    try meta.insert(key: CanvasSchema.Key.y, v: frame.y - origin.y)
    try meta.insert(key: CanvasSchema.Key.w, v: frame.w)
    try meta.insert(key: CanvasSchema.Key.h, v: frame.h)
    if kind.isColored, let color { try meta.insert(key: CanvasSchema.Key.color, v: color.rawValue) }
    if kind == .file, let path { try meta.insert(key: CanvasSchema.Key.path, v: path) }
    if !text.isEmpty { try meta.getOrCreateTextContainer(key: CanvasSchema.Key.text, child: LoroText()).sync(to: text) }
    self.nodes[id] = node
    self.taken.insert(id)
    return id
  }

  /// `frame` in board points; the item keeps its section.
  public func setFrame(_ id: CanvasID, _ frame: CanvasRect) throws {
    try self.setPosition(id, x: frame.x, y: frame.y)
    try self.setSize(id, CanvasSize(w: frame.w, h: frame.h))
  }

  /// In board points.
  func setPosition(_ id: CanvasID, x: Double, y: Double) throws {
    let node = try self.node(id)
    let origin = try self.origin(of: self.tree.parent(target: node))
    let meta = try self.tree.getMeta(target: node)
    try set(meta, CanvasSchema.Key.x, x - origin.x)
    try set(meta, CanvasSchema.Key.y, y - origin.y)
  }

  func setSize(_ id: CanvasID, _ size: CanvasSize) throws {
    let meta = try self.meta(id)
    try set(meta, CanvasSchema.Key.w, size.w)
    try set(meta, CanvasSchema.Key.h, size.h)
  }

  /// Puts siblings in this order among themselves, moving as few as it can: those off a longest
  /// run already in order.
  func order(_ ids: [CanvasID]) throws {
    guard let first = ids.first, ids.count > 1 else { return }
    let nodes = try ids.map(self.node)
    let siblings = try self.tree.children(parent: self.tree.parent(target: self.node(first))) ?? []
    let kept = longestIncreasingRun(nodes.map { siblings.firstIndex(of: $0) ?? 0 })
    guard let anchor = kept.min() else { return }
    for index in nodes.indices where !kept.contains(index) {
      if index == 0 {
        try self.tree.movBefore(target: nodes[index], before: nodes[anchor])
      } else {
        try self.tree.movAfter(target: nodes[index], after: nodes[index - 1])
      }
    }
  }

  /// Moves each item by the offset; one inside a section that also moves rides along with it.
  public func move(_ ids: [CanvasID], dx: Double, dy: Double) throws {
    let moving = Set(ids)
    for id in moving {
      let node = try self.node(id)
      if case let .node(parent) = try self.tree.parent(target: node), let section = self.id(of: parent), moving.contains(section) { continue }
      let meta = try self.tree.getMeta(target: node)
      try set(meta, CanvasSchema.Key.x, (CanvasSchema.number(meta.get(key: CanvasSchema.Key.x)?.asValue()) ?? 0) + dx)
      try set(meta, CanvasSchema.Key.y, (CanvasSchema.number(meta.get(key: CanvasSchema.Key.y)?.asValue()) ?? 0) + dy)
    }
  }

  /// Moves the item into `section` (nil: the board), on top of its new siblings, where it stands.
  public func reparent(_ id: CanvasID, into section: CanvasID?) throws {
    let node = try self.node(id)
    let meta = try self.tree.getMeta(target: node)
    let kind = CanvasSchema.string(meta.get(key: CanvasSchema.Key.kind)?.asValue()).flatMap(CanvasKind.init(rawValue:))
    let parent = try self.parent(for: kind ?? .sticky, in: section)
    let from = try self.tree.parent(target: node)
    guard from != parent else { return }
    let old = try self.origin(of: from)
    let new = try self.origin(of: parent)
    let x = (CanvasSchema.number(meta.get(key: CanvasSchema.Key.x)?.asValue()) ?? 0) + old.x - new.x
    let y = (CanvasSchema.number(meta.get(key: CanvasSchema.Key.y)?.asValue()) ?? 0) + old.y - new.y
    try self.tree.mov(target: node, parent: parent)
    try set(meta, CanvasSchema.Key.x, x)
    try set(meta, CanvasSchema.Key.y, y)
  }

  /// Paints the item above its siblings.
  public func bringToFront(_ id: CanvasID) throws {
    let node = try self.node(id)
    guard let last = try self.tree.children(parent: self.tree.parent(target: node))?.last, last != node else { return }
    try self.tree.movAfter(target: node, after: last)
  }

  /// Deletes the items, a section's contents and every connector touching one of them.
  @discardableResult
  public mutating func delete(_ ids: [CanvasID]) throws -> CanvasDeletion {
    var gone: Set<CanvasID> = []
    for id in ids {
      let node = try self.node(id)
      for child in self.tree.children(parent: .node(id: node)) ?? [] {
        if let child = self.id(of: child) { gone.insert(child) }
      }
      gone.insert(id)
    }
    let removed = gone.sorted()
    var deletion = CanvasDeletion(items: removed)
    for key in self.connectorMap.keys().sorted() {
      guard let id = CanvasID(rawValue: key), let entry = self.connectorMap.get(key: key)?.asLoroMap() else { continue }
      let ends = [CanvasSchema.Key.from, CanvasSchema.Key.to].compactMap { CanvasSchema.string(entry.get(key: $0)?.asValue()).flatMap(CanvasID.init(rawValue:)) }
      guard ends.contains(where: gone.contains) else { continue }
      try self.connectorMap.delete(key: key)
      deletion.connectors.append(id)
    }
    for id in removed {
      guard let node = self.nodes.removeValue(forKey: id) else { continue }
      if try !self.tree.isNodeDeleted(target: node) { try self.tree.delete(target: node) }
    }
    return deletion
  }

  /// Copies the items, offset; a section brings its contents, and connectors between copied items
  /// are copied too. Answers each original's copy.
  public mutating func duplicate(_ ids: [CanvasID], dx: Double, dy: Double) throws -> [CanvasID: CanvasID] {
    let board = CanvasBoard(doc: self.doc)
    let chosen = Set(ids)
    var copies: [CanvasID: CanvasID] = [:]
    for item in board.items where chosen.contains(item.id) || item.parent.map(chosen.contains) == true {
      let copiedSection = item.parent.flatMap { copies[$0] }
      let placed: CanvasRect
      if let copiedSection {
        let origin = try self.origin(of: .node(id: self.node(copiedSection)))
        placed = CanvasRect(x: origin.x + item.x, y: origin.y + item.y, w: item.w, h: item.h)
      } else {
        let frame = board.frame(of: item)
        placed = CanvasRect(x: frame.x + dx, y: frame.y + dy, w: item.w, h: item.h)
      }
      let section = copiedSection ?? item.parent
      copies[item.id] = try self.insert(item.kind, frame: placed, color: item.color, text: item.text, path: item.path, in: section)
    }
    for connector in board.connectors {
      guard let from = copies[connector.from], let to = copies[connector.to] else { continue }
      var copy = connector
      copy.from = from
      copy.to = to
      try self.connect(copy, id: self.newID())
    }
    return copies
  }

  /// nil clears it; free text takes none.
  public func setColor(_ ids: [CanvasID], _ color: CanvasColor?) throws {
    for id in ids {
      let meta = try self.meta(id)
      if let color, CanvasSchema.string(meta.get(key: CanvasSchema.Key.kind)?.asValue()) != CanvasKind.text.rawValue {
        try set(meta, CanvasSchema.Key.color, color.rawValue)
      } else if meta.get(key: CanvasSchema.Key.color) != nil {
        try meta.delete(key: CanvasSchema.Key.color)
      }
    }
  }

  /// Leaving `file` drops the path, so no reader meets a stray one.
  public func setKind(_ id: CanvasID, _ kind: CanvasKind) throws {
    let meta = try self.meta(id)
    try set(meta, CanvasSchema.Key.kind, kind.rawValue)
    if kind != .file { try set(meta, CanvasSchema.Key.path, nil as String?) }
  }

  public func setText(_ id: CanvasID, _ text: Inline) throws {
    try self.meta(id).getOrCreateTextContainer(key: CanvasSchema.Key.text, child: LoroText()).sync(to: text)
  }

  public func setPath(_ id: CanvasID, _ path: String) throws {
    try set(self.meta(id), CanvasSchema.Key.path, path)
  }

  // MARK: Connectors

  @discardableResult
  public mutating func connect(
    from: CanvasID, to: CanvasID, fromSide: CanvasSide? = nil, toSide: CanvasSide? = nil, style: ConnectorStyle = .straight,
    arrow: ConnectorArrow = .end, label: Inline = Inline(),
  ) throws -> CanvasID {
    let id = self.newID()
    try self.connect(CanvasConnector(id: id, from: from, to: to, fromSide: fromSide, toSide: toSide, style: style, arrow: arrow, label: label), id: id)
    return id
  }

  mutating func connect(_ connector: CanvasConnector, id: CanvasID) throws {
    for end in [connector.from, connector.to] where self.nodes[end] == nil { throw CanvasEditError.unknown(end) }
    var connector = connector
    connector.id = id
    let map = try self.connectorMap.insertContainer(key: id.rawValue, child: LoroMap())
    try write(connector, into: map, over: nil)
    self.taken.insert(id)
  }

  /// Changes a connector's fields; its id stays.
  public func updateConnector(_ id: CanvasID, _ change: (inout CanvasConnector) -> Void) throws {
    guard let map = self.connectorMap.get(key: id.rawValue)?.asLoroMap(), let current = CanvasBoard(doc: self.doc).connectors.first(where: { $0.id == id })
    else { throw CanvasEditError.unknown(id) }
    var next = current
    change(&next)
    next.id = id
    for end in [next.from, next.to] where self.nodes[end] == nil { throw CanvasEditError.unknown(end) }
    try write(next, into: map, over: current)
  }

  public func deleteConnector(_ id: CanvasID) throws {
    guard self.connectorMap.get(key: id.rawValue) != nil else { throw CanvasEditError.unknown(id) }
    try self.connectorMap.delete(key: id.rawValue)
  }

  // MARK: Internals

  mutating func newID() -> CanvasID {
    var generator = SystemRandomNumberGenerator()
    return self.newID(using: &generator)
  }

  mutating func newID(using generator: inout some RandomNumberGenerator) -> CanvasID {
    let id = CanvasID.random(avoiding: self.taken, using: &generator)
    self.taken.insert(id)
    return id
  }

  func node(_ id: CanvasID) throws -> TreeId {
    guard let node = self.nodes[id] else { throw CanvasEditError.unknown(id) }
    return node
  }

  func meta(_ id: CanvasID) throws -> LoroMap {
    try self.tree.getMeta(target: self.node(id))
  }

  private func id(of node: TreeId) -> CanvasID? {
    self.nodes.first { $0.value == node }?.key
  }

  private func parent(for kind: CanvasKind, in section: CanvasID?) throws -> TreeParentId {
    guard let section else { return .root }
    if kind == .section { throw CanvasEditError.nestedSection(section) }
    let node = try self.node(section)
    guard try CanvasSchema.string(self.tree.getMeta(target: node).get(key: CanvasSchema.Key.kind)?.asValue()) == CanvasKind.section.rawValue,
          try self.tree.parent(target: node) == .root else { throw CanvasEditError.notASection(section) }
    return .node(id: node)
  }

  private func origin(of parent: TreeParentId) throws -> (x: Double, y: Double) {
    guard case let .node(node) = parent else { return (0, 0) }
    let meta = try self.tree.getMeta(target: node)
    return (CanvasSchema.number(meta.get(key: CanvasSchema.Key.x)?.asValue()) ?? 0, CanvasSchema.number(meta.get(key: CanvasSchema.Key.y)?.asValue()) ?? 0)
  }
}

/// The indices of one longest strictly increasing subsequence.
func longestIncreasingRun(_ values: [Int]) -> Set<Int> {
  var tails: [Int] = []
  var previous = [Int?](repeating: nil, count: values.count)
  for (index, value) in values.enumerated() {
    var low = 0
    var high = tails.count
    while low < high {
      let middle = (low + high) / 2
      if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
    }
    if low > 0 { previous[index] = tails[low - 1] }
    if low == tails.count { tails.append(index) } else { tails[low] = index }
  }
  var run: Set<Int> = []
  var cursor = tails.last
  while let index = cursor {
    run.insert(index)
    cursor = previous[index]
  }
  return run
}

/// Writes only what differs, so a no-op edit makes no operation.
func set(_ map: LoroMap, _ key: String, _ value: Double) throws {
  if CanvasSchema.number(map.get(key: key)?.asValue()) != value { try map.insert(key: key, v: value) }
}

func set(_ map: LoroMap, _ key: String, _ value: String?) throws {
  guard let value else {
    if map.get(key: key) != nil { try map.delete(key: key) }
    return
  }
  if CanvasSchema.string(map.get(key: key)?.asValue()) != value { try map.insert(key: key, v: value) }
}

private func write(_ connector: CanvasConnector, into map: LoroMap, over current: CanvasConnector?) throws {
  try set(map, CanvasSchema.Key.from, connector.from.rawValue)
  try set(map, CanvasSchema.Key.to, connector.to.rawValue)
  try set(map, CanvasSchema.Key.fromSide, connector.fromSide?.rawValue)
  try set(map, CanvasSchema.Key.toSide, connector.toSide?.rawValue)
  try set(map, CanvasSchema.Key.style, connector.style.rawValue)
  try set(map, CanvasSchema.Key.arrow, connector.arrow.rawValue)
  if current?.offset != connector.offset {
    if connector.offset == 0, map.get(key: CanvasSchema.Key.offset) != nil {
      try map.delete(key: CanvasSchema.Key.offset)
    } else if connector.offset != 0 {
      try map.insert(key: CanvasSchema.Key.offset, v: connector.offset)
    }
  }
  if current?.label != connector.label {
    try map.getOrCreateTextContainer(key: CanvasSchema.Key.label, child: LoroText()).sync(to: connector.label)
  }
}
