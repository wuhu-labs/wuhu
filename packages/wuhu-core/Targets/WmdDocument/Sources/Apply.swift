import JSONValue
import Loro

/// Makes `doc` say `target`, touching only what the agent changed. The diff runs over what the
/// agent read: each block as its own markdown reads back, so a block that renders to nothing (an
/// empty paragraph) is never touched and one whose text does not round-trip still matches. Inside
/// a gap between kept blocks, blocks of one family and similar text are updated in place; the rest
/// are deleted and inserted, so concurrent typing never lands in another block's container.
func apply(_ target: Content, to doc: LoroDoc) throws {
  let (current, placed) = project(doc)
  let frontmatter = doc.getMap(id: Key.frontmatter)
  for (key, value) in target.frontmatter where current.frontmatter[key] != value {
    try frontmatter.insert(key: key, v: loro(value))
  }
  for key in current.frontmatter.keys where target.frontmatter[key] == nil {
    try frontmatter.delete(key: key)
  }
  let visible = placed.compactMap(Visible.init)
  let plan = Plan(base: visible, target: target.blocks)
  let list = doc.getMovableList(id: Key.blocks)
  for (base, next) in plan.updates {
    try write(target.blocks[next], into: list.get(index: visible[base].position)!.asLoroMap()!)
  }
  for edit in plan.edits.sorted(by: >) {
    switch edit.kind {
    case .delete: try list.delete(pos: edit.position, len: 1)
    case let .insert(next): try write(target.blocks[next], into: list.insertMapContainer(pos: edit.position, child: LoroMap()))
    }
  }
}

/// A block the agent view shows, with the blocks its own markdown reads back as.
private struct Visible {
  let position: UInt32
  let block: Block
  let reads: [Block]

  init?(_ placed: Placed) {
    var numbering = Numbering()
    guard let markdown = placed.block.markdown(numbering: &numbering),
          let reads = try? Content(markdown: markdown).blocks, !reads.isEmpty else { return nil }
    self.position = placed.position
    self.block = placed.block
    self.reads = reads
  }
}

private struct Plan {
  var updates: [(base: Int, next: Int)] = []
  var edits: [Edit] = []

  /// Positions are the list's before any edit, so the edits apply from the end.
  struct Edit: Comparable {
    enum Kind { case delete, insert(next: Int) }
    let position: UInt32
    let kind: Kind

    /// At one position a delete goes first, then inserts in reverse target order.
    private var order: Int {
      switch self.kind {
      case .delete: Int.max
      case let .insert(next): next
      }
    }

    static func < (lhs: Edit, rhs: Edit) -> Bool { (lhs.position, lhs.order) < (rhs.position, rhs.order) }
    static func == (lhs: Edit, rhs: Edit) -> Bool { lhs.position == rhs.position && lhs.order == rhs.order }
  }

  init(base: [Visible], target: [Block]) {
    var previous: UInt32?
    var baseStart = 0
    var targetStart = 0
    for anchor in kept(base, target) + [(base: base.count, target: target.count, length: 0)] {
      let gapBase = Array(baseStart ..< anchor.base)
      let gapTarget = Array(targetStart ..< anchor.target)
      var b = 0
      var t = 0
      for pair in paired(gapBase.map { base[$0].block }, gapTarget.map { target[$0] }) + [(gapBase.count, gapTarget.count)] {
        while b < pair.0 {
          self.edits.append(Edit(position: base[gapBase[b]].position, kind: .delete))
          previous = base[gapBase[b]].position
          b += 1
        }
        while t < pair.1 {
          self.edits.append(Edit(position: previous.map { $0 + 1 } ?? 0, kind: .insert(next: gapTarget[t])))
          t += 1
        }
        guard b < gapBase.count else { break }
        self.updates.append((gapBase[b], gapTarget[t]))
        previous = base[gapBase[b]].position
        b += 1
        t += 1
      }
      if anchor.base < base.count { previous = base[anchor.base].position }
      baseStart = anchor.base + 1
      targetStart = anchor.target + anchor.length
    }
  }
}

/// The longest run of base blocks whose markdown the target holds unchanged, in order, weighted
/// by the target blocks each covers.
private func kept(_ base: [Visible], _ target: [Block]) -> [(base: Int, target: Int, length: Int)] {
  let n = base.count
  let m = target.count
  func matches(_ i: Int, _ j: Int) -> Bool {
    let reads = base[i].reads
    return j + reads.count <= m && target[j ..< j + reads.count].elementsEqual(reads)
  }
  var best = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
  for i in stride(from: n - 1, through: 0, by: -1) {
    for j in stride(from: m, through: 0, by: -1) {
      var value = best[i + 1][j]
      if j < m { value = max(value, best[i][j + 1]) }
      if matches(i, j) { value = max(value, base[i].reads.count + best[i + 1][j + base[i].reads.count]) }
      best[i][j] = value
    }
  }
  var result: [(base: Int, target: Int, length: Int)] = []
  var i = 0
  var j = 0
  while i < n {
    let length = base[i].reads.count
    if matches(i, j), best[i][j] == length + best[i + 1][j + length] {
      result.append((i, j, length))
      i += 1
      j += length
    } else if best[i][j] == best[i + 1][j] {
      i += 1
    } else {
      j += 1
    }
  }
  return result
}

