#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CanvasDocument
import Loro
import Testing
import WmdDocument

// Fixtures/editor-cases.json is shared with the web editor (packages/wuhu-web lib/canvas/editor-fixture.test.ts):
// both editors run the same operations and must read back the same board.

private struct Run: Codable, Equatable, Sendable {
  var text: String
  var bold: Bool?
  var italic: Bool?
  var link: String?
}

private struct Change: Decodable, Sendable {
  var from: String?
  var to: String?
  var fromSide: Clearable<CanvasSide>
  var toSide: Clearable<CanvasSide>
  var style: String?
  var offset: Double?
  var arrow: String?
  var label: [Run]?

  enum CodingKeys: String, CodingKey { case from, to, fromSide, toSide, style, offset, arrow, label }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.from = try c.decodeIfPresent(String.self, forKey: .from)
    self.to = try c.decodeIfPresent(String.self, forKey: .to)
    self.fromSide = try Clearable(c, .fromSide)
    self.toSide = try Clearable(c, .toSide)
    self.style = try c.decodeIfPresent(String.self, forKey: .style)
    self.offset = try c.decodeIfPresent(Double.self, forKey: .offset)
    self.arrow = try c.decodeIfPresent(String.self, forKey: .arrow)
    self.label = try c.decodeIfPresent([Run].self, forKey: .label)
  }
}

/// Absent keeps the field, `null` clears it.
private enum Clearable<Value: RawRepresentable<String> & Sendable>: Sendable {
  case keep
  case set(Value?)

  init<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) throws {
    guard container.contains(key) else {
      self = .keep
      return
    }
    self = try .set(container.decodeNil(forKey: key) ? nil : Value(rawValue: container.decode(String.self, forKey: key))!)
  }
}

private struct Operation: Decodable, Sendable {
  var op: String
  var `as`: Named?
  var kind: String?
  var frame: [Double]?
  var color: String?
  var text: [Run]?
  var path: String?
  var `in`: String?
  var id: String?
  var ids: [String]?
  var into: String?
  var dx: Double?
  var dy: Double?
  var from: String?
  var to: String?
  var fromSide: String?
  var toSide: String?
  var style: String?
  var arrow: String?
  var label: [Run]?
  var set: Change?
  var deleted: Deleted?
  var `throws`: String?
  var noop: Bool?
}

private enum Named: Decodable, Sendable {
  case one(String)
  case many([String: String])

  init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let name = try? c.decode(String.self) { self = .one(name) } else { self = try .many(c.decode([String: String].self)) }
  }
}

private struct Deleted: Decodable, Equatable, Sendable {
  var items: [String]
  var connectors: [String]
}

private struct ExpectedItem: Codable, Equatable, Sendable {
  var id: String
  var kind: String
  var parent: String?
  var x, y, w, h: Double
  var color: String?
  var text: [Run]?
  var path: String?
}

private struct ExpectedConnector: Codable, Equatable, Sendable {
  var id: String
  var from: String
  var to: String
  var fromSide: String?
  var toSide: String?
  var style: String
  var offset: Double
  var arrow: String
  var label: [Run]?
}

private struct Expected: Codable, Equatable, Sendable {
  var items: [ExpectedItem]
  var connectors: [ExpectedConnector]
}

private struct Case: Decodable, Sendable, CustomTestStringConvertible {
  var name: String
  var ops: [Operation]
  var expected: Expected

  var testDescription: String { self.name }

  static let all: [Case] = {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/editor-cases.json")
    return try! JSONDecoder().decode([Case].self, from: Data(contentsOf: file))
  }()
}

private func inline(_ runs: [Run]?) -> Inline {
  Inline((runs ?? []).map { InlineRun(text: $0.text, marks: InlineMarks(bold: $0.bold ?? false, italic: $0.italic ?? false, link: $0.link)) })
}

private func runs(_ inline: Inline) -> [Run]? {
  inline.isEmpty ? nil : inline.runs.map { Run(text: $0.text, bold: $0.marks.bold ? true : nil, italic: $0.marks.italic ? true : nil, link: $0.marks.link) }
}

private struct Runner {
  let doc: LoroDoc
  var names: [String: CanvasID] = [:]

  func id(_ name: String) -> CanvasID {
    self.names[name] ?? CanvasID(rawValue: name)!
  }

  func name(_ id: CanvasID) -> String {
    self.names.first { $0.value == id }?.key ?? "new"
  }

