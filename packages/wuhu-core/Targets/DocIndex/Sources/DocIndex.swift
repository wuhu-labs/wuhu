import Dispatch
import Foundation
import Markdown
import struct SpaceFS.FSResolver
import struct SpaceFS.SpacePath
import SwiftSoup
import Synchronization
import Yams

public enum DocIndex {
  public static func parse(markdown: String, at path: SpacePath) -> DocMeta {
    onLargeStack { parseMarkdown(markdown, at: path) }
  }

  public static func parse(html: String, at path: SpacePath) -> DocMeta {
    onLargeStack { parseHTML(html, at: path) }
  }
}

private func parseMarkdown(_ markdown: String, at path: SpacePath) -> DocMeta {
  let (yaml, body) = splitFrontmatter(markdown)
  let frontmatter = parseFrontmatter(yaml)
  let (destinations, embeddedHTML) = collectMarkdownLinks(body)

  var links: [LinkTarget] = []
  for destination in destinations {
    if let resolved = resolveLink(destination, doc: path) { links.append(resolved) }
  }
  links.append(contentsOf: htmlLinks(in: embeddedHTML, doc: path))

  return DocMeta(
    title: path.lastComponent ?? "",
    kind: frontmatter.kind,
    status: frontmatter.status,
    customAttrs: frontmatter.attrs,
    links: local(links),
    groupLinks: grouped(links),
  )
}

private func parseHTML(_ html: String, at path: SpacePath) -> DocMeta {
  let title = path.lastComponent ?? ""
  guard let document = try? SwiftSoup.parse(html) else {
    return DocMeta(title: title, kind: nil, status: nil, customAttrs: [], links: [])
  }

  var kind: String?
  var status: String?
  var customAttrs: [DocMeta.Attr] = []
  for meta in (try? document.select("meta").array()) ?? [] {
    let rawName = (try? meta.attr("name")) ?? ""
    let content = (try? meta.attr("content")) ?? ""
    if rawName == "wuhu:kind" {
      if kind == nil { kind = content }
    } else if rawName == "wuhu:status" {
      if status == nil { status = content }
    } else if rawName.hasPrefix(customMetaPrefix) {
      let name = String(rawName.dropFirst(customMetaPrefix.count))
      if !name.isEmpty {
        customAttrs.append(DocMeta.Attr(name: name, value: .scalar(jsonQuote(content))))
      }
    }
  }

  let links = links(in: document, doc: path)
  return DocMeta(
    title: title,
    kind: kind,
    status: status,
    customAttrs: customAttrs,
    links: local(links),
    groupLinks: grouped(links),
  )
}

private let customMetaPrefix = "wuhu-custom:"

// swift-markdown and Yams recurse once per nesting level; a pathologically deep
// document overruns the caller's stack before our own depth caps ever run, so the
// whole parse executes on a dedicated thread with room the default stack lacks.
// swift-corelibs-foundation clamps a Thread stack at 1 GiB, so that is the ceiling.
private let parseStackSize = 1 << 30

// Cap for our own tree walks; beyond this a document degrades to fewer induced
// rows rather than recursing without bound.
private let maxWalkDepth = 128

// Block-quote nesting is the only unbounded block axis in CommonMark (cmark caps
// list nesting), and swift-markdown's converter recurses once per level — deep
// enough to overrun even the 1 GiB ceiling. A document past this depth is degraded
// to no markdown links rather than handed to swift-markdown at all.
private let maxBlockquoteNesting = 50000

private func onLargeStack(_ work: @escaping @Sendable () -> DocMeta) -> DocMeta {
  let result = Mutex<DocMeta?>(nil)
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    let value = work()
    result.withLock { $0 = value }
    done.signal()
  }
  thread.stackSize = parseStackSize
  thread.start()
  done.wait()
  return result.withLock { $0! }
}

// MARK: - Frontmatter

private func splitFrontmatter(_ content: String) -> (yaml: String?, body: String) {
  let stripped = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
  let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
  guard let first = lines.first, first == "---" else { return (nil, content) }

  var closeIndex: Int?
  var index = 1
  while index < lines.count {
    if lines[index] == "---" || lines[index] == "..." {
      closeIndex = index
      break
    }
    index += 1
  }
  guard let close = closeIndex else { return (nil, content) }

  let yaml = lines[1 ..< close].joined(separator: "\n")
  let body = lines[(close + 1)...].joined(separator: "\n")
  return (yaml, body)
}

