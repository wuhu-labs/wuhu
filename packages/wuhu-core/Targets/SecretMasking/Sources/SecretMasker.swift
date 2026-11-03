public struct SecretMasker: Sendable {
  private static let replacement: [UInt8] = Array("***".utf8)

  private var forms: [[UInt8]] = []
  private var held: [UInt8] = []

  public init(secrets: some Sequence<String>) {
    insert(secrets.flatMap(Self.forms).map { Array($0.utf8) })
  }

  /// Adds the other masker's secrets; a stream in progress keeps the bytes it holds back.
  public mutating func formUnion(_ other: SecretMasker) {
    insert(other.forms)
  }

  private mutating func insert(_ new: [[UInt8]]) {
    forms = Set(forms + new).sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
  }

  public func masked(_ text: String) -> String {
    String(decoding: masked(Array(text.utf8)), as: UTF8.self)
  }

  public func masked(_ bytes: [UInt8]) -> [UInt8] {
    guard !forms.isEmpty else { return bytes }
    var whole = self
    return whole.process(bytes, flushing: true)
  }

  public mutating func mask(_ chunk: [UInt8]) -> [UInt8] {
    guard !forms.isEmpty else { return chunk }
    return process(held.isEmpty ? chunk : held + chunk, flushing: false)
  }

  /// How many of the bytes fed to `mask` it holds back, undecided: the stream's last bytes, unchanged.
  public var holding: Int { held.count }

  public mutating func flush() -> [UInt8] {
    guard !held.isEmpty else { return [] }
    return process(held, flushing: true)
  }

  /// The spellings of `secret` a masker replaces, in a stable order.
  public static func forms(of secret: String) -> [String] {
    let start = secret.firstIndex { !$0.isWhitespace } ?? secret.endIndex
    let end = secret.lastIndex { !$0.isWhitespace }.map(secret.index(after:)) ?? start
    guard start < end else { return [] }
    let trimmed = String(secret[start ..< end])
    let escaped = [secret, trimmed].map(jsonEscaped)
    return [secret, trimmed] + escaped + escaped.map { $0.replacing("/", with: #"\/"#) }
  }

  private static func jsonEscaped(_ text: String) -> String {
    var escaped = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": escaped += #"\""#.unicodeScalars
      case "\\": escaped += #"\\"#.unicodeScalars
      case "\n": escaped += #"\n"#.unicodeScalars
      case "\r": escaped += #"\r"#.unicodeScalars
      case "\t": escaped += #"\t"#.unicodeScalars
      case "\u{8}": escaped += #"\b"#.unicodeScalars
      case "\u{C}": escaped += #"\f"#.unicodeScalars
      case ..<"\u{20}":
        let hex = String(scalar.value, radix: 16)
        escaped += (#"\u"# + String(repeating: "0", count: 4 - hex.count) + hex).unicodeScalars
      default: escaped.append(scalar)
      }
    }
    return String(escaped)
  }

  private mutating func process(_ buffer: [UInt8], flushing: Bool) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(buffer.count)
    var index = 0
    scan: while index < buffer.count {
      let remaining = buffer.count - index
      // A form longer than the remaining bytes that prefix-matches could
      // still complete with future bytes, so the outcome at this position is
      // undecided: hold everything from here. Deciding before checking full
      // matches is what makes chunked output identical to whole-string output.
      if !flushing {
        for form in forms where form.count > remaining {
          if buffer[index...].elementsEqual(form[..<remaining]) { break scan }
        }
      }
      for form in forms where form.count <= remaining {
        if buffer[index ..< index + form.count].elementsEqual(form) {
          output += Self.replacement
          index += form.count
          continue scan
        }
      }
      output.append(buffer[index])
      index += 1
    }
    held = flushing ? [] : Array(buffer[index...])
    return output
  }
}
