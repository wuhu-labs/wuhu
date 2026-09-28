struct SecretMasker: Sendable {
  static let replacement: [UInt8] = Array("***".utf8)

  private let secrets: [[UInt8]]
  private var held: [UInt8] = []

  init(secrets: some Sequence<String>) {
    self.secrets = Set(secrets)
      .map { Array($0.utf8) }
      .filter { !$0.isEmpty }
      .sorted { $0.count != $1.count ? $0.count > $1.count : $0.lexicographicallyPrecedes($1) }
  }

  mutating func mask(_ chunk: [UInt8]) -> [UInt8] {
    guard !secrets.isEmpty else { return chunk }
    return process(held.isEmpty ? chunk : held + chunk, flushing: false)
  }

  mutating func flush() -> [UInt8] {
    guard !secrets.isEmpty, !held.isEmpty else { return [] }
    return process(held, flushing: true)
  }

  private mutating func process(_ buffer: [UInt8], flushing: Bool) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(buffer.count)
    var index = 0
    scan: while index < buffer.count {
      let remaining = buffer.count - index
      // A secret longer than the remaining bytes that prefix-matches could
      // still complete with future bytes, so the outcome at this position is
      // undecided: hold everything from here. Deciding before checking full
      // matches is what makes chunked output identical to whole-string output.
      if !flushing {
        for secret in secrets where secret.count > remaining {
          if buffer[index...].elementsEqual(secret[..<remaining]) { break scan }
        }
      }
      for secret in secrets where secret.count <= remaining {
        if buffer[index ..< index + secret.count].elementsEqual(secret) {
          output += Self.replacement
          index += secret.count
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
