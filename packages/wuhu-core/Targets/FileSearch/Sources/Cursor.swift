#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Where a page stopped: the entry the next page visits first, relative to the
/// root ("" when the root is that entry), and for grep the byte offset and
/// number of the line to read first. A cursor is opaque and bound to its
/// query (mode, pattern, root, scope, hidden, noIgnore; not limit), so a step
/// from another search, another scope or a hand-made one is refused rather
/// than misread.
struct SearchCursor: Hashable, Sendable {
  static let version = "s2."

  var path: String
  var offset = 0
  var line = 1

  func encoded(for query: SearchQuery) -> String {
    Self.version + base64URL(Data("\(Self.digest(query))\n\(offset)\n\(line)\n\(path)".utf8))
  }

  init(path: String, offset: Int = 0, line: Int = 1) {
    self.path = path
    self.offset = offset
    self.line = line
  }

  init(_ step: String, for query: SearchQuery) throws(SearchError) {
    let invalid = SearchError(.invalidStep, "invalid step: pass back a cursor this search returned, with the same pattern, path and options")
    guard step.hasPrefix(Self.version), let data = base64URLDecoded(String(step.dropFirst(Self.version.count))) else { throw invalid }
    let parts = String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0] == Self.digest(query), let offset = Int(parts[1]), offset >= 0, let line = Int(parts[2]), line >= 1
    else { throw invalid }
    self.init(path: String(parts[3]), offset: offset, line: line)
  }

  // FNV-1a: binds a cursor to its query; not a secret.
  static func digest(_ query: SearchQuery) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for field in [query.mode.rawValue, query.pattern, query.root, query.scope, String(query.hidden), String(query.noIgnore)] {
      for byte in field.utf8 + [0] {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
      }
    }
    return String(hash, radix: 16)
  }
}

private func base64URL(_ data: Data) -> String {
  String(data.base64EncodedString().compactMap { character -> Character? in
    switch character {
    case "+": "-"
    case "/": "_"
    case "=": nil
    default: character
    }
  })
}

private func base64URLDecoded(_ text: String) -> Data? {
  guard text.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) })
  else { return nil }
  let base64 = String(text.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 }) + String(repeating: "=", count: (4 - text.utf8.count % 4) % 4)
  return Data(base64Encoded: base64)
}