/// The order-preserving pairing of a gap's blocks with the most total similarity, among pairs of
/// one family at least half similar.
private func paired(_ base: [Block], _ target: [Block]) -> [(Int, Int)] {
  let n = base.count
  let m = target.count
  guard n > 0, m > 0 else { return [] }
  let similarity = base.map { lhs in target.map { rhs in lhs.family == rhs.family ? dice(lhs.searchText, rhs.searchText) : 0 } }
  var best = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
  for i in stride(from: n - 1, through: 0, by: -1) {
    for j in stride(from: m - 1, through: 0, by: -1) {
      var value = max(best[i + 1][j], best[i][j + 1])
      if similarity[i][j] >= 0.5 { value = max(value, similarity[i][j] + best[i + 1][j + 1]) }
      best[i][j] = value
    }
  }
  var result: [(Int, Int)] = []
  var i = 0
  var j = 0
  while i < n, j < m {
    if similarity[i][j] >= 0.5, best[i][j] == similarity[i][j] + best[i + 1][j + 1] {
      result.append((i, j))
      i += 1
      j += 1
    } else if best[i][j] == best[i + 1][j] {
      i += 1
    } else {
      j += 1
    }
  }
  return result
}

/// The Dice coefficient of two texts' character bigrams, the ends marked so short texts compare.
private func dice(_ lhs: String, _ rhs: String) -> Double {
  func bigrams(_ text: String) -> [String: Int] {
    let characters = [Character("\u{2}")] + Array(text) + [Character("\u{3}")]
    var counts: [String: Int] = [:]
    for index in 1 ..< characters.count { counts[String(characters[index - 1]) + String(characters[index]), default: 0] += 1 }
    return counts
  }
  let (left, right) = (bigrams(lhs), bigrams(rhs))
  let shared = left.reduce(0) { $0 + min($1.value, right[$1.key] ?? 0) }
  return 2 * Double(shared) / Double(left.values.reduce(0, +) + right.values.reduce(0, +))
}

extension Block {
  /// Blocks of one family turn into each other in place: a heading's level, a list item's style.
  fileprivate var family: Int {
    switch self {
    case .heading: 0
    case .paragraph: 1
    case .list: 2
    case .code: 3
    case .view: 4
    }
  }

  fileprivate var searchText: String {
    switch self {
    case let .heading(_, text), let .paragraph(text), let .list(_, _, text): text.plain
    case let .code(code): code
    case let .view(view, config, sql): view + "\n" + config.jsonString(sortedKeys: true) + "\n" + sql
    }
  }
}

private func write(_ block: Block, into map: LoroMap) throws {
  if map.get(key: Key.kind)?.asValue() != .string(value: block.kind) { try map.insert(key: Key.kind, v: block.kind) }
  if case let .list(level, style, _) = block {
    if map.get(key: Key.level)?.asValue() != .i64(value: Int64(level)) { try map.insert(key: Key.level, v: Int64(level)) }
    if map.get(key: Key.style)?.asValue() != .string(value: style.rawValue) { try map.insert(key: Key.style, v: style.rawValue) }
  } else {
    if map.get(key: Key.level) != nil { try map.delete(key: Key.level) }
    if map.get(key: Key.style) != nil { try map.delete(key: Key.style) }
  }
  switch block {
  case let .view(view, config, sql):
    if map.get(key: Key.view)?.asValue() != .string(value: view) { try map.insert(key: Key.view, v: view) }
    if map.get(key: Key.config)?.asValue().map(json) != config { try map.insert(key: Key.config, v: loro(config)) }
    if map.get(key: Key.sql)?.asValue() != .string(value: sql) { try map.insert(key: Key.sql, v: sql) }
  case let .code(code):
    try sync(map.getOrCreateTextContainer(key: Key.text, child: LoroText()), to: Inline(plain: code))
  case let .heading(_, text), let .paragraph(text), let .list(_, _, text):
    try sync(map.getOrCreateTextContainer(key: Key.text, child: LoroText()), to: text)
  }
}

private typealias Attributes = [String: LoroValue]

private func sync(_ text: LoroText, to inline: Inline) throws {
  let plain = inline.plain
  if text.toString() != plain { try text.update(s: plain, options: UpdateOptions(timeoutMs: nil, useRefinedDiff: true)) }
  let desired: [Attributes] = inline.runs.flatMap { run in Array(repeating: attributes(run.marks), count: run.text.utf16.count) }
  let actual: [Attributes] = text.toDelta().flatMap { delta -> [Attributes] in
    guard case let .insert(string, attributes) = delta else { return [] }
    let present = (attributes ?? [:]).filter { $0.value != .null && $0.value != .bool(value: false) }
    return Array(repeating: present, count: string.utf16.count)
  }
  precondition(desired.count == actual.count, "a synced text has the target's length")
  for key in [Key.bold, Key.italic, Key.link] {
    var start = 0
    while start < desired.count {
      let value = desired[start][key]
      guard actual[start][key] != value else {
        start += 1
        continue
      }
      var end = start + 1
      while end < desired.count, desired[end][key] == value, actual[end][key] != value { end += 1 }
      if let value {
        try text.markUtf16(from: UInt32(start), to: UInt32(end), key: key, value: value)
      } else {
        try text.unmarkUtf16(from: UInt32(start), to: UInt32(end), key: key)
      }
      start = end
    }
  }
}

private func attributes(_ marks: Marks) -> Attributes {
  var result: Attributes = [:]
  if marks.bold { result[Key.bold] = .bool(value: true) }
  if marks.italic { result[Key.italic] = .bool(value: true) }
  if let link = marks.link { result[Key.link] = .string(value: link) }
  return result
}
