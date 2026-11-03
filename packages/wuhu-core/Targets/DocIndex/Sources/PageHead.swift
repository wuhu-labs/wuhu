#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum SpaceContract.PageLayout

/// What an HTML page declares in its head, read where stat answers so a shell
/// lays the page out and names it right on its first frame: the layout of
/// `<meta name="wuhu-layout" content="immersive">` (anything else, or nothing,
/// is the default framed layout) and the `<title>`.
public struct PageHead: Equatable, Sendable {
  public var layout: PageLayout?
  public var title: String?

  /// How much of a page's start is searched; a head declares itself early.
  public static let scanBytes = 16 * 1024

  public static func isHTML(_ path: String) -> Bool {
    let lower = path.lowercased()
    return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
  }

  /// The head is what comes before `<body`, with comments, scripts and
  /// styles (an unclosed one runs to the end) taken out first.
  public static func parse(_ data: Data) -> PageHead {
    var html = String(decoding: data, as: UTF8.self)
    html.replace(/(?is)<!--.*?(?:-->|\z)/, with: "")
    html.replace(/(?is)<(script|style)\b.*?(?:<\/\1\s*>|\z)/, with: "")
    if let body = html.firstMatch(of: /(?i)<body\b/) { html = String(html[..<body.range.lowerBound]) }
    var head = PageHead(layout: nil, title: nil)
    for tag in html.matches(of: /(?i)<meta\b[^>]*>/) {
      let text = String(tag.output)
      guard attribute("name", in: text)?.lowercased() == "wuhu-layout" else { continue }
      head.layout = attribute("content", in: text).flatMap { PageLayout(rawValue: $0.lowercased()) }
      break
    }
    if let title = html.firstMatch(of: /(?is)<title\b[^>]*>(.*?)<\/title\s*>/) {
      let text = decoded(String(title.output.1)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
      head.title = text.isEmpty ? nil : text
    }
    return head
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    for match in tag.matches(of: /([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/)
      where match.output.1.lowercased() == name
    {
      let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
      return String(value.filter { !$0.isWhitespace })
    }
    return nil
  }

  private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

  private static func decoded(_ text: String) -> String {
    text.replacing(/&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);/) { match in
      let name = String(match.output.1)
      if name.hasPrefix("#") {
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? String(match.output.0)
      }
      return entities[name] ?? String(match.output.0)
    }
  }
}
