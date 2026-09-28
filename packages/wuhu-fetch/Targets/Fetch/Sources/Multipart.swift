#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct MultipartForm: Sendable {
  public let boundary: String
  private var parts: [Bytes] = []

  public init(boundary: String) {
    self.boundary = boundary
  }

  public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

  public mutating func appendField(_ name: String, _ value: String, contentType: String? = nil) {
    var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(escaped(name))\"\r\n"
    if let contentType { header += "Content-Type: \(contentType)\r\n" }
    parts.append(Bytes((header + "\r\n" + value + "\r\n").utf8))
  }

  public mutating func appendFile(name: String, filename: String, contentType: String, bytes: Bytes) {
    var header = "--\(boundary)\r\n"
    header += "Content-Disposition: form-data; name=\"\(escaped(name))\"; filename=\"\(escaped(filename))\"\r\n"
    header += "Content-Type: \(contentType)\r\n\r\n"
    parts.append(Bytes(header.utf8))
    parts.append(bytes)
    parts.append(Bytes("\r\n".utf8))
  }

  public consuming func finish() -> Body {
    parts.append(Bytes("--\(boundary)--\r\n".utf8))
    return .chunks(parts, contentType: contentType)
  }

  // The WHATWG form-data encoding: a quoted value never ends early or splits a
  // header line.
  private func escaped(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": result += "%22"
      case "\r": result += "%0D"
      case "\n": result += "%0A"
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}

public struct MultipartPart: Sendable, Equatable {
  public let name: String?
  public let filename: String?
  public let contentType: String?

  public init(name: String?, filename: String?, contentType: String?) {
    self.name = name
    self.filename = filename
    self.contentType = contentType
  }
}

public enum MultipartError: Error, Sendable, Equatable {
  case notMultipart
  case malformed(String)
}

// Reads a multipart/form-data body one part at a time without collecting it:
// `nextPart()` yields each part's headers, `nextChunk()` its bytes until the
// part ends. Bytes are never buffered beyond one boundary's length past what
// the transport delivered.
public struct MultipartReader {
  private var source: BodyStream.AsyncIterator
  private let delimiter: [UInt8]
  private var buffer: [UInt8]
  private var state = State.preamble

  private enum State {
    case preamble
    case between
    case inPart
    case finished
  }

  private static let maximumHeaderBytes = 16 << 10

  public init(body: Body, contentType: String) throws(MultipartError) {
    guard let boundary = Self.boundary(of: contentType) else { throw .notMultipart }
    source = body.asyncBytes().makeAsyncIterator()
    delimiter = Array("\r\n--\(boundary)".utf8)
    // The first delimiter has no preceding line break; seeding one lets every
    // delimiter be found the same way.
    buffer = Array("\r\n".utf8)
  }

