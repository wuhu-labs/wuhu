import CanvasDocument
import Loro
import Testing
import WmdDocument

private func board() -> LoroDoc {
  let doc = LoroDoc()
  CanvasSchema.configure(doc)
  return doc
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasRect {
  CanvasRect(x: x, y: y, w: w, h: h)
}

@Suite struct EditorTests {
  @Test func insertedItemsReadBackInTreeOrderWithRelativeFrames() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(40, 60, 160, 160), color: .yellow, text: Inline(plain: "Ship"))
    let section = try editor.insert(.section, frame: rect(600, 0, 900, 700), color: .gray, text: Inline(plain: "Sprint"))
    let inside = try editor.insert(.rect, frame: rect(640, 60, 200, 100), color: .blue, in: section)
    let free = try editor.insert(.text, frame: rect(40, 300, 320, 40), color: .pink)
    doc.commit()

    let read = CanvasBoard(doc: doc)
    #expect(read.items.map(\.id) == [sticky, section, inside, free])
    let child = try #require(read.item(inside))
    #expect(child.parent == section)
    #expect((child.x, child.y) == (40, 60))
    #expect(read.frame(of: child) == rect(640, 60, 200, 100))
    #expect(read.item(free)?.color == nil, "free text has no colour")
    #expect(read.item(sticky)?.blocks == [.paragraph(Inline(plain: "Ship"))] && read.item(sticky)?.text.isEmpty == true)
  }

  @Test func aNewStickyIsBlocksSoConcurrentFirstEditsMergeByCharacter() throws {
    let doc = board()
    try doc.setPeerId(peer: 1)
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(0, 0, 160, 160), color: .yellow, text: Inline(plain: "Ship the page"))
    doc.commit()
    let other = doc.fork()
    try other.setPeerId(peer: 2)
    try CanvasEditor(doc).setBlocks(sticky, [.paragraph(Inline(plain: "Ship the canvas page"))])
    try CanvasEditor(other).setBlocks(sticky, [.paragraph(Inline(plain: "Ship the page today"))])
    doc.commit()
    other.commit()
    _ = try doc.import(bytes: other.export(mode: .snapshot))
    #expect(CanvasBoard(doc: doc).item(sticky)?.note == [.paragraph(Inline(plain: "Ship the canvas page today"))])
  }

  @Test func aNewShapeHasItsTextSoConcurrentFirstWordsBothStay() throws {
    let doc = board()
    try doc.setPeerId(peer: 1)
    var editor = CanvasEditor(doc)
    let shape = try editor.insert(.rect, frame: rect(0, 0, 200, 100), color: .blue)
    doc.commit()
    let other = doc.fork()
    try other.setPeerId(peer: 2)
    try CanvasEditor(doc).setText(shape, Inline(plain: "API"))
    try CanvasEditor(other).setText(shape, Inline(plain: "draft"))
    doc.commit()
    other.commit()
    _ = try doc.import(bytes: other.export(mode: .snapshot))
    let merged = CanvasBoard(doc: doc).item(shape)?.text.plain
    #expect(merged == "APIdraft" || merged == "draftAPI")
  }

  @Test func movingASectionCarriesItsContents() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let section = try editor.insert(.section, frame: rect(0, 0, 400, 400), color: .gray)
    let inside = try editor.insert(.sticky, frame: rect(20, 20, 100, 100), color: .yellow, in: section)
    try editor.move([section, inside], dx: 100, dy: 50)
    doc.commit()
    let read = CanvasBoard(doc: doc)
    #expect(read.frame(of: read.item(inside)!) == rect(120, 70, 100, 100))
    #expect(read.item(inside)!.x == 20, "the child's stored position is untouched")
  }

  @Test func reparentKeepsTheAbsolutePosition() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let section = try editor.insert(.section, frame: rect(300, 300, 400, 400), color: .gray)
    let sticky = try editor.insert(.sticky, frame: rect(350, 360, 100, 100), color: .yellow)
    try editor.reparent(sticky, into: section)
    doc.commit()
    var read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.parent == section)
    #expect(read.frame(of: read.item(sticky)!) == rect(350, 360, 100, 100))
    #expect(throws: CanvasEditError.nestedSection(section)) { try CanvasEditor(doc).reparent(section, into: section) }

    try CanvasEditor(doc).reparent(sticky, into: nil)
    doc.commit()
    read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.parent == nil)
    #expect(read.frame(of: read.item(sticky)!) == rect(350, 360, 100, 100))
  }

  @Test func deleteCascadesToContentsAndConnectors() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let section = try editor.insert(.section, frame: rect(0, 0, 400, 400), color: .gray)
    let inside = try editor.insert(.sticky, frame: rect(20, 20, 100, 100), color: .yellow, in: section)
    let outside = try editor.insert(.rect, frame: rect(600, 0, 100, 100), color: .blue)
    let other = try editor.insert(.rect, frame: rect(900, 0, 100, 100), color: .blue)
    let doomed = try editor.connect(from: inside, to: outside)
    let kept = try editor.connect(from: outside, to: other, style: .elbow)
    let deletion = try editor.delete([section])
    doc.commit()
    #expect(deletion.items == [section, inside].sorted())
    #expect(deletion.connectors == [doomed])
    let read = CanvasBoard(doc: doc)
    #expect(read.items.map(\.id) == [outside, other])
    #expect(read.connectors.map(\.id) == [kept])
  }

  @Test func duplicateCopiesSectionsContentsAndInnerConnectors() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let section = try editor.insert(.section, frame: rect(0, 0, 400, 400), color: .gray, text: Inline(plain: "S"))
    let a = try editor.insert(.sticky, frame: rect(20, 20, 100, 100), color: .yellow, in: section)
    let b = try editor.insert(.sticky, frame: rect(200, 20, 100, 100), color: .pink, in: section)
    try editor.connect(from: a, to: b, label: Inline(plain: "next"))
    let copies = try editor.duplicate([section], dx: 500, dy: 0)
    doc.commit()
    let read = CanvasBoard(doc: doc)
    #expect(Set(copies.keys) == [section, a, b])
    let copyOfB = try #require(read.item(copies[b]!))
    #expect(copyOfB.parent == copies[section])
    #expect(read.frame(of: copyOfB) == rect(700, 20, 100, 100))
    #expect(copyOfB.color == .pink)
    #expect(read.connectors.count == 2)
    #expect(read.connectors.contains { $0.from == copies[a] && $0.to == copies[b] && $0.label == Inline(plain: "next") })

    let again = try editor.duplicate([section, a], dx: 0, dy: 500)
    doc.commit()
    #expect(Set(again.keys) == [section, a, b], "a selected child comes along with its selected section, once")
    #expect(CanvasBoard(doc: doc).items.filter { $0.parent == again[section] }.count == 2)
  }

  @Test func connectorsUpdateFieldByField() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let a = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow)
    let b = try editor.insert(.sticky, frame: rect(300, 0, 100, 100), color: .yellow)
    let connector = try editor.connect(from: a, to: b)
    try editor.updateConnector(connector) {
      $0.style = .elbow
      $0.offset = -20.5
      $0.toSide = .left
      $0.arrow = .both
    }
    doc.commit()
    let read = try #require(CanvasBoard(doc: doc).connectors.first)
    #expect(read == CanvasConnector(id: connector, from: a, to: b, toSide: .left, style: .elbow, offset: -20.5, arrow: .both))
    try editor.deleteConnector(connector)
    doc.commit()
    #expect(CanvasBoard(doc: doc).connectors.isEmpty)
  }

  @Test func textAndColorAndPathEdits() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow)
    let file = try editor.insert(.file, frame: rect(200, 0, 240, 160), color: nil, path: "/a.png")
    let bold = Inline([InlineRun(text: "Ship "), InlineRun(text: "v1", marks: .text(bold: true))])
    try editor.setText(sticky, bold)
    try editor.setColor([sticky], .green)
    try editor.setPath(file, "/designs/hero.png")
    try editor.setKind(sticky, .rect)
    doc.commit()
    let read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.text == bold)
    #expect(read.item(sticky)?.color == .green)
    #expect(read.item(sticky)?.kind == .rect)
    #expect(read.item(file)?.path == "/designs/hero.png")
  }

  @Test func setBlocksUpgradesAStickyAndItsCopiesAndLeavingStickyDropsThem() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow, text: Inline(plain: "Ship"))
    let blocks: [Block] = [.heading(level: 1, text: Inline(plain: "Ship")), .list(level: 0, style: .done, text: Inline(plain: "v1"))]
    try editor.setBlocks(sticky, blocks)
    let copy = try #require(try editor.duplicate([sticky], dx: 20, dy: 20)[sticky])
    doc.commit()
    var read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.blocks == blocks && read.item(sticky)?.text.isEmpty == true)
    #expect(read.item(copy)?.blocks == blocks)

    try CanvasEditor(doc).setKind(sticky, .rect)
    try CanvasEditor(doc).setKind(sticky, .sticky)
    doc.commit()
    read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.blocks == nil && read.item(sticky)?.note == [])
  }

  @Test func setBlocksWritesExactlyWhatTheEditorShowsABlankLineIncluded() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow)
    let (one, two) = (Block.paragraph(Inline(plain: "one")), Block.paragraph(Inline(plain: "two")))
    try editor.setBlocks(sticky, [one, .paragraph(Inline()), .paragraph(Inline()), two])
    doc.commit()
    #expect(CanvasBoard(doc: doc).item(sticky)?.blocks == [one, .paragraph(Inline()), .paragraph(Inline()), two])
    try editor.setBlocks(sticky, [one, .paragraph(Inline()), two])
    doc.commit()
    #expect(CanvasBoard(doc: doc).item(sticky)?.blocks == [one, .paragraph(Inline()), two])
  }

  @Test func outOfSchemaNodesAreSkipped() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let section = try editor.insert(.section, frame: rect(0, 0, 400, 400), color: .gray)
    let sticky = try editor.insert(.sticky, frame: rect(500, 0, 100, 100), color: .yellow)
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    let stray = try tree.create(parent: .root)
    try tree.getMeta(target: stray).insert(key: CanvasSchema.Key.kind, v: "hologram")
    let nodes = tree.children(parent: .root)!
    let nested = try tree.create(parent: .node(id: nodes[0]))
    let meta = try tree.getMeta(target: nested)
    for (key, value) in [("id", "zzzzzz"), ("kind", "section")] { try meta.insert(key: key, v: value) }
    for key in ["x", "y", "w", "h"] { try meta.insert(key: key, v: 1.0) }
    doc.commit()
    #expect(CanvasBoard(doc: doc).items.map(\.id) == [section, sticky])
  }

  @Test func aColourOutOfSchemaReadsAsNoneAndFreeTextHasNone() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let sticky = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow)
    let text = try editor.insert(.text, frame: rect(200, 0, 100, 40), color: nil)
    let tree = doc.getTree(id: CanvasSchema.Key.tree)
    let nodes = try #require(tree.children(parent: .root))
    try tree.getMeta(target: nodes[0]).insert(key: CanvasSchema.Key.color, v: "teal")
    try tree.getMeta(target: nodes[1]).insert(key: CanvasSchema.Key.color, v: "pink")
    doc.commit()
    let read = CanvasBoard(doc: doc)
    #expect(read.item(sticky)?.color == nil && read.item(text)?.color == nil)
  }

  @Test func outOfSchemaConnectorFieldsReadAsTheirDefaults() throws {
    let doc = board()
    var editor = CanvasEditor(doc)
    let a = try editor.insert(.sticky, frame: rect(0, 0, 100, 100), color: .yellow)
    let b = try editor.insert(.sticky, frame: rect(300, 0, 100, 100), color: .yellow)
    let connector = try editor.connect(from: a, to: b)
    let map = try #require(doc.getMap(id: CanvasSchema.Key.connectors).get(key: connector.rawValue)?.asLoroMap())
    for (key, value) in [("fromSide", "middle"), ("style", "curved"), ("offset", "1"), ("arrow", "x"), ("label", "plain")] {
      try map.insert(key: key, v: value)
    }
    doc.commit()
    #expect(CanvasBoard(doc: doc).connectors == [CanvasConnector(id: connector, from: a, to: b)])
  }

  @Test func idsAreSixBase36Characters() {
    #expect(CanvasID(rawValue: "a1k9z0") != nil)
    #expect(CanvasID(rawValue: "A1K9Z0") == nil)
    #expect(CanvasID(rawValue: "a1k9z") == nil)
    let taken: Set<CanvasID> = [CanvasID(rawValue: "000000")!]
    #expect(!taken.contains(CanvasID.random(avoiding: taken)))
  }
}
