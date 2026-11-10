#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CanvasDocument
import LiveDocument
import Loro
import Testing
import WmdDocument

extension LiveReplica {
  /// Merges like the node does: the update first, then its import.
  @discardableResult
  func write(_ text: String, base: Data? = nil, peer: UInt64) throws -> LiveMerge? {
    guard let merge = try merge(text: text, base: base, peer: peer) else { return nil }
    try importUpdate(merge.update)
    return merge
  }

  /// A client caught up with this replica, as the live channel's handshake leaves it.
  func client() throws -> LiveReplica {
    let client = LiveReplica(.canvas)
    try client.importUpdate(#require(try self.updates(since: client.versionVector)))
    return client
  }
}

/// The board a person drew with the editor, as a replica.
private func drawn(_ draw: (inout CanvasEditor) throws -> Void) throws -> LiveReplica {
  let doc = LoroDoc()
  CanvasSchema.configure(doc)
  var editor = CanvasEditor(doc)
  try draw(&editor)
  doc.commit()
  return try LiveReplica(.canvas, snapshot: doc.export(mode: .snapshot), updates: [])
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
  CanvasRect(x: x, y: y, w: w, h: h)
}

/// The text with each id replaced by its order of appearance, for asserting on new boards.
private func shape(_ text: String) -> String {
  var names: [Substring: String] = [:]
  var out = ""
  var rest = text[...]
  while let match = rest.firstMatch(of: /#[0-9a-z]{6}/) {
    out += rest[..<match.range.lowerBound]
    let raw = match.output.dropFirst()
    if names[raw] == nil { names[raw] = "id\(names.count)" }
    out += "#" + names[raw]!
    rest = rest[match.range.upperBound...]
  }
  return out + rest
}

private func ids(_ text: String) -> [String] {
  text.matches(of: /#([0-9a-z]{6})/).map { String($0.output.1) }
}

@Suite struct TextTests {
  static let example = """
  - sticky {@40,60} Ship canvas **v1**
  - text {@40,300 320x40} Free text, line one
    continuation line two

  ## Sprint {@600,0 900x700}
  - rect {@640,60 blue} API draft
  - file {@640,300} /designs/hero.png

  """

  @Test func aWrittenBoardReadsBackCanonicalAndRewritesAsNothing() throws {
    let live = LiveReplica(.canvas)
    try live.write(Self.example, peer: 1)
    #expect(shape(live.text) == """
    - sticky {#id0 @40,60 160x160 yellow} Ship canvas **v1**
    - text {#id1 @40,300 320x40} Free text, line one
      continuation line two

    ## Sprint {#id2 @600,0 900x700 gray}
    - rect {#id3 @640,60 200x100 blue} API draft
    - file {#id4 @640,300 240x160} /designs/hero.png

    """)
    #expect(try live.merge(text: live.text, base: nil, peer: 2) == nil)
  }

  @Test func codeKeepsItsBracesUnescapedAndOutOfTheAttributes() throws {
    let live = LiveReplica(.canvas)
    try live.write("## `{x}` and \\{y} {@0,0 400x300}\n- rect {@40,60} run `f{}` [a](u\\{)\n", peer: 40)
    #expect(live.text.hasPrefix("## `{x}` and \\{y} {#"))
    #expect(live.text.contains("blue} run `f{}` [a](u\\{)\n"))
    let board = CanvasBoard(doc: try drawnDoc(live))
    #expect(board.items.first { $0.kind == .section }?.text == Inline([InlineRun(text: "{x}", marks: .code), InlineRun(text: " and {y}")]))
    #expect(try live.merge(text: live.text, base: nil, peer: 41) == nil)
  }

  @Test func aStickyHoldsBlocksAsMarkdownUnderItsLine() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} ## Launch\n  - [ ] Draft the API\n  - [x] Book the room\n", peer: 42)
    let id = try #require(ids(live.text).first)
    let canonical = """
    - sticky {#\(id) @0,0 160x160 yellow}
      ## Launch

      - [ ] Draft the API
      - [x] Book the room

    """
    #expect(live.text == canonical)
    #expect(try live.merge(text: live.text, base: nil, peer: 43) == nil)
    let item = try #require(CanvasBoard(doc: try drawnDoc(live)).item(CanvasID(rawValue: id)!))
    #expect(item.blocks == [
      .heading(level: 2, text: Inline(plain: "Launch")),
      .list(level: 0, style: .todo, text: Inline(plain: "Draft the API")),
      .list(level: 0, style: .done, text: Inline(plain: "Book the room")),
    ])
    #expect(item.text.isEmpty)

    let client = try live.client()
    let before = client.versionVector
    try live.write(canonical.replacing("- [ ] Draft", with: "- [x] Draft"), peer: 44)
    try client.importUpdate(#require(try live.updates(since: before)))
    #expect(client.text == canonical.replacing("- [ ] Draft", with: "- [x] Draft"))
  }

  @Test func aCodeBlockWithABlankLookingLineSurvivesAnUnrelatedWrite() throws {
    var id = CanvasID(rawValue: "aaaaaa")!
    let live = try drawn { editor in
      id = try editor.insert(.sticky, frame: rect(0, 0, 160, 160), color: .yellow)
      try editor.setBlocks(id, [.code("let a = 1\n    \nlet b = 2")])
    }
    let before = try #require(CanvasBoard(doc: try drawnDoc(live)).item(id)).blocks
    try live.write(live.text + "- rect {@300,0} unrelated\n", peer: 47)
    #expect(CanvasBoard(doc: try drawnDoc(live)).item(id)?.blocks == before)
  }

  @Test func aStickyStoredAsTextReadsAsParagraphsAndUpgradesOnlyWhenEdited() throws {
    var old = CanvasID(rawValue: "aaaaaa")!
    let live = try drawn { editor in
      old = try editor.insert(.rect, frame: rect(0, 0, 160, 160), color: .yellow, text: Inline(plain: "one\ntwo\n\nthree"))
      try editor.setKind(old, .sticky)
    }
    let canonical = "- sticky {#\(old) @0,0 160x160 yellow}\n  one\n  two\n\n  three\n"
    #expect(live.text == canonical)
    try live.write(canonical + "- sticky {@300,0} new\n", peer: 45)
    var item = try #require(CanvasBoard(doc: try drawnDoc(live)).item(old))
    #expect(item.blocks == nil && item.text.plain == "one\ntwo\n\nthree", "an untouched sticky stays as it was stored")
    #expect(item.note == [.paragraph(Inline(plain: "one\ntwo")), .paragraph(Inline()), .paragraph(Inline(plain: "three"))])

    try live.write(live.text.replacing("  three", with: "  - [ ] three"), peer: 46)
    item = try #require(CanvasBoard(doc: try drawnDoc(live)).item(old))
    #expect(item.text.isEmpty)
    #expect(item.blocks == [.paragraph(Inline(plain: "one\ntwo")), .paragraph(Inline()), .list(level: 0, style: .todo, text: Inline(plain: "three"))])
  }

  @Test func aBlankLineInAStickyIsHiddenFromTheAgentViewAndSurvivesItsWrites() throws {
    var id = CanvasID(rawValue: "aaaaaa")!
    var short = CanvasID(rawValue: "bbbbbb")!
    let todo = { (text: String) in Block.list(level: 0, style: .todo, text: Inline(plain: text)) }
    let live = try drawn { editor in
      id = try editor.insert(.sticky, frame: rect(0, 0, 160, 160), color: .yellow)
      try editor.setBlocks(id, [todo("one"), .paragraph(Inline()), todo("two")])
      short = try editor.insert(.sticky, frame: rect(200, 0, 160, 160), color: .yellow)
      try editor.setBlocks(short, [.paragraph(Inline(plain: "Ship it")), .paragraph(Inline())])
    }
    #expect(live.text.contains("yellow} Ship it\n"), "a paragraph and a blank line read as the one paragraph")
    try live.write(live.text + "- rect {@400,0} unrelated\n", peer: 48)
    try live.write(live.text.replacing("- [ ] two", with: "- [x] two"), peer: 49)
    let board = CanvasBoard(doc: try drawnDoc(live))
    #expect(board.item(id)?.blocks == [todo("one"), .paragraph(Inline()), .list(level: 0, style: .done, text: Inline(plain: "two"))])
    #expect(board.item(short)?.blocks == [.paragraph(Inline(plain: "Ship it")), .paragraph(Inline())])
  }

  @Test func connectorsJoinItemsTheBoardAlreadyHas() throws {
    let live = LiveReplica(.canvas)
    try live.write(Self.example, peer: 3)
    let named = ids(live.text)
    let text = live.text + "\n# Connectors\n\(named[0]) -> \(named[3]) {elbow right:left -40} \"depends on\"\n\(named[3]) -- \(named[4])\n"
    try live.write(text, peer: 4)
    let connectors = live.text.split(separator: "# Connectors\n")[1]
    #expect(shape(String(connectors)).split(separator: "\n").count == 2)
    #expect(connectors.contains("\(named[0]) -> \(named[3]) {#"))
    #expect(connectors.contains("elbow right:left -40} \"depends on\""))
    #expect(CanvasBoard(doc: try drawnDoc(live)).connectors.map(\.offset).sorted() == [-40, 0])
    #expect(try live.merge(text: live.text, base: nil, peer: 5) == nil)
  }

  @Test func editsByIdChangeOnlyWhatTheLineChanged() throws {
    var sticky = CanvasID(rawValue: "aaaaaa")!
    var other = sticky
    let live = try drawn { editor in
      sticky = try editor.insert(.sticky, frame: rect(40.4, 60, 160, 160), color: .yellow, text: Inline(plain: "Ship"))
      other = try editor.insert(.rect, frame: rect(400, 60, 200, 100), color: .blue, text: Inline(plain: "Keep"))
    }
    let read = live.frontiers
    let text = live.text
    #expect(text.contains("- sticky {#\(sticky) @40,60 160x160 yellow} Ship\n"))
    let edited = text.replacing("@40,60 160x160 yellow} Ship", with: "@40,60 200x160 pink} Ship *it*")
    try live.write(edited, base: read, peer: 6)
    let board = CanvasBoard(doc: try drawnDoc(live))
    let item = try #require(board.item(sticky))
    #expect(item.x == 40.4, "an unchanged position keeps its fraction")
    #expect((item.w, item.color) == (200, .pink))
    #expect(item.note == [.paragraph(Inline([InlineRun(text: "Ship "), InlineRun(text: "it", marks: .text(italic: true))]))])
    #expect(item.text.isEmpty, "the first edit upgrades the sticky to blocks")
    #expect(board.item(other)?.text.plain == "Keep")
  }

  @Test func aMissingLineDeletesTheItemAndItsConnectorsWithANote() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} a\n- sticky {@300,0} b\n- sticky {@600,0} c\n", peer: 7)
    let named = ids(live.text)
    try live.write(live.text + "\n# Connectors\n\(named[0]) -> \(named[1])\n\(named[1]) -> \(named[2])\n", peer: 8)
    let lines = live.text.split(separator: "\n", omittingEmptySubsequences: false)
    let withoutB = lines.filter { !$0.hasPrefix("- sticky {#\(named[1])") }.joined(separator: "\n")
    let merge = try #require(try live.write(withoutB, peer: 9))
    #expect(merge.notes.count == 2)
    #expect(merge.notes.allSatisfy { $0.contains("was deleted with #\(named[1])") })
    #expect(!live.text.contains("# Connectors"))
    #expect(!live.text.contains(named[1]))
  }

  @Test func aFileCardWrittenAsAStickyKeepsItsIdAndConnectorsAndDropsItsPath() throws {
    let live = LiveReplica(.canvas)
    try live.write("- file {@0,0} /designs/hero.png\n- sticky {@300,0} b\n", peer: 30)
    let named = ids(live.text)
    try live.write(live.text + "\n# Connectors\n\(named[0]) -> \(named[1])\n", peer: 31)
    let client = try live.client()
    let before = client.versionVector

    try live.write(live.text.replacing("- file {#\(named[0])", with: "- sticky {#\(named[0])").replacing("/designs/hero.png", with: "Hero"), peer: 32)
    try client.importUpdate(#require(try live.updates(since: before)))
    let board = CanvasBoard(doc: try drawnDoc(client))
    let card = try #require(board.item(CanvasID(rawValue: named[0])!))
    #expect(card.kind == .sticky && card.path == nil && card.note == [.paragraph(Inline(plain: "Hero"))])
    #expect(board.connectors.count == 1)
    let doc = try drawnDoc(client)
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    let metas = try tree.nodes().map { try tree.getMeta(target: $0) }
    #expect(metas.allSatisfy { $0.get(key: CanvasSchema.Key.path) == nil }, "no stray path is left behind")
  }

  @Test func aStrayPathOnANonFileItemIsIgnored() throws {
    let doc = LoroDoc()
    CanvasSchema.configure(doc)
    var editor = CanvasEditor(doc)
    let id = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow, text: Inline(plain: "Hi"))
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    let node = try #require(tree.nodes().first)
    try tree.getMeta(target: node).insert(key: CanvasSchema.Key.path, v: "/a.png")
    doc.commit()
    let item = try #require(CanvasBoard(doc: doc).item(id))
    #expect(item.kind == .sticky && item.path == nil)
  }

  @Test func aLineUnderAnotherHeadingMovesIntoThatSectionWhereItStands() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@700,100} a\n\n## Left {@0,0 400x400}\n\n## Right {@600,0 400x400}\n", peer: 10)
    let named = ids(live.text)
    let moved = "## Left {#\(named[1]) @0,0 400x400 gray}\n\n## Right {#\(named[2]) @600,0 400x400 gray}\n- sticky {#\(named[0]) @700,100 160x160 yellow} a\n"
    try live.write(moved, peer: 11)
    #expect(live.text == moved)
    let draggedSection = moved.replacing("@600,0 400x400", with: "@800,0 400x400")
    try live.write(draggedSection, peer: 12)
    #expect(live.text.contains("- sticky {#\(named[0]) @900,100 160x160 yellow} a"), "an unchanged child rides with its section")
  }

  @Test func newItemsWithoutAPositionTakeFreeSlots() throws {
    let live = LiveReplica(.canvas)
    try live.write("## S {@0,0 600x400}\n- sticky\n- sticky\n- sticky\n- sticky\n", peer: 13)
    let board = CanvasBoard(doc: try drawnDoc(live))
    let frames = board.items.filter { $0.kind == .sticky }.map(board.frame(of:))
    #expect(frames.map(\.x) == [20, 200, 380, 20])
    #expect(frames.map(\.y) == [60, 60, 60, 240])
    try live.write(live.text + "- rect\n", peer: 14)
    #expect(live.text.contains("## S {"))
    let below = CanvasBoard(doc: try drawnDoc(live)).items.first { $0.kind == .rect && $0.parent == nil }
    #expect(below == nil, "a line under the heading stays in the section")
  }

  @Test func lineOrderIsPaintOrder() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} a\n- sticky {@0,0} b\n- sticky {@0,0} c\n", peer: 15)
    let lines = live.text.split(separator: "\n")
    let reordered = [lines[2], lines[0], lines[1]].joined(separator: "\n") + "\n"
    try live.write(reordered, peer: 16)
    #expect(live.text == reordered)
  }

  @Test func anAgentEditMergesWithAConcurrentDrag() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} plan\n", peer: 17)
    let read = live.frontiers
    let agentText = try live.text(at: read)
    let human = try live.client()
    let dragged = try #require(try human.write(agentText.replacing("@0,0", with: "@300,200"), peer: 18))
    try live.importUpdate(dragged.update)
    let agent = try #require(try live.write(agentText.replacing("plan", with: "plan **v2**"), base: read, peer: 19))
    #expect(live.text.contains("@300,200 160x160 yellow} plan **v2**"))
    try human.importUpdate(agent.update)
    #expect(human.text == live.text)
  }

  @Test(arguments: [
    ("- sticky {#zzzzzz} a\n", 1, "#zzzzzz is not on this board"),
    ("- sticky a\n\n# Connectors\nzzzzzz -> yyyyyy\n", 4, "names zzzzzz"),
    ("## A\n### B\n", 2, "sections are one level deep"),
    ("- section {@0,0} x\n", 1, "a section is a ## heading"),
    ("- blob x\n", 1, "unknown kind blob"),
    ("- sticky {@1,2 @3,4} a\n", 1, "repeats"),
    ("  stray\n", 1, "continues the text"),
    ("- text {pink} a\n", 1, "free text has no colour"),
    ("# Connectors\n- sticky a\n", 2, "come before # Connectors"),
    ("- sticky\n  ## Plan\n\n  > quoted\n", 4, "block quotes are not supported"),
  ])
  func refusedTextNamesTheLine(text: String, line: Int, reason: String) throws {
    let live = LiveReplica(.canvas)
    do {
      try live.write(text, peer: 20)
      Issue.record("accepted \(text)")
    } catch let LiveError.syntax(error) {
      #expect(error.line == line)
      #expect(error.reason.contains(reason), "\(error.reason)")
    }
    #expect(live.text == "")
  }

  @Test func restoringAnOlderTextBringsBackItsIds() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} a\n- sticky {@300,0} b\n", peer: 24)
    let older = live.text
    let named = ids(older)
    try live.write(older + "\n# Connectors\n\(named[0]) -> \(named[1])\n", peer: 25)
    try live.write("", peer: 26)
    #expect(live.text == "")
    #expect(throws: LiveError.self) { try live.merge(text: older, base: nil, peer: 27) }
    let restored = try #require(try live.merge(text: older, base: nil, peer: 28, restoring: true))
    try live.importUpdate(restored.update)
    #expect(live.text == older)
  }

  @Test func duplicateIDsAndKindChangesAreRefused() throws {
    let live = LiveReplica(.canvas)
    try live.write("- sticky {@0,0} a\n\n## S {@400,0}\n", peer: 21)
    let named = ids(live.text)
    #expect(throws: LiveError.syntax(LiveSyntaxError(line: 2, reason: "#\(named[0]) is already used on line 1"))) {
      try live.write("- sticky {#\(named[0])} a\n- sticky {#\(named[0])} b\n", peer: 22)
    }
    #expect(throws: LiveError.syntax(LiveSyntaxError(line: 1, reason: "#\(named[1]) cannot turn into or out of a section; delete it and write a new one"))) {
      try live.write("- sticky {#\(named[1])} a\n", peer: 23)
    }
  }
}

/// The replica's board, through its snapshot.
private func drawnDoc(_ live: LiveReplica) throws -> LoroDoc {
  let doc = LoroDoc()
  CanvasSchema.configure(doc)
  _ = try doc.import(bytes: live.snapshot())
  return doc
}