  public static func boundary(of contentType: String) -> String? {
    let pieces = contentType.split(separator: ";").map { $0.trimmingASCIISpaces() }
    guard pieces.first?.lowercased() == "multipart/form-data" else { return nil }
    for piece in pieces.dropFirst() {
      guard let equals = piece.firstIndex(of: "="), piece[..<equals].lowercased() == "boundary" else { continue }
      var value = piece[piece.index(after: equals)...]
      if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
        value = value.dropFirst().dropLast()
      }
      return value.isEmpty || value.count > 70 ? nil : String(value)
    }
    return nil
  }

  public mutating func nextPart() async throws -> MultipartPart? {
    while state == .inPart {
      _ = try await nextChunk()
    }
    switch state {
    case .finished:
      return nil
    case .preamble:
      try await skipToDelimiter()
    case .between, .inPart:
      break
    }
    try await fill(2)
    if buffer.starts(with: Array("--".utf8)) {
      state = .finished
      return nil
    }
    let headerEnd = try await find(Array("\r\n\r\n".utf8), within: Self.maximumHeaderBytes)
    let head = String(decoding: buffer[..<headerEnd], as: UTF8.self)
    buffer.removeFirst(headerEnd + 4)
    state = .inPart
    return Self.part(head)
  }

  public mutating func nextChunk() async throws -> Bytes? {
    guard state == .inPart else { return nil }
    while true {
      if let at = Self.index(of: delimiter, in: buffer) {
        let chunk = Bytes(buffer[..<at])
        buffer.removeFirst(at + delimiter.count)
        state = .between
        return chunk.isEmpty ? nil : chunk
      }
      let safe = buffer.count - (delimiter.count - 1)
      if safe > 0 {
        let chunk = Bytes(buffer[..<safe])
        buffer.removeFirst(safe)
        return chunk
      }
      guard try await pull() else { throw MultipartError.malformed("the body ended inside a part") }
    }
  }

  private mutating func skipToDelimiter() async throws {
    while true {
      if let at = Self.index(of: delimiter, in: buffer) {
        buffer.removeFirst(at + delimiter.count)
        return
      }
      let keep = delimiter.count - 1
      if buffer.count > keep { buffer.removeFirst(buffer.count - keep) }
      guard try await pull() else { throw MultipartError.malformed("no opening boundary") }
    }
  }

  private mutating func fill(_ count: Int) async throws {
    while buffer.count < count {
      guard try await pull() else { throw MultipartError.malformed("the body ended after a boundary") }
    }
  }

  private mutating func find(_ needle: [UInt8], within limit: Int) async throws -> Int {
    while true {
      if let at = Self.index(of: needle, in: buffer) { return at }
      guard buffer.count <= limit else { throw MultipartError.malformed("part headers exceed \(limit) bytes") }
      guard try await pull() else { throw MultipartError.malformed("the body ended inside part headers") }
    }
  }

  private mutating func pull() async throws -> Bool {
    guard let chunk = try await source.next() else { return false }
    buffer.append(contentsOf: chunk)
    return true
  }

  private static func index(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard let first = needle.first, haystack.count >= needle.count else { return nil }
    var start = 0
    while let at = haystack[start...].firstIndex(of: first) {
      guard at + needle.count <= haystack.count else { return nil }
      if haystack[at ..< at + needle.count].elementsEqual(needle) { return at }
      start = at + 1
    }
    return nil
  }

  private static func part(_ head: String) -> MultipartPart {
    var name: String?
    var filename: String?
    var contentType: String?
    for line in head.split(separator: "\r\n") {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let field = line[..<colon].trimmingASCIISpaces().lowercased()
      let value = line[line.index(after: colon)...].trimmingASCIISpaces()
      switch field {
      case "content-disposition":
        for (key, parameter) in parameters(value) {
          switch key {
          case "name": name = parameter
          case "filename": filename = parameter
          default: continue
          }
        }
      case "content-type":
        contentType = value
      default:
        continue
      }
    }
    return MultipartPart(name: name, filename: filename, contentType: contentType)
  }

  private static func parameters(_ value: String) -> [(String, String)] {
    var result: [(String, String)] = []
    var rest = Substring(value)
    guard let semicolon = rest.firstIndex(of: ";") else { return result }
    rest = rest[rest.index(after: semicolon)...]
    while !rest.isEmpty {
      rest = rest.drop { $0 == " " || $0 == "\t" }
      guard let equals = rest.firstIndex(of: "=") else { break }
      let key = rest[..<equals].trimmingASCIISpaces().lowercased()
      rest = rest[rest.index(after: equals)...]
      var parameter = ""
      if rest.first == "\"" {
        rest = rest.dropFirst()
        while let character = rest.first, character != "\"" {
          rest = rest.dropFirst()
          if character == "\\", let escaped = rest.first {
            parameter.append(escaped)
            rest = rest.dropFirst()
          } else {
            parameter.append(character)
          }
        }
        rest = rest.dropFirst()
        rest = rest.drop { $0 != ";" }
      } else {
        let end = rest.firstIndex(of: ";") ?? rest.endIndex
        parameter = rest[..<end].trimmingASCIISpaces()
        rest = rest[end...]
      }
      rest = rest.drop { $0 == ";" }
      result.append((key, parameter))
    }
    return result
  }
}

extension StringProtocol {
  fileprivate func trimmingASCIISpaces() -> String {
    String(drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
  }
}
