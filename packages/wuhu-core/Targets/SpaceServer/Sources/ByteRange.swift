// One `bytes=` range per RFC 9110 §14.1; a multi-range or malformed header is
// ignored and the whole representation served, which the RFC permits.
enum ByteRange: Equatable {
  case whole
  case partial(ClosedRange<Int>)
  case unsatisfiable

  init(header: String?, length: Int) {
    guard let header, header.hasPrefix("bytes="), !header.contains(",") else {
      self = .whole
      return
    }
    let spec = header.dropFirst("bytes=".count)
    guard let dash = spec.firstIndex(of: "-") else {
      self = .whole
      return
    }
    let first = spec[..<dash]
    let last = spec[spec.index(after: dash)...]
    if first.isEmpty {
      guard let suffix = Int(last) else {
        self = .whole
        return
      }
      self = suffix > 0 && length > 0 ? .partial(max(0, length - suffix) ... length - 1) : .unsatisfiable
      return
    }
    guard let start = Int(first), start >= 0 else {
      self = .whole
      return
    }
    let end: Int
    if last.isEmpty {
      end = length - 1
    } else {
      guard let parsed = Int(last), parsed >= start else {
        self = .whole
        return
      }
      end = min(parsed, length - 1)
    }
    self = start < length ? .partial(start ... end) : .unsatisfiable
  }
}
