import OrderedCollections

// wuhu-json owns parse/serialize so object key order is a guarantee of this
// package rather than a Foundation JSONEncoder/JSONDecoder implementation
// detail (Foundation reorders keyed-container keys without .sortedKeys).

extension JSONValue {
  func serialized(sortedKeys: Bool, pretty: Bool) -> String {
    var output = ""
    write(into: &output, sortedKeys: sortedKeys, depth: pretty ? 0 : nil)
    return output
  }

  private func write(into output: inout String, sortedKeys: Bool, depth: Int?) {
    switch self {
    case .null:
      output += "null"
    case let .bool(value):
      output += value ? "true" : "false"
    case let .integer(value):
      output += String(value)
    case let .number(value):
      // Non-finite is unconstructible from wire (parseNumber rejects it); a
      // non-finite here is a programmatic bug, so fail loudly rather than
      // silently emitting a wrong token.
      precondition(value.isFinite, "Cannot serialize non-finite JSONValue.number(\(value)).")
      output += value.description
    case let .string(value):
      JSONValue.writeString(value, into: &output)
    case let .array(value):
      guard !value.isEmpty else {
        output += "[]"
        return
      }
      let inner = depth.map { $0 + 1 }
      output += "["
      for (index, element) in value.enumerated() {
        if index > 0 { output += "," }
        JSONValue.writeBreak(into: &output, depth: inner)
        element.write(into: &output, sortedKeys: sortedKeys, depth: inner)
      }
      JSONValue.writeBreak(into: &output, depth: depth)
      output += "]"
    case let .object(value):
      guard !value.isEmpty else {
        output += "{}"
        return
      }
      let inner = depth.map { $0 + 1 }
      let members = sortedKeys ? value.keys.sorted().map { ($0, value[$0]!) } : Array(value)
      output += "{"
      for (index, member) in members.enumerated() {
        if index > 0 { output += "," }
        JSONValue.writeBreak(into: &output, depth: inner)
        JSONValue.writeString(member.0, into: &output)
        output += depth == nil ? ":" : ": "
        member.1.write(into: &output, sortedKeys: sortedKeys, depth: inner)
      }
      JSONValue.writeBreak(into: &output, depth: depth)
      output += "}"
    }
  }

  private static func writeBreak(into output: inout String, depth: Int?) {
    guard let depth else { return }
    output += "\n"
    output += String(repeating: "  ", count: depth)
  }

  private static func writeString(_ string: String, into output: inout String) {
    output += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case let s where s.value < 0x20:
        let byte = UInt8(s.value)
        output += "\\u00"
        output.append(hexNibble(byte >> 4))
        output.append(hexNibble(byte & 0x0F))
      default:
        output.unicodeScalars.append(scalar)
      }
    }
    output += "\""
  }

  private static func hexNibble(_ value: UInt8) -> Character {
    Character(Unicode.Scalar(value < 10 ? 0x30 + value : 0x61 + (value - 10)))
  }
}

extension JSONValue {
  static func parseJSON(_ bytes: [UInt8]) -> JSONValue? {
    var parser = Parser(bytes: bytes)
    parser.skipWhitespace()
    guard let value = parser.parseValue(depth: 0) else { return nil }
    parser.skipWhitespace()
    guard parser.isAtEnd else { return nil }
    return value
  }

  private struct Parser {
    // Cap nesting to match the 512-deep limit Foundation's JSONDecoder enforced
    // before this hand-rolled parser replaced it. Without it the mutual
    // recursion parseValue -> parseArray/parseObject -> parseValue overflows the
    // stack on hostile input, an untrappable crash of the whole process.
    static let maxDepth = 512

    let bytes: [UInt8]
    var index = 0

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
      while index < bytes.count {
        switch bytes[index] {
        case 0x20, 0x09, 0x0A, 0x0D:
          index += 1
        default:
          return
        }
      }
    }

    mutating func parseValue(depth: Int) -> JSONValue? {
      skipWhitespace()
      guard index < bytes.count else { return nil }
      switch bytes[index] {
      case UInt8(ascii: "{"):
        return parseObject(depth: depth)
      case UInt8(ascii: "["):
        return parseArray(depth: depth)
      case UInt8(ascii: "\""):
        guard let string = parseString() else { return nil }
        return .string(string)
      case UInt8(ascii: "t"):
        return parseLiteral("true", .bool(true))
      case UInt8(ascii: "f"):
        return parseLiteral("false", .bool(false))
      case UInt8(ascii: "n"):
        return parseLiteral("null", .null)
      case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
        return parseNumber()
      default:
        return nil
      }
    }