private func parseFrontmatter(_ yaml: String?) -> (kind: String?, status: String?, attrs: [DocMeta.Attr]) {
  guard let yaml, !yaml.isEmpty else { return (nil, nil, []) }
  let root: Yams.Node?
  do {
    root = try Yams.compose(yaml: yaml)
  } catch {
    return (nil, nil, [])
  }
  guard let mapping = root?.mapping else { return (nil, nil, []) }

  var byKey: [String: Yams.Node] = [:]
  for (keyNode, valueNode) in mapping {
    guard let key = keyNode.scalar?.string else { continue }
    byKey[key] = valueNode
  }

  var attrs: [DocMeta.Attr] = []
  for key in byKey.keys.sorted() where key != "kind" && key != "status" {
    if let value = attrValue(byKey[key]!, depth: 0) {
      attrs.append(DocMeta.Attr(name: key, value: value))
    }
  }
  return (byKey["kind"].flatMap(stringScalar), byKey["status"].flatMap(stringScalar), attrs)
}

private func stringScalar(_ node: Yams.Node) -> String? {
  guard node.scalar != nil else { return nil }
  return node.any as? String
}

// MARK: - EAV value rendering

private func attrValue(_ node: Yams.Node, depth: Int) -> DocMeta.AttrValue? {
  if let scalar = canonicalScalar(node) { return .scalar(scalar) }
  if let sequence = node.sequence {
    if sequence.isEmpty { return nil }
    return .array(sequence.map { canonicalScalar($0) ?? canonicalJSON($0, depth: depth + 1) })
  }
  return .jsonObject(canonicalJSON(node, depth: depth))
}

private func canonicalScalar(_ node: Yams.Node) -> String? {
  guard let scalar = node.scalar else { return nil }
  // Construct only this leaf via Yams (safe: the trapping force-unwrap is in
  // mapping construction, which we walk ourselves). Non-finite floats and the
  // timestamp/binary types keep the author's scalar text so payloads stay JSON.
  switch node.any {
  case is NSNull: return "null"
  case let bool as Bool: return bool ? "true" : "false"
  case let value as Int: return String(value)
  case let value as Int64: return String(value)
  case let value as UInt64: return String(value)
  case let value as Double: return value.isFinite ? canonicalNumber(value) : jsonQuote(scalar.string)
  case let value as String: return jsonQuote(value)
  default: return jsonQuote(scalar.string)
  }
}

private func canonicalJSON(_ node: Yams.Node, depth: Int) -> String {
  if depth > maxWalkDepth { return "null" }
  if let scalar = canonicalScalar(node) { return scalar }
  if let sequence = node.sequence {
    return "[" + sequence.map { canonicalJSON($0, depth: depth + 1) }.joined(separator: ",") + "]"
  }
  if let mapping = node.mapping {
    var byKey: [String: Yams.Node] = [:]
    for (keyNode, valueNode) in mapping {
      guard let key = keyNode.scalar?.string else { continue }
      byKey[key] = valueNode
    }
    let pairs = byKey.keys.sorted().map { jsonQuote($0) + ":" + canonicalJSON(byKey[$0]!, depth: depth + 1) }
    return "{" + pairs.joined(separator: ",") + "}"
  }
  return "null"
}

private func canonicalNumber(_ value: Double) -> String {
  if value == value.rounded(), let integer = Int64(exactly: value) {
    return String(integer)
  }
  return String(value)
}

private func jsonQuote(_ string: String) -> String {
  var out = "\""
  for scalar in string.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    default:
      if scalar.value < 0x20 {
        out += "\\u" + hex4(scalar.value)
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
  }
  return out + "\""
}

private func hex4(_ value: UInt32) -> String {
  let digits = Array("0123456789abcdef")
  var result = ""
  for shift in stride(from: 12, through: 0, by: -4) {
    result.append(digits[Int((value >> UInt32(shift)) & 0xF)])
  }
  return result
}

// MARK: - Links

private func collectMarkdownLinks(_ body: String) -> (destinations: [String], embeddedHTML: String) {
  if blockquoteNestingExceedsLimit(body) { return ([], "") }
  var result: (destinations: [String], embeddedHTML: String) = ([], "")
  for child in Markdown.Document(parsing: body).children {
    collect(child, into: &result, depth: 0)
  }
  return result
}

