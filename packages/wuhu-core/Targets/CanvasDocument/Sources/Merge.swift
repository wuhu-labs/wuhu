import Loro
import WmdDocument

extension CanvasBoard {
  /// Edits `doc`, at the version the agent read, into what the agent view `text` says, diffing by
  /// id. Answers a note per connector its line kept but a deleted end took along. New ids come
  /// from `seed`, so a write is deterministic. `restoring` (an older revision's text) creates
  /// the ids the board no longer has instead of refusing them. Throws `CanvasSyntaxError` for a
  /// refused text.
  static func merge(_ text: String, into doc: LoroDoc, seed: UInt64, restoring: Bool) throws -> [String] {
    let draft = try Draft(text)
    let base = CanvasBoard(doc: doc)
    let (cascading, restored) = try validate(draft, against: base, restoring: restoring)
    var merge = Merge(doc: doc, base: base, draft: draft, restored: restored, random: SplitMix64(state: seed))
    return try merge.run(cascading: cascading)
  }
}

/// Refuses what cannot apply; answers the connectors whose line names a deleted item, which go
/// too, and the ids a restore brings back.
private func validate(
  _ draft: Draft, against base: CanvasBoard, restoring: Bool,
) throws(CanvasSyntaxError) -> (cascading: Set<CanvasID>, restored: Set<CanvasID>) {
  let items = Dictionary(uniqueKeysWithValues: base.items.map { ($0.id, $0) })
  let connectors = Dictionary(uniqueKeysWithValues: base.connectors.map { ($0.id, $0) })
  var lines: [CanvasID: Int] = [:]
  var restored: Set<CanvasID> = []
  func claim(_ id: CanvasID, line: Int) throws(CanvasSyntaxError) {
    if let first = lines[id] { throw CanvasSyntaxError(line: line, problem: .duplicateID(id, firstLine: first)) }
    lines[id] = line
  }
  for item in draft.items {
    guard let id = item.id else { continue }
    try claim(id, line: item.line)
    guard let old = items[id] else {
      guard restoring else { throw CanvasSyntaxError(line: item.line, problem: .unknownID(id)) }
      restored.insert(id)
      continue
    }
    if (old.kind == .section) != (item.kind == .section) { throw CanvasSyntaxError(line: item.line, problem: .kindChange(id)) }
  }
  let kept = Set(draft.items.compactMap(\.id))
  var cascading: Set<CanvasID> = []
  for connector in draft.connectors {
    let old = try connector.id.flatMap { id throws(CanvasSyntaxError) -> CanvasConnector? in
      try claim(id, line: connector.line)
      guard let old = connectors[id] else {
        guard restoring else { throw CanvasSyntaxError(line: connector.line, problem: .unknownID(id)) }
        restored.insert(id)
        return nil
      }
      return old
    }
    for end in [connector.from, connector.to] where !kept.contains(end) {
      guard let old, [old.from, old.to].contains(end) else { throw CanvasSyntaxError(line: connector.line, problem: .missingEndpoint(end)) }
      cascading.insert(old.id)
    }
  }
  return (cascading, restored)
}

private struct Merge {
  let doc: LoroDoc
  let base: CanvasBoard
  let draft: Draft
  let restored: Set<CanvasID>
  var random: SplitMix64
  var editor: CanvasEditor
  /// Each draft item's id, once it has one.
  var ids: [Int: CanvasID] = [:]
  var board: Slots?
  var sections: [CanvasID: Slots] = [:]

  init(doc: LoroDoc, base: CanvasBoard, draft: Draft, restored: Set<CanvasID>, random: SplitMix64) {
    self.doc = doc
    self.base = base
    self.draft = draft
    self.restored = restored
    self.random = random
    self.editor = CanvasEditor(doc)
  }

  mutating func run(cascading: Set<CanvasID>) throws -> [String] {
    let items = self.draft.items
    let sections = items.indices.filter { items[$0].kind == .section }
    let others = items.indices.filter { items[$0].kind != .section }
    let restored = self.restored
    let known = { (index: Int) in items[index].id.map { !restored.contains($0) } ?? false }
    for index in sections where known(index) { try self.update(index) }
    for index in sections where !known(index) { try self.create(index) }
    for index in others where known(index) { try self.update(index) }
    let kept = Set(self.ids.values)
    let deletion = try self.editor.delete(self.base.items.map(\.id).filter { !kept.contains($0) })
    for index in others where !known(index) { try self.create(index) }
    let notes = try self.connect(cascading: cascading, deleted: Set(deletion.connectors))
    let ids = self.ids
    try self.editor.order(others.filter { items[$0].section == nil }.map { ids[$0]! })
    try self.editor.order(sections.map { ids[$0]! })
    for section in sections {
      try self.editor.order(others.filter { items[$0].section == section }.map { ids[$0]! })
    }
    return notes
  }

  private func parent(of item: Draft.Item) -> CanvasID? {
    item.section.map { self.ids[$0]! }
  }