  mutating func run(_ op: Operation) throws {
    var editor = CanvasEditor(self.doc)
    let frame = op.frame.map { CanvasRect(x: $0[0], y: $0[1], w: $0[2], h: $0[3]) }
    switch op.op {
    case "insert":
      let id = try editor.insert(
        CanvasKind(rawValue: op.kind!)!, frame: frame!, color: op.color.flatMap(CanvasColor.init(rawValue:)), text: inline(op.text), path: op.path,
        in: op.`in`.map(self.id),
      )
      if case let .one(name) = op.`as` { self.names[name] = id }
    case "setFrame": try editor.setFrame(self.id(op.id!), frame!)
    case "move": try editor.move(op.ids!.map(self.id), dx: op.dx!, dy: op.dy!)
    case "reparent": try editor.reparent(self.id(op.id!), into: op.into.map(self.id))
    case "bringToFront": try editor.bringToFront(self.id(op.id!))
    case "delete":
      let deletion = try editor.delete(op.ids!.map(self.id))
      let named = Deleted(items: deletion.items.map(self.name).sorted(), connectors: deletion.connectors.map(self.name).sorted())
      #expect(named == op.deleted.map { Deleted(items: $0.items.sorted(), connectors: $0.connectors.sorted()) })
    case "duplicate":
      let copies = try editor.duplicate(op.ids!.map(self.id), dx: op.dx!, dy: op.dy!)
      if case let .many(names) = op.`as` {
        for (original, name) in names { self.names[name] = copies[self.id(original)] }
      }
    case "setColor": try editor.setColor(op.ids!.map(self.id), op.color.flatMap(CanvasColor.init(rawValue:)))
    case "setKind": try editor.setKind(self.id(op.id!), CanvasKind(rawValue: op.kind!)!)
    case "setText": try editor.setText(self.id(op.id!), inline(op.text))
    case "setPath": try editor.setPath(self.id(op.id!), op.path!)
    case "connect":
      let id = try editor.connect(
        from: self.id(op.from!), to: self.id(op.to!), fromSide: op.fromSide.flatMap(CanvasSide.init(rawValue:)),
        toSide: op.toSide.flatMap(CanvasSide.init(rawValue:)), style: op.style.flatMap(ConnectorStyle.init(rawValue:)) ?? .straight,
        arrow: op.arrow.flatMap(ConnectorArrow.init(rawValue:)) ?? .end, label: inline(op.label),
      )
      if case let .one(name) = op.`as` { self.names[name] = id }
    case "updateConnector":
      let change = op.set!
      let names = self.names
      let resolve = { (name: String) in names[name] ?? CanvasID(rawValue: name)! }
      try editor.updateConnector(self.id(op.id!)) { connector in
        if let from = change.from { connector.from = resolve(from) }
        if let to = change.to { connector.to = resolve(to) }
        if case let .set(side) = change.fromSide { connector.fromSide = side }
        if case let .set(side) = change.toSide { connector.toSide = side }
        if let style = change.style { connector.style = ConnectorStyle(rawValue: style)! }
        if let offset = change.offset { connector.offset = offset }
        if let arrow = change.arrow { connector.arrow = ConnectorArrow(rawValue: arrow)! }
        if let label = change.label { connector.label = inline(label) }
      }
    case "deleteConnector": try editor.deleteConnector(self.id(op.id!))
    default: Issue.record("unknown op \(op.op)")
    }
  }

  var board: Expected {
    let board = CanvasBoard(doc: self.doc)
    return Expected(
      items: board.items.map { item in
        ExpectedItem(
          id: self.name(item.id), kind: item.kind.rawValue, parent: item.parent.map(self.name), x: item.x, y: item.y, w: item.w, h: item.h,
          color: item.color?.rawValue, text: runs(item.text), path: item.path,
        )
      },
      connectors: board.connectors.map { connector in
        ExpectedConnector(
          id: self.name(connector.id), from: self.name(connector.from), to: self.name(connector.to), fromSide: connector.fromSide?.rawValue,
          toSide: connector.toSide?.rawValue, style: connector.style.rawValue, offset: connector.offset, arrow: connector.arrow.rawValue,
          label: runs(connector.label),
        )
      }.sorted { ($0.id, $0.from, $0.to) < ($1.id, $1.from, $1.to) },
    )
  }
}

private func errorName(_ error: any Error) -> String? {
  switch error as? CanvasEditError {
  case .unknown?: "unknown"
  case .notASection?: "notASection"
  case .nestedSection?: "nestedSection"
  case nil: nil
  }
}

@Suite struct EditorFixtureTests {
  @Test(arguments: Case.all) fileprivate func editorCase(_ fixture: Case) throws {
    let doc = LoroDoc()
    CanvasSchema.configure(doc)
    var runner = Runner(doc: doc)
    for (index, op) in fixture.ops.enumerated() {
      let before = doc.oplogVv().encode()
      do {
        try runner.run(op)
        #expect(op.`throws` == nil, "op \(index) (\(op.op)) should throw \(op.`throws` ?? "")")
      } catch {
        #expect(errorName(error) == op.`throws`, "op \(index) (\(op.op)) threw \(error)")
      }
      doc.commit()
      if op.noop == true || op.`throws` != nil {
        #expect(doc.oplogVv().encode() == before, "op \(index) (\(op.op)) should write nothing")
      }
    }
    #expect(runner.board == fixture.expected)
    let read = CanvasBoard(doc: doc)
    for id in read.items.map(\.id) + read.connectors.map(\.id) {
      #expect(id.rawValue.utf8.count == 6 && id.rawValue.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x61 ... 0x7A).contains($0) }, "bad id \(id.rawValue)")
    }
  }
}
