import WmdDocument

extension CanvasBoard {
  /// The agent view: top-level items, one `##` block per section, then `# Connectors`.
  /// Deterministic, so an agent's `edit` matches what `read` returned.
  public var text: String {
    var blocks: [String] = []
    let top = self.items.filter { $0.parent == nil && $0.kind != .section }
    if !top.isEmpty { blocks.append(top.map { self.line(of: $0) }.joined(separator: "\n")) }
    for section in self.items where section.kind == .section {
      let children = self.items.filter { $0.parent == section.id }
      blocks.append(([self.heading(of: section)] + children.map { self.line(of: $0) }).joined(separator: "\n"))
    }
    if !self.connectors.isEmpty {
      blocks.append((["# Connectors"] + self.connectors.map(connectorLine)).joined(separator: "\n"))
    }
    return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
  }

  private func line(of item: CanvasItem) -> String {
    let body = switch item.kind {
    case .file: [item.path ?? ""]
    case .sticky: noteLines(item.note)
    default: bodyLines(item.text)
    }
    let head = "- \(item.kind.rawValue) {\(self.attributes(of: item))}"
    return join(head, body)
  }

  private func heading(of section: CanvasItem) -> String {
    var body = bodyLines(section.text)
    let title = body.removeFirst()
    return join("## " + (title.isEmpty ? "" : title + " ") + "{\(self.attributes(of: section))}", [""] + body)
  }

  private func attributes(of item: CanvasItem) -> String {
    let frame = self.frame(of: item)
    var parts = ["#\(item.id)", "@\(shown(frame.x)),\(shown(frame.y))", "\(shown(frame.w))x\(shown(frame.h))"]
    if let color = item.color { parts.append(color.rawValue) }
    return parts.joined(separator: " ")
  }
}

private func connectorLine(_ connector: CanvasConnector) -> String {
  var attributes = ["#\(connector.id)"]
  if connector.style != .straight { attributes.append(connector.style.rawValue) }
  if connector.fromSide != nil || connector.toSide != nil {
    attributes.append((connector.fromSide?.rawValue ?? "auto") + ":" + (connector.toSide?.rawValue ?? "auto"))
  }
  if connector.offset != 0 { attributes.append(String(shown(connector.offset))) }
  let label = connector.label.isEmpty ? "" : " " + quoted(connector.label.plain)
  return "\(connector.from) \(glyph(connector.arrow)) \(connector.to) {\(attributes.joined(separator: " "))}" + label
}

func glyph(_ arrow: ConnectorArrow) -> String {
  switch arrow {
  case .none: "--"
  case .end: "->"
  case .both: "<->"
  }
}

/// Coordinates read as whole points.
func shown(_ value: Double) -> Int {
  Int(value.rounded())
}

/// The head line, then the text's first line after a space and its later lines indented 2.
private func join(_ head: String, _ body: [String]) -> String {
  var out = head
  if let first = body.first, !first.isEmpty { out += " " + first }
  for line in body.dropFirst() { out += "\n" + (line.isEmpty ? "" : "  " + line) }
  return out
}

/// Item text in `.wmd`'s inline markdown, one entry per line; `{` outside code is escaped, since
/// a heading's attributes start at its first bare one.
func bodyLines(_ text: Inline) -> [String] {
  text.markdown(continuation: "\n", escaping: ["{"])
    .split(separator: "\n", omittingEmptySubsequences: false)
    .map { $0.allSatisfy { $0 == " " } ? "" : String($0) }
}

/// A sticky's blocks as `.wmd` markdown. One paragraph stays on the item's line, as plain text
/// always did; anything more starts on the line below.
private func noteLines(_ blocks: [Block]) -> [String] {
  let lines = blocks.markdown.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
  let shown = blocks.filter { if case let .paragraph(text) = $0 { !text.isEmpty } else { true } }
  if shown.count == 1, case .paragraph = shown[0] { return lines }
  return [""] + lines
}

/// The blocks the agent's lines say, `line` being the first one's number.
func blocks(_ lines: [String], line: Int) throws(CanvasSyntaxError) -> [Block] {
  do throws(WmdSyntaxError) { return try [Block](markdown: lines.joined(separator: "\n")) } catch {
    throw CanvasSyntaxError(line: line + error.line - 1, problem: .inline(error.problem))
  }
}

/// What the agent's lines say, `line` being the first one's number.
func inline(_ lines: [String], line: Int) throws(CanvasSyntaxError) -> Inline {
  do throws(WmdSyntaxError) { return try Inline(markdown: lines.joined(separator: "\n"), line: line) } catch {
    throw CanvasSyntaxError(line: error.line, problem: .inline(error.problem))
  }
}

/// The text as the agent view reads it back: what a write of the agent view leaves unchanged.
func readBack(_ text: Inline) -> Inline {
  var lines = bodyLines(text)
  while lines.count > 1, lines.last == "" { lines.removeLast() }
  return (try? inline(lines, line: 1)) ?? text
}

func readBack(_ blocks: [Block]) -> [Block] {
  var lines = noteLines(blocks).map { $0.allSatisfy { $0 == " " || $0 == "\t" } ? "" : $0 }
  while lines.count > 1, lines.last == "" { lines.removeLast() }
  return (try? CanvasDocument.blocks(lines, line: 1)) ?? blocks
}

private func quoted(_ string: String) -> String {
  var out = "\""
  for character in string {
    switch character {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\t": out += "\\t"
    default: out.append(character)
    }
  }
  return out + "\""
}
