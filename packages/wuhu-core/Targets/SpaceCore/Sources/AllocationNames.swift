import Crypto
import Foundation

// Width-stratified permutation of the single allocation counter: 1-based ids
// map zero-based onto consecutive strata of size count^3, count^4, ..., and a
// per-width 4-round Feistel (truncated SHA256 rounds) scrambles the position
// inside its stratum. The vocabulary size must be a power of four so every
// stratum is a power of two splitting into exact equal Feistel halves — the
// permutation is then a bijection on the exact domain, with no cycle-walking.
enum AllocationNames {
  static func name(for id: Int64, words: [String], secret: [UInt8]) -> String {
    precondition(id >= 1)
    let count = vocabularySize(words)
    let position = UInt64(id) - 1
    var width = 3
    var base: UInt64 = 0
    var size = count * count * count
    while position - base >= size {
      let (nextBase, baseOverflow) = base.addingReportingOverflow(size)
      let (nextSize, sizeOverflow) = size.multipliedReportingOverflow(by: count)
      precondition(!baseOverflow && !sizeOverflow, "allocation id beyond nameable range")
      base = nextBase
      size = nextSize
      width += 1
    }
    var local = encrypt(position - base, domain: size, key: widthKey(width, secret: secret))
    var indices = [Int](repeating: 0, count: width)
    for slot in (0 ..< width).reversed() {
      indices[slot] = Int(local % count)
      local /= count
    }
    return indices.map { words[$0] }.joined(separator: "-")
  }

  static func id(for name: String, words: [String], secret: [UInt8]) -> Int64? {
    let count = vocabularySize(words)
    let parts = name.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    var base: UInt64 = 0
    var size = count * count * count
    for _ in 3 ..< parts.count {
      let (nextBase, baseOverflow) = base.addingReportingOverflow(size)
      let (nextSize, sizeOverflow) = size.multipliedReportingOverflow(by: count)
      guard !baseOverflow, !sizeOverflow else { return nil }
      base = nextBase
      size = nextSize
    }
    let index = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, UInt64($0)) })
    var local: UInt64 = 0
    for part in parts {
      guard let digit = index[String(part)] else { return nil }
      local = local * count + digit
    }
    let position = base + decrypt(local, domain: size, key: widthKey(parts.count, secret: secret))
    guard position < UInt64(Int64.max) else { return nil }
    return Int64(position) + 1
  }

  private static func vocabularySize(_ words: [String]) -> UInt64 {
    let count = words.count
    precondition(
      count >= 4 && count.nonzeroBitCount == 1 && count.trailingZeroBitCount.isMultiple(of: 2),
      "vocabulary size must be a power of four",
    )
    return UInt64(count)
  }

  private static func encrypt(_ value: UInt64, domain: UInt64, key: [UInt8]) -> UInt64 {
    let half = UInt64(domain.trailingZeroBitCount / 2)
    let mask = (UInt64(1) << half) - 1
    var left = value >> half
    var right = value & mask
    for round in 0 ..< 4 {
      (left, right) = (right, left ^ (roundValue(round, right, key: key) & mask))
    }
    return (left << half) | right
  }

  private static func decrypt(_ value: UInt64, domain: UInt64, key: [UInt8]) -> UInt64 {
    let half = UInt64(domain.trailingZeroBitCount / 2)
    let mask = (UInt64(1) << half) - 1
    var left = value >> half
    var right = value & mask
    for round in (0 ..< 4).reversed() {
      (left, right) = (right ^ (roundValue(round, left, key: key) & mask), left)
    }
    return (left << half) | right
  }

  private static func widthKey(_ width: Int, secret: [UInt8]) -> [UInt8] {
    var hasher = SHA256()
    hasher.update(data: Data(secret))
    hasher.update(data: Data("wuhu-allocation-width".utf8))
    hasher.update(data: Data([UInt8(width)]))
    return Array(hasher.finalize())
  }

  private static func roundValue(_ round: Int, _ input: UInt64, key: [UInt8]) -> UInt64 {
    var hasher = SHA256()
    hasher.update(data: Data(key))
    hasher.update(data: Data([UInt8(round)]))
    withUnsafeBytes(of: input.littleEndian) { hasher.update(bufferPointer: $0) }
    return hasher.finalize().prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
  }
}