  private mutating func update(_ index: Int) throws {
    let item = self.draft.items[index]
    let id = item.id!
    self.ids[index] = id
    let old = self.base.item(id)!
    let frame = self.base.frame(of: old)
    let parent = self.parent(of: item)
    if old.parent != parent {
      try self.editor.reparent(id, into: parent)
      try self.editor.setPosition(id, x: item.at?.x ?? frame.x, y: item.at?.y ?? frame.y)
    } else if let at = item.at, at.x != Double(shown(frame.x)) || at.y != Double(shown(frame.y)) {
      try self.editor.setPosition(id, x: at.x, y: at.y)
    }
    if let size = item.size, size.w != Double(shown(frame.w)) || size.h != Double(shown(frame.h)) { try self.editor.setSize(id, size) }
    if item.kind != old.kind { try self.editor.setKind(id, item.kind) }
    let color = item.kind.isColored ? item.color ?? old.color ?? item.kind.defaultColor : nil
    if color != old.color { try self.editor.setColor([id], color) }
    if let path = item.path {
      if path != old.path { try self.editor.setPath(id, path) }
    } else if let blocks = item.blocks {
      if blocks != readBack(old.note) { try self.editor.mergeBlocks(id, blocks, over: old) }
    } else if item.text != readBack(old.text) {
      try self.editor.setText(id, item.text)
    }
  }

  private mutating func create(_ index: Int) throws {
    let item = self.draft.items[index]
    let parent = self.parent(of: item)
    let size = item.size ?? item.kind.defaultSize
    let frame = if let at = item.at { CanvasRect(x: at.x, y: at.y, w: size.w, h: size.h) } else { self.place(size, in: parent) }
    let id = item.id ?? self.editor.newID(using: &self.random)
    self.ids[index] = id
    try self.editor.insert(
      item.kind, frame: frame, color: item.color ?? item.kind.defaultColor, text: item.text, blocks: item.blocks, path: item.path, in: parent,
      id: id,
    )
  }

  /// The next free grid slot: in the section below its title, or else below the whole board.
  private mutating func place(_ size: CanvasSize, in section: CanvasID?) -> CanvasRect {
    let board = CanvasBoard(doc: self.doc)
    guard let section else {
      if self.board == nil {
        let frames = board.items.map(board.frame(of:))
        let left = frames.map(\.x).min() ?? 0
        let width = (frames.map { $0.x + $0.w }.max() ?? 0) - left
        self.board = Slots(x: left, y: frames.map { $0.y + $0.h + 40 }.max() ?? 0, width: max(width, 1200))
      }
      return self.board!.take(size)
    }
    if self.sections[section] == nil {
      let frame = board.frame(of: board.item(section)!)
      var slots = Slots(x: frame.x + 20, y: frame.y + 60, width: frame.w - 40)
      slots.taken = board.items.filter { $0.parent == section }.map(board.frame(of:))
      self.sections[section] = slots
    }
    return self.sections[section]!.take(size)
  }

  private mutating func connect(cascading: Set<CanvasID>, deleted: Set<CanvasID>) throws -> [String] {
    let named = Set(self.draft.connectors.compactMap(\.id))
    for old in self.base.connectors where !named.contains(old.id) && !deleted.contains(old.id) {
      try self.editor.deleteConnector(old.id)
    }
    var notes: [String] = []
    for line in self.draft.connectors {
      let style = line.style
      let next = { (connector: inout CanvasConnector) in
        connector.from = line.from
        connector.to = line.to
        connector.fromSide = line.fromSide
        connector.toSide = line.toSide
        connector.style = style
        if Double(shown(connector.offset)) != line.offset { connector.offset = line.offset }
        connector.arrow = line.arrow
        if connector.label.plain != line.label { connector.label = Inline(plain: line.label) }
      }
      guard let id = line.id, !self.restored.contains(id) else {
        let id = line.id ?? self.editor.newID(using: &self.random)
        var connector = CanvasConnector(id: id, from: line.from, to: line.to)
        next(&connector)
        try self.editor.connect(connector, id: id)
        continue
      }
      if cascading.contains(id) {
        let gone = [line.from, line.to].filter { !self.ids.values.contains($0) }.map { "#\($0)" }
        notes.append("connector #\(id) (\(line.from) \(glyph(line.arrow)) \(line.to)) was deleted with \(gone.joined(separator: " and "))")
        continue
      }
      try self.editor.updateConnector(id, next)
    }
    return notes
  }
}

/// Item-sized cells, left to right then down, from a corner and within a width.
private struct Slots {
  let x: Double
  let y: Double
  let width: Double
  var taken: [CanvasRect] = []

  init(x: Double, y: Double, width: Double) {
    self.x = x
    self.y = y
    self.width = width
  }

  mutating func take(_ size: CanvasSize) -> CanvasRect {
    let gap = 20.0
    var y = self.y
    while true {
      var x = self.x
      repeat {
        let cell = CanvasRect(x: x, y: y, w: size.w, h: size.h)
        let margin = CanvasRect(x: x - gap / 2, y: y - gap / 2, w: size.w + gap, h: size.h + gap)
        if !self.taken.contains(where: margin.intersects) {
          self.taken.append(cell)
          return cell
        }
        x += size.w + gap
      } while x + size.w <= self.x + self.width
      y += size.h + gap
    }
  }
}

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var z = self.state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