// The maximum count of leading '>' markers on any line is exactly the document's
// block-quote nesting depth: depth only rises when a line presents that many
// markers. So this O(n) scan soundly bounds what swift-markdown would build.
private func blockquoteNestingExceedsLimit(_ body: String) -> Bool {
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    var depth = 0
    var spaces = 0
    for character in line {
      if character == ">" {
        depth += 1
        if depth > maxBlockquoteNesting { return true }
        spaces = 0
      } else if character == " " || character == "\t" {
        spaces += 1
        if spaces > 3 { break }
      } else {
        break
      }
    }
  }
  return false
}

private func collect(_ markup: Markup, into result: inout (destinations: [String], embeddedHTML: String), depth: Int) {
  if depth > maxWalkDepth { return }
  if let link = markup as? Markdown.Link {
    if let destination = link.destination, !destination.isEmpty { result.destinations.append(destination) }
  } else if let image = markup as? Markdown.Image {
    if let source = image.source, !source.isEmpty { result.destinations.append(source) }
  } else if let inlineHTML = markup as? Markdown.InlineHTML {
    result.embeddedHTML += inlineHTML.rawHTML + "\n"
  } else if let htmlBlock = markup as? Markdown.HTMLBlock {
    result.embeddedHTML += htmlBlock.rawHTML + "\n"
  }
  for child in markup.children {
    collect(child, into: &result, depth: depth + 1)
  }
}

private func htmlLinks(in html: String, doc: SpacePath) -> [LinkTarget] {
  guard !html.isEmpty, let document = try? SwiftSoup.parse(html) else { return [] }
  return links(in: document, doc: doc)
}

private func links(in document: SwiftSoup.Document, doc: SpacePath) -> [LinkTarget] {
  guard let elements = try? document.getAllElements().array() else { return [] }
  var result: [LinkTarget] = []
  for element in elements {
    // A <base> carries the document base URI, not a link target of its own.
    if element.tagNameNormal() == "base" { continue }
    let href = (try? element.attr("href")) ?? ""
    if !href.isEmpty, let resolved = resolveLink(href, doc: doc) { result.append(resolved) }
    let src = (try? element.attr("src")) ?? ""
    if !src.isEmpty, let resolved = resolveLink(src, doc: doc) { result.append(resolved) }
  }
  return result
}

private enum LinkTarget: Hashable {
  case local(SpacePath)
  case group(DocMeta.GroupLink)
}

// `wuhu:/x` is the document's own group; `wuhu://<group>.localspace/x` names one.
private func resolveLink(_ raw: String, doc: SpacePath) -> LinkTarget? {
  var reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if reference.isEmpty || reference.hasPrefix("#") { return nil }
  if let fragment = reference.firstIndex(of: "#") { reference = String(reference[..<fragment]) }
  if let query = reference.firstIndex(of: "?") { reference = String(reference[..<query]) }
  if reference.hasPrefix("wuhu://") {
    let rest = reference.dropFirst("wuhu://".count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    guard let group = try? FSResolver.group(ofHost: rest[..<slash]),
          let decoded = String(rest[slash...]).removingPercentEncoding,
          let path = doc.resolving(decoded) else { return nil }
    return .group(DocMeta.GroupLink(group: group, path: path))
  }
  if reference.hasPrefix("wuhu:/") {
    guard let decoded = String(reference.dropFirst("wuhu:".count)).removingPercentEncoding,
          let path = doc.resolving(decoded) else { return nil }
    return .local(path)
  }
  if reference.isEmpty || hasScheme(reference) { return nil }
  guard let decoded = reference.removingPercentEncoding, let path = doc.parent.resolving(decoded) else { return nil }
  return .local(path)
}

private func hasScheme(_ reference: String) -> Bool {
  guard let colon = reference.firstIndex(of: ":") else { return false }
  if let slash = reference.firstIndex(of: "/"), slash < colon { return false }
  let scheme = reference[..<colon]
  guard let first = scheme.first, first.isLetter else { return false }
  return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
}

private func local(_ links: [LinkTarget]) -> [SpacePath] {
  orderedUnique(links.compactMap { if case let .local(path) = $0 { path } else { nil } })
}

private func grouped(_ links: [LinkTarget]) -> [DocMeta.GroupLink] {
  orderedUnique(links.compactMap { if case let .group(link) = $0 { link } else { nil } })
}

private func orderedUnique<T: Hashable>(_ items: [T]) -> [T] {
  var seen: Set<T> = []
  var result: [T] = []
  for item in items where seen.insert(item).inserted {
    result.append(item)
  }
  return result
}
