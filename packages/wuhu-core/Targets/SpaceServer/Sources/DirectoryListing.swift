#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct SpaceFS.Entry

func directoryListing(path: String, entries: [Entry]) -> Data {
  let ordered = entries.sorted {
    (($0.kind == .directory ? 0 : 1), $0.name) < (($1.kind == .directory ? 0 : 1), $1.name)
  }
  var rows = ""
  if path != "/" {
    rows += row(href: encodedPath(parent(of: path)), glyph: parentGlyph, name: "..")
  }
  for entry in ordered {
    let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
    rows += row(href: encodedPath(child), glyph: glyph(for: entry.kind), name: entry.name)
  }
  if ordered.isEmpty {
    rows += "<p class=\"listing-empty\">Empty directory</p>\n"
  }
  return Data(page(path: path, rows: rows).utf8)
}

private func page(path: String, rows: String) -> String {
  """
  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>\(escaped(path))</title>
  <link rel="stylesheet" href="/theme.css">
  <style>
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; margin: 0; }
    body.wuhu-listing {
      --_paper: light-dark(#f6f7f2, #0c0e11);
      --_fg: light-dark(#101318, #edf0f2);
      --_fg-muted: light-dark(#61686f, #949ba1);
      --_hover: light-dark(rgba(16, 21, 28, 0.05), rgba(236, 240, 244, 0.05));
      --_border: light-dark(rgba(16, 21, 28, 0.08), rgba(236, 240, 244, 0.08));
      background: var(--bg, var(--_paper));
      color: var(--fg, var(--_fg));
      font-family: var(--font-text, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif);
      font-size: var(--font-size, 1rem);
      min-height: 100dvh;
      padding: 1rem;
    }
    body.wuhu-listing ::selection { background: var(--selection, rgba(89, 201, 165, 0.3)); }
    .listing-eyebrow {
      color: var(--fg-muted, var(--_fg-muted));
      font-size: 0.68rem;
      font-weight: 600;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }
    .listing-path {
      padding-bottom: 0.6rem;
      border-bottom: 1px solid var(--border, var(--_border));
      margin-bottom: 0.4rem;
      font-family: var(--font-mono, ui-monospace, "SF Mono", Menlo, monospace);
      font-size: 0.95rem;
      font-weight: 500;
      overflow-wrap: anywhere;
    }
    .listing-rows { display: flex; flex-direction: column; }
    .listing-row {
      display: flex;
      height: 34px;
      align-items: center;
      padding: 0 0.5rem;
      border-radius: var(--radius, 9px);
      color: inherit;
      font-size: 0.88rem;
      gap: 0.5rem;
      text-decoration: none;
    }
    .listing-row:hover { background: var(--code-bg, var(--_hover)); }
    .listing-glyph {
      width: 16px;
      height: 16px;
      flex: none;
      color: var(--fg-muted, var(--_fg-muted));
      fill: none;
      stroke: currentColor;
      stroke-linecap: round;
      stroke-linejoin: round;
      stroke-width: 1.7;
    }
    .listing-name { overflow-wrap: anywhere; }
    .listing-empty {
      padding: 0.5rem;
      color: var(--fg-muted, var(--_fg-muted));
      font-size: 0.82rem;
    }
  </style>
  </head>
  <body class="wuhu-content wuhu-listing">
  <p class="listing-eyebrow">Directory</p>
  <h1 class="listing-path">\(escaped(path))</h1>
  <nav class="listing-rows">
  \(rows)</nav>
  </body>
  </html>

  """
}

private func row(href: String, glyph: String, name: String) -> String {
  """
  <a class="listing-row" href="\(escaped(href))"><svg class="listing-glyph" viewBox="0 0 24 24" aria-hidden="true">\(glyph)</svg><span class="listing-name">\(escaped(name))</span></a>

  """
}

private let parentGlyph = #"<path d="m6 14 6-6 6 6"/>"#

private func glyph(for kind: Entry.Kind) -> String {
  switch kind {
  case .directory: #"<path d="M4 7h6l2 2h8v10H4z"/>"#
  case .table: #"<rect x="4" y="5" width="16" height="14" rx="2"/><path d="M4 10h16M10 10v9"/>"#
  case .file, .symlink: #"<path d="M6 3h9l4 4v14H6zM15 3v5h4M9 12h7M9 16h5"/>"#
  }
}

private func parent(of path: String) -> String {
  guard let end = path.lastIndex(of: "/"), end != path.startIndex else { return "/" }
  return String(path[path.startIndex ..< end])
}

func escaped(_ text: String) -> String {
  var out = ""
  out.reserveCapacity(text.count)
  for character in text {
    switch character {
    case "&": out += "&amp;"
    case "<": out += "&lt;"
    case ">": out += "&gt;"
    case "\"": out += "&quot;"
    default: out.append(character)
    }
  }
  return out
}

private func encodedPath(_ path: String) -> String {
  "/" + path.split(separator: "/", omittingEmptySubsequences: true).map(encodedSegment).joined(separator: "/")
}

private func encodedSegment(_ segment: Substring) -> String {
  var out = ""
  for byte in segment.utf8 {
    if byte.isUnreservedURL {
      out.unicodeScalars.append(UnicodeScalar(byte))
    } else {
      out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
    }
  }
  return out
}

extension UInt8 {
  fileprivate var isUnreservedURL: Bool {
    switch self {
    case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
         UInt8(ascii: "0") ... UInt8(ascii: "9"):
      true
    case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
      true
    default:
      false
    }
  }
}

extension String {
  fileprivate func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: "0", count: width - count) + self
  }
}
