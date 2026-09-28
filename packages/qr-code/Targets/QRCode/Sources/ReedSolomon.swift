enum GF256 {
  static let exp: [UInt8] = {
    var table = [UInt8](repeating: 0, count: 510)
    var value = 1
    for i in 0 ..< 255 {
      table[i] = UInt8(value)
      table[i + 255] = UInt8(value)
      value <<= 1
      if value >= 256 { value ^= 0x11D }
    }
    return table
  }()

  static let log: [Int] = {
    var table = [Int](repeating: 0, count: 256)
    for i in 0 ..< 255 {
      table[Int(exp[i])] = i
    }
    return table
  }()

  static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
    guard a != 0, b != 0 else { return 0 }
    return exp[log[Int(a)] + log[Int(b)]]
  }
}

enum ReedSolomon {
  // Coefficients of prod_{i=0..degree-1} (x - a^i), highest power first, with
  // the monic leading 1 dropped.
  static func generator(degree: Int) -> [UInt8] {
    var lowestFirst: [UInt8] = [1]
    for i in 0 ..< degree {
      let root = GF256.exp[i]
      var next = [UInt8](repeating: 0, count: lowestFirst.count + 1)
      for (power, coefficient) in lowestFirst.enumerated() {
        next[power] ^= GF256.multiply(coefficient, root)
        next[power + 1] ^= coefficient
      }
      lowestFirst = next
    }
    return (0 ..< degree).map { lowestFirst[degree - 1 - $0] }
  }

  static func parity(for data: [UInt8], degree: Int) -> [UInt8] {
    let divisor = generator(degree: degree)
    var remainder = [UInt8](repeating: 0, count: degree)
    for byte in data {
      let factor = byte ^ remainder.removeFirst()
      remainder.append(0)
      for i in 0 ..< degree {
        remainder[i] ^= GF256.multiply(divisor[i], factor)
      }
    }
    return remainder
  }
}
