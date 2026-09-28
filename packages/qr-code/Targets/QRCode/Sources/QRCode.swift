public struct QRCode: Equatable, Sendable {
  public let size: Int
  let modules: [Bool]

  public subscript(row: Int, column: Int) -> Bool {
    modules[row * size + column]
  }

  public static func encode(_ text: String) -> QRCode? {
    encode(text, forcedMask: nil)
  }

  static func encode(_ text: String, forcedMask: Int?) -> QRCode? {
    let bytes = Array(text.utf8)
    guard let version = Version.fitting(byteCount: bytes.count) else { return nil }
    let codewords = version.interleaved(data: version.dataCodewords(bytes: bytes))
    var canvas = Canvas(version: version)
    canvas.drawFunctionPatterns()
    canvas.drawCodewords(codewords)
    let mask = forcedMask ?? canvas.bestMask()
    canvas.apply(mask: mask)
    return QRCode(size: canvas.size, modules: canvas.modules)
  }

  // Every line pins white-on-black explicitly: with theme-relative colors a
  // light-background terminal renders the code inverted, which does not scan.
  public var terminalRendering: String {
    let quiet = 4
    let total = size + 2 * quiet
    func isLight(_ row: Int, _ column: Int) -> Bool {
      let r = row - quiet
      let c = column - quiet
      guard (0 ..< size).contains(r), (0 ..< size).contains(c) else { return true }
      return !self[r, c]
    }
    var lines: [String] = []
    for top in stride(from: 0, to: total, by: 2) {
      var line = "\u{1B}[97;40m"
      for column in 0 ..< total {
        switch (isLight(top, column), top + 1 < total ? isLight(top + 1, column) : true) {
        case (true, true): line += "█"
        case (true, false): line += "▀"
        case (false, true): line += "▄"
        case (false, false): line += " "
        }
      }
      line += "\u{1B}[0m"
      lines.append(line)
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

// Error correction level L throughout: one-time URLs are short-lived screen
// transfers, so capacity beats redundancy.
struct Version {
  let number: Int

  static let dataCodewordCounts = [19, 34, 55, 80, 108, 136, 156, 194, 232, 274]
  static let parityPerBlock = [7, 10, 15, 20, 26, 18, 20, 24, 30, 18]
  static let blockCounts = [1, 1, 1, 1, 1, 2, 2, 2, 2, 4]

  static func fitting(byteCount: Int) -> Version? {
    for number in 1 ... 10 {
      let version = Version(number: number)
      if version.byteCapacity >= byteCount { return version }
    }
    return nil
  }

  var size: Int { 17 + 4 * number }
  var totalDataCodewords: Int { Self.dataCodewordCounts[number - 1] }
  var characterCountBits: Int { number <= 9 ? 8 : 16 }
  var byteCapacity: Int { (totalDataCodewords * 8 - 4 - characterCountBits) / 8 }

  var alignmentCenters: [Int] {
    guard number >= 2 else { return [] }
    let last = size - 7
    guard number >= 7 else { return [6, last] }
    let count = 3
    let step = (last - 6 + (count - 1) * 2 - 1) / ((count - 1) * 2) * 2
    return [6, last - step, last]
  }

  func dataCodewords(bytes: [UInt8]) -> [UInt8] {
    var bits = BitWriter()
    bits.append(0b0100, count: 4)
    bits.append(bytes.count, count: characterCountBits)
    for byte in bytes {
      bits.append(Int(byte), count: 8)
    }
    let capacityBits = totalDataCodewords * 8
    bits.append(0, count: min(4, capacityBits - bits.count))
    bits.append(0, count: (8 - bits.count % 8) % 8)
    var codewords = bits.bytes
    var pad: UInt8 = 0xEC
    while codewords.count < totalDataCodewords {
      codewords.append(pad)
      pad = pad == 0xEC ? 0x11 : 0xEC
    }
    return codewords
  }

  func interleaved(data: [UInt8]) -> [UInt8] {
    let blockCount = Self.blockCounts[number - 1]
    let parityLength = Self.parityPerBlock[number - 1]
    let shortLength = totalDataCodewords / blockCount
    let longBlocks = totalDataCodewords % blockCount
    var blocks: [[UInt8]] = []
    var cursor = 0
    for index in 0 ..< blockCount {
      let length = shortLength + (index >= blockCount - longBlocks ? 1 : 0)
      blocks.append(Array(data[cursor ..< cursor + length]))
      cursor += length
    }
    let parities = blocks.map { ReedSolomon.parity(for: $0, degree: parityLength) }
    var result: [UInt8] = []
    for i in 0 ..< blocks.map(\.count).max()! {
      for block in blocks where i < block.count {
        result.append(block[i])
      }
    }
    for i in 0 ..< parityLength {
      for parity in parities {
        result.append(parity[i])
      }
    }
    return result
  }
}

struct BitWriter {
  private(set) var bytes: [UInt8] = []
  private(set) var count = 0

  mutating func append(_ value: Int, count bitCount: Int) {
    for shift in stride(from: bitCount - 1, through: 0, by: -1) {
      if count % 8 == 0 { bytes.append(0) }
      if value >> shift & 1 == 1 {
        bytes[count / 8] |= 1 << (7 - count % 8)
      }
      count += 1
    }
  }
}

struct Canvas {
  let version: Version
  let size: Int
  var modules: [Bool]
  var isFunction: [Bool]

  init(version: Version) {
    self.version = version
    size = version.size
    modules = [Bool](repeating: false, count: size * size)
    isFunction = [Bool](repeating: false, count: size * size)
  }

  subscript(row: Int, column: Int) -> Bool {
    get { modules[row * size + column] }
    set { modules[row * size + column] = newValue }
  }

  mutating func setFunction(row: Int, column: Int, dark: Bool) {
    modules[row * size + column] = dark
    isFunction[row * size + column] = true
  }

  mutating func drawFunctionPatterns() {
    for i in 0 ..< size {
      setFunction(row: 6, column: i, dark: i % 2 == 0)
      setFunction(row: i, column: 6, dark: i % 2 == 0)
    }
    drawFinder(centerRow: 3, centerColumn: 3)
    drawFinder(centerRow: 3, centerColumn: size - 4)
    drawFinder(centerRow: size - 4, centerColumn: 3)
    let centers = version.alignmentCenters
    for (i, row) in centers.enumerated() {
      for (j, column) in centers.enumerated() {
        let overlapsFinder = (i == 0 && j == 0)
          || (i == 0 && j == centers.count - 1)
          || (i == centers.count - 1 && j == 0)
        guard !overlapsFinder else { continue }
        drawAlignment(centerRow: row, centerColumn: column)
      }
    }
    drawFormat(bits: 0)
    drawVersionInfo()
  }

  private mutating func drawFinder(centerRow: Int, centerColumn: Int) {
    for dr in -4 ... 4 {
      for dc in -4 ... 4 {
        let row = centerRow + dr
        let column = centerColumn + dc
        guard (0 ..< size).contains(row), (0 ..< size).contains(column) else { continue }
        let distance = max(abs(dr), abs(dc))
        setFunction(row: row, column: column, dark: distance != 2 && distance != 4)
      }
    }
  }

  private mutating func drawAlignment(centerRow: Int, centerColumn: Int) {
    for dr in -2 ... 2 {
      for dc in -2 ... 2 {
        setFunction(row: centerRow + dr, column: centerColumn + dc, dark: max(abs(dr), abs(dc)) != 1)
      }
    }
  }

  mutating func drawFormat(bits mask: Int) {
    let data = 1 << 3 | mask
    var remainder = data
    for _ in 0 ..< 10 {
      remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
    }
    let bits = (data << 10 | remainder) ^ 0x5412
    func bit(_ i: Int) -> Bool { bits >> i & 1 == 1 }
    for i in 0 ... 5 {
      setFunction(row: i, column: 8, dark: bit(i))
    }
    setFunction(row: 7, column: 8, dark: bit(6))
    setFunction(row: 8, column: 8, dark: bit(7))
    setFunction(row: 8, column: 7, dark: bit(8))
    for i in 9 ... 14 {
      setFunction(row: 8, column: 14 - i, dark: bit(i))
    }
    for i in 0 ... 7 {
      setFunction(row: 8, column: size - 1 - i, dark: bit(i))
    }
    for i in 8 ... 14 {
      setFunction(row: size - 15 + i, column: 8, dark: bit(i))
    }
    setFunction(row: size - 8, column: 8, dark: true)
  }

  private mutating func drawVersionInfo() {
    guard version.number >= 7 else { return }
    var remainder = version.number
    for _ in 0 ..< 12 {
      remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25)
    }
    let bits = version.number << 12 | remainder
    for i in 0 ..< 18 {
      let dark = bits >> i & 1 == 1
      let a = size - 11 + i % 3
      let b = i / 3
      setFunction(row: b, column: a, dark: dark)
      setFunction(row: a, column: b, dark: dark)
    }
  }

  mutating func drawCodewords(_ codewords: [UInt8]) {
    var bitIndex = 0
    var right = size - 1
    while right >= 1 {
      if right == 6 { right = 5 }
      for vertical in 0 ..< size {
        for j in 0 ... 1 {
          let column = right - j
          let upward = (right + 1) & 2 == 0
          let row = upward ? size - 1 - vertical : vertical
          if !isFunction[row * size + column], bitIndex < codewords.count * 8 {
            self[row, column] = codewords[bitIndex >> 3] >> (7 - (bitIndex & 7)) & 1 == 1
            bitIndex += 1
          }
        }
      }
      right -= 2
    }
  }

  mutating func apply(mask: Int) {
    for row in 0 ..< size {
      for column in 0 ..< size {
        guard !isFunction[row * size + column], Self.masked(mask, row: row, column: column) else { continue }
        self[row, column].toggle()
      }
    }
    drawFormat(bits: mask)
  }

  static func masked(_ mask: Int, row: Int, column: Int) -> Bool {
    switch mask {
    case 0: (row + column) % 2 == 0
    case 1: row % 2 == 0
    case 2: column % 3 == 0
    case 3: (row + column) % 3 == 0
    case 4: (column / 3 + row / 2) % 2 == 0
    case 5: row * column % 2 + row * column % 3 == 0
    case 6: (row * column % 2 + row * column % 3) % 2 == 0
    case 7: ((row + column) % 2 + row * column % 3) % 2 == 0
    default: fatalError("mask \(mask) is not a QR mask")
    }
  }

  func bestMask() -> Int {
    var best = 0
    var bestPenalty = Int.max
    for mask in 0 ... 7 {
      var candidate = self
      candidate.apply(mask: mask)
      let penalty = candidate.penalty()
      if penalty < bestPenalty {
        best = mask
        bestPenalty = penalty
      }
    }
    return best
  }

  private func penalty() -> Int {
    var score = 0
    for line in 0 ..< size {
      score += runPenalty { self[line, $0] }
      score += runPenalty { self[$0, line] }
      score += finderLikePenalty { self[line, $0] }
      score += finderLikePenalty { self[$0, line] }
    }
    for row in 0 ..< size - 1 {
      for column in 0 ..< size - 1 {
        let color = self[row, column]
        if self[row, column + 1] == color, self[row + 1, column] == color, self[row + 1, column + 1] == color {
          score += 3
        }
      }
    }
    let dark = modules.count(where: { $0 })
    let total = modules.count
    score += ((abs(dark * 20 - total * 10) + total - 1) / total - 1) * 10
    return score
  }

  private func runPenalty(_ module: (Int) -> Bool) -> Int {
    var score = 0
    var run = 1
    for i in 1 ..< size {
      if module(i) == module(i - 1) {
        run += 1
        if run == 5 { score += 3 } else if run > 5 { score += 1 }
      } else {
        run = 1
      }
    }
    return score
  }

  private func finderLikePenalty(_ module: (Int) -> Bool) -> Int {
    let pattern = [true, false, true, true, true, false, true]
    let lights = [Bool](repeating: false, count: 4)
    var score = 0
    for start in 0 ... (size - 11) {
      let window = (0 ..< 11).map { module(start + $0) }
      if window == pattern + lights || window == lights + pattern {
        score += 40
      }
    }
    return score
  }
}
