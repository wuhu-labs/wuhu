#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

enum S3ListParser {
  static func parse(_ data: Data) throws -> ObjectListing {
    let bytes = Array(data)
    let whole = 0 ..< bytes.count

    var entries: [ObjectListEntry] = []
    var cursor = 0
    while let block = self.nextBlock(bytes, tag: "Contents", from: cursor) {
      guard let keyBytes = self.firstElement(bytes, tag: "Key", in: block.content) else {
        throw ObjectStoreError.malformedResponse("<Contents> element without <Key>")
      }
      let key = try ObjectKey(self.unescape(self.decode(keyBytes)))
      let size = self.firstElement(bytes, tag: "Size", in: block.content)
        .flatMap { Int64(self.decode($0).trimmedASCIIWhitespace()) } ?? 0
      entries.append(ObjectListEntry(key: key, size: size))
      cursor = block.end
    }

    let truncated = self.firstElement(bytes, tag: "IsTruncated", in: whole)
      .map { self.decode($0).trimmedASCIIWhitespace() } == "true"
    let token = self.firstElement(bytes, tag: "NextContinuationToken", in: whole)
      .map { self.unescape(self.decode($0)) }

    return ObjectListing(entries: entries, continuationToken: truncated ? token : nil)
  }

  private static func firstElement(
    _ bytes: [UInt8],
    tag: String,
    in range: Range<Int>,
  ) -> ArraySlice<UInt8>? {
    let open = Array("<\(tag)>".utf8)
    let close = Array("</\(tag)>".utf8)
    guard let start = self.indexOf(bytes, open, from: range.lowerBound), start < range.upperBound else {
      return nil
    }
    let contentStart = start + open.count
    guard let end = self.indexOf(bytes, close, from: contentStart), end <= range.upperBound else {
      return nil
    }
    return bytes[contentStart ..< end]
  }

  private static func nextBlock(
    _ bytes: [UInt8],
    tag: String,
    from: Int,
  ) -> (content: Range<Int>, end: Int)? {
    let open = Array("<\(tag)>".utf8)
    let close = Array("</\(tag)>".utf8)
    guard let start = self.indexOf(bytes, open, from: from) else { return nil }
    let contentStart = start + open.count
    guard let end = self.indexOf(bytes, close, from: contentStart) else { return nil }
    return (contentStart ..< end, end + close.count)
  }

  private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
    guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
    let last = haystack.count - needle.count
    guard from <= last else { return nil }
    for start in from ... last {
      var matched = true
      for offset in 0 ..< needle.count where haystack[start + offset] != needle[offset] {
        matched = false
        break
      }
      if matched { return start }
    }
    return nil
  }

  private static func decode(_ slice: ArraySlice<UInt8>) -> String {
    String(decoding: slice, as: UTF8.self)
  }

  private static func unescape(_ string: String) -> String {
    guard string.contains("&" as Character) else { return string }
    var out = ""
    var iterator = string.unicodeScalars.makeIterator()
    var pending: Unicode.Scalar? = iterator.next()
    while let scalar = pending {
      guard scalar == "&" else {
        out.unicodeScalars.append(scalar)
        pending = iterator.next()
        continue
      }
      var entity = ""
      var next = iterator.next()
      while let character = next, character != ";", entity.count < 12 {
        entity.unicodeScalars.append(character)
        next = iterator.next()
      }
      if next == ";", let replacement = self.entityValue(entity) {
        out.unicodeScalars.append(contentsOf: replacement.unicodeScalars)
        pending = iterator.next()
      } else {
        out.append("&")
        out.unicodeScalars.append(contentsOf: entity.unicodeScalars)
        if let character = next { out.unicodeScalars.append(character) }
        pending = iterator.next()
      }
    }
    return out
  }

  private static func entityValue(_ entity: String) -> String? {
    switch entity {
    case "amp": return "&"
    case "lt": return "<"
    case "gt": return ">"
    case "quot": return "\""
    case "apos": return "'"
    default:
      if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
        guard let value = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else {
          return nil
        }
        return String(scalar)
      }
      if entity.hasPrefix("#") {
        guard let value = UInt32(entity.dropFirst(1)), let scalar = Unicode.Scalar(value) else {
          return nil
        }
        return String(scalar)
      }
      return nil
    }
  }
}

private extension String {
  func trimmedASCIIWhitespace() -> String {
    let isWhitespace: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
    return String(self.drop(while: isWhitespace).reversed().drop(while: isWhitespace).reversed())
  }
}
