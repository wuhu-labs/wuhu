public struct SpaceURL: Hashable, Sendable {
  public enum Scheme: String, Sendable, CaseIterable {
    case https
    case wuhu
  }

  public enum Destination: Hashable, Sendable {
    case session(String)
    case conversation(String)
    case path(String)
  }

  public let host: String
  public let destination: Destination
  public let percentEncodedQuery: String?
  public let percentEncodedFragment: String?

  public init?(
    host: String,
    destination: Destination,
    percentEncodedQuery: String? = nil,
    percentEncodedFragment: String? = nil,
  ) {
    guard let host = Self.normalizedHost(host[...]),
          Destination(percentEncodedPath: destination.percentEncodedPath) == destination,
          percentEncodedQuery?.contains("#") != true
    else { return nil }
    self.host = host
    self.destination = destination
    self.percentEncodedQuery = percentEncodedQuery
    self.percentEncodedFragment = percentEncodedFragment
  }

  public init?(_ spelling: String, contextHost: String? = nil) {
    let host: Substring
    var tail: Substring
    if let separator = spelling.firstRange(of: "://") {
      guard Scheme(rawValue: spelling[..<separator.lowerBound].lowercased()) != nil else { return nil }
      let rest = spelling[separator.upperBound...]
      let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
      host = rest[..<authorityEnd]
      tail = rest[authorityEnd...]
    } else {
      guard let contextHost else { return nil }
      let hostless = spelling.lowercased().hasPrefix("wuhu:/") ? spelling.dropFirst("wuhu:".count) : spelling[...]
      guard hostless.hasPrefix("/"), !hostless.hasPrefix("//") else { return nil }
      host = contextHost[...]
      tail = hostless
    }
    var fragment: String?
    if let hash = tail.firstIndex(of: "#") {
      fragment = String(tail[tail.index(after: hash)...])
      tail = tail[..<hash]
    }
    var query: String?
    if let mark = tail.firstIndex(of: "?") {
      query = String(tail[tail.index(after: mark)...])
      tail = tail[..<mark]
    }
    guard let destination = Destination(percentEncodedPath: tail.isEmpty ? "/" : String(tail)) else { return nil }
    self.init(host: String(host), destination: destination, percentEncodedQuery: query, percentEncodedFragment: fragment)
  }

  public static func host(origin: String) -> String? {
    let secured = origin.lowercased().hasPrefix("http://") ? "https://" + origin.dropFirst("http://".count) : origin
    guard let url = SpaceURL(secured.hasSuffix("/") ? secured : secured + "/"),
          url.destination == .path("/"), url.percentEncodedQuery == nil, url.percentEncodedFragment == nil
    else { return nil }
    return url.host
  }

  public func formatted(_ scheme: Scheme) -> String {
    var spelling = "\(scheme.rawValue)://\(self.host)\(self.destination.percentEncodedPath)"
    if let query = self.percentEncodedQuery { spelling += "?\(query)" }
    if let fragment = self.percentEncodedFragment { spelling += "#\(fragment)" }
    return spelling
  }

  private static func normalizedHost(_ raw: Substring) -> String? {
    guard !raw.isEmpty,
          raw.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && !"@\\%".unicodeScalars.contains($0) })
    else { return nil }
    let authority = raw.lowercased()
    let hostEnd: String.Index
    if authority.hasPrefix("[") {
      guard let close = authority.firstIndex(of: "]") else { return nil }
      hostEnd = authority.index(after: close)
    } else {
      hostEnd = authority.firstIndex(of: ":") ?? authority.endIndex
    }
    guard hostEnd > authority.startIndex else { return nil }
    let port = authority[hostEnd...]
    let host: String
    if port.isEmpty {
      host = authority
    } else {
      guard port.first == ":", port.count > 1, port.dropFirst().allSatisfy(\.isASCIIDigit) else { return nil }
      host = port == ":443" ? String(authority[..<hostEnd]) : authority
    }
    // `wuhu://system/…` is the server's built-in files, never a space's host;
    // `system:5530` still is one.
    return host == reservedSystemHost ? nil : host
  }
}

/// The host `system` names the read-only files built into the server
/// (`wuhu://system/<path>`), so no space URL may use it bare. With a port
/// (other than the dropped `:443`), `system:5530` is an ordinary space host.
let reservedSystemHost = "system"

extension SpaceURL.Destination {
  public init?(percentEncodedPath: String) {
    guard percentEncodedPath.hasPrefix("/") else { return nil }
    var raw = percentEncodedPath.dropFirst()
    if raw.hasSuffix("/") { raw = raw.dropLast() }
    if raw.isEmpty {
      self = .path("/")
      return
    }
    var segments: [String] = []
    for encoded in raw.split(separator: "/", omittingEmptySubsequences: false) {
      guard let segment = decodedSegment(encoded) else { return nil }
      segments.append(segment)
    }
    switch (segments.count, segments[0], segments.dropFirst().first) {
    case (3, "_", "sessions"): self = .session(segments[2])
    case (3, "_", "conversations"): self = .conversation(segments[2])
    default: self = .path("/" + segments.joined(separator: "/"))
    }
  }

  public var percentEncodedPath: String {
    switch self {
    case let .session(id): "/_/sessions/\(encodedSegment(id))"
    case let .conversation(id): "/_/conversations/\(encodedSegment(id))"
    case let .path(path): path == "/" ? "/" : path.split(separator: "/").map { "/" + encodedSegment($0) }.joined()
    }
  }
}

private func decodedSegment(_ encoded: Substring) -> String? {
  var bytes: [UInt8] = []
  var utf8 = encoded.utf8[...]
  while let byte = utf8.popFirst() {
    guard byte == UInt8(ascii: "%") else {
      bytes.append(byte)
      continue
    }
    guard utf8.count >= 2,
          let high = hexValue(utf8.removeFirst()),
          let low = hexValue(utf8.removeFirst())
    else { return nil }
    bytes.append(high << 4 | low)
  }
  guard let segment = String(validating: bytes, as: UTF8.self),
        !segment.isEmpty, segment != ".", segment != "..",
        !segment.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F })
  else { return nil }
  return segment
}

private func encodedSegment(_ segment: some StringProtocol) -> String {
  var encoded = ""
  for byte in segment.utf8 {
    switch byte {
    case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
         UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
         UInt8(ascii: "_"), UInt8(ascii: "~"):
      encoded.unicodeScalars.append(Unicode.Scalar(byte))
    default:
      encoded += "%" + String(byte >> 4, radix: 16, uppercase: true) + String(byte & 0xF, radix: 16, uppercase: true)
    }
  }
  return encoded
}

private func hexValue(_ byte: UInt8) -> UInt8? {
  switch byte {
  case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
  case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
  case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
  default: nil
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