    mutating func parseObject(depth: Int) -> JSONValue? {
      let depth = depth + 1
      guard depth <= Self.maxDepth else { return nil }
      index += 1
      var object: OrderedDictionary<String, JSONValue> = [:]
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(object)
      }
      while true {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\""),
              let key = parseString()
        else { return nil }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        index += 1
        guard let value = parseValue(depth: depth) else { return nil }
        object[key] = value
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: ","):
          index += 1
        case UInt8(ascii: "}"):
          index += 1
          return .object(object)
        default:
          return nil
        }
      }
    }

    mutating func parseArray(depth: Int) -> JSONValue? {
      let depth = depth + 1
      guard depth <= Self.maxDepth else { return nil }
      index += 1
      var array: [JSONValue] = []
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(array)
      }
      while true {
        guard let value = parseValue(depth: depth) else { return nil }
        array.append(value)
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: ","):
          index += 1
        case UInt8(ascii: "]"):
          index += 1
          return .array(array)
        default:
          return nil
        }
      }
    }

    mutating func parseString() -> String? {
      index += 1
      var out: [UInt8] = []
      while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "\""):
          index += 1
          return String(decoding: out, as: UTF8.self)
        case UInt8(ascii: "\\"):
          index += 1
          guard index < bytes.count else { return nil }
          switch bytes[index] {
          case UInt8(ascii: "\""): out.append(UInt8(ascii: "\"")); index += 1
          case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); index += 1
          case UInt8(ascii: "/"): out.append(UInt8(ascii: "/")); index += 1
          case UInt8(ascii: "b"): out.append(0x08); index += 1
          case UInt8(ascii: "f"): out.append(0x0C); index += 1
          case UInt8(ascii: "n"): out.append(0x0A); index += 1
          case UInt8(ascii: "r"): out.append(0x0D); index += 1
          case UInt8(ascii: "t"): out.append(0x09); index += 1
          case UInt8(ascii: "u"):
            guard let scalar = parseUnicodeEscape() else { return nil }
            out.append(contentsOf: String(scalar).utf8)
          default:
            return nil
          }
        case 0 ..< 0x20:
          return nil
        default:
          out.append(byte)
          index += 1
        }
      }
      return nil
    }

    mutating func parseUnicodeEscape() -> Unicode.Scalar? {
      index += 1
      guard let high = readHex4() else { return nil }
      if high >= 0xD800, high <= 0xDBFF {
        guard index + 1 < bytes.count,
              bytes[index] == UInt8(ascii: "\\"),
              bytes[index + 1] == UInt8(ascii: "u")
        else { return nil }
        index += 2
        guard let low = readHex4(), low >= 0xDC00, low <= 0xDFFF else { return nil }
        let value = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(low - 0xDC00)
        return Unicode.Scalar(value)
      }
      if high >= 0xDC00, high <= 0xDFFF {
        return nil
      }
      return Unicode.Scalar(high)
    }

    mutating func readHex4() -> UInt16? {
      guard index + 4 <= bytes.count else { return nil }
      var value: UInt16 = 0
      for _ in 0 ..< 4 {
        guard let digit = Self.hexDigit(bytes[index]) else { return nil }
        value = value << 4 | UInt16(digit)
        index += 1
      }
      return value
    }

    mutating func parseNumber() -> JSONValue? {
      let start = index
      if bytes[index] == UInt8(ascii: "-") { index += 1 }
      guard index < bytes.count else { return nil }
      let firstDigit = bytes[index]
      guard firstDigit >= UInt8(ascii: "0"), firstDigit <= UInt8(ascii: "9") else { return nil }
      if firstDigit == UInt8(ascii: "0") {
        // RFC 8259: a leading zero must stand alone; "0123"/"007" are invalid.
        // A fraction or exponent may still follow the lone zero.
        index += 1
      } else {
        _ = consumeDigits()
      }
      var isDouble = false
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        isDouble = true
        index += 1
        guard consumeDigits() else { return nil }
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        isDouble = true
        index += 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
          index += 1
        }
        guard consumeDigits() else { return nil }
      }
      let literal = String(decoding: bytes[start ..< index], as: UTF8.self)
      if !isDouble, let value = Int(literal) {
        return .integer(value)
      }
      guard let value = Double(literal), value.isFinite else { return nil }
      return .number(value)
    }

    mutating func consumeDigits() -> Bool {
      let start = index
      while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") {
        index += 1
      }
      return index > start
    }

    mutating func parseLiteral(_ literal: String, _ value: JSONValue) -> JSONValue? {
      let expected = Array(literal.utf8)
      guard index + expected.count <= bytes.count else { return nil }
      for (offset, byte) in expected.enumerated() where bytes[index + offset] != byte {
        return nil
      }
      index += expected.count
      return value
    }

    static func hexDigit(_ byte: UInt8) -> UInt8? {
      switch byte {
      case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
      case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
      default: nil
      }
    }
  }
}
