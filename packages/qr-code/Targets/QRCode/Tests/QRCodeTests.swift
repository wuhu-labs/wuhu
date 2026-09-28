@testable import QRCode
import Testing

@Suite
struct QRCodeTests {
  @Test func matchesTheNodeQRCodeReferenceMatrices() throws {
    for golden in goldenQRCodes {
      let code = try #require(QRCode.encode(golden.text, forcedMask: golden.mask))
      #expect(code.size == golden.rows.count)
      var mismatches = 0
      for (row, line) in golden.rows.enumerated() {
        for (column, character) in line.enumerated() {
          if code[row, column] != (character == "#") {
            mismatches += 1
          }
        }
      }
      #expect(mismatches == 0, "\(mismatches) module mismatches for \(golden.text.prefix(24))")
    }
  }

  @Test(arguments: [1, 17, 18, 53, 154, 271])
  func roundTripsThroughAStructuralBitDecoder(length: Int) throws {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789:/#?&=._-")
    let text = String((0 ..< length).map { alphabet[($0 &* 7 &+ length) % alphabet.count] })
    let code = try #require(QRCode.encode(text))
    #expect(decode(code) == text)
  }

  @Test func everyMaskRoundTrips() throws {
    let text = "https://example.com/enroll#token=jt_abcdefghijklmnopqrstuvwxyz012345"
    for mask in 0 ... 7 {
      let code = try #require(QRCode.encode(text, forcedMask: mask))
      #expect(decode(code) == text)
    }
  }

  @Test func refusesTextBeyondVersionTenCapacity() {
    #expect(QRCode.encode(String(repeating: "a", count: 271)) != nil)
    #expect(QRCode.encode(String(repeating: "a", count: 272)) == nil)
  }

  @Test func parityMakesEveryBlockSyndromeFree() {
    for length in [0, 1, 19, 68, 116] {
      let data = (0 ..< length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
      for degree in [7, 18, 30] {
        let codeword = data + ReedSolomon.parity(for: data, degree: degree)
        for i in 0 ..< degree {
          #expect(evaluate(codeword, at: GF256.exp[i]) == 0)
        }
      }
    }
  }

  @Test func terminalRenderingKeepsAQuietZone() throws {
    let code = try #require(QRCode.encode("hi"))
    let lines = try renderedGlyphLines(code)
    #expect(lines.count == (code.size + 8 + 1) / 2)
    #expect(Set(lines.joined()).isSubset(of: ["█", "▀", "▄", " "]))
    #expect(lines.first == String(repeating: "█", count: code.size + 8))
    for line in lines {
      #expect(line.hasPrefix("████"))
      #expect(line.hasSuffix("████") || line.hasSuffix("▀▀▀▀"))
    }
  }

  @Test func terminalRenderingPinsDarkModulesToBlackOnEveryTheme() throws {
    let code = try #require(QRCode.encode("hi"))
    #expect(code[0, 0])
    let lines = try renderedGlyphLines(code)
    // QR row 0 is the top half of glyph line 2 (below the 4-module quiet
    // zone); with the foreground pinned white and the background black, a
    // dark module must land in a glyph whose top half is background.
    let glyphs = Array(try #require(lines.dropFirst(2).first))
    #expect(glyphs[4] == "▄" || glyphs[4] == " ")
  }
}

// Every rendered line must carry the explicit white-on-black SGR framing;
// theme-relative output would invert on light terminals.
private func renderedGlyphLines(_ code: QRCode) throws -> [String] {
  try code.terminalRendering.split(separator: "\n").map { line in
    let framed = try #require(line.wholeMatch(of: /\u{1B}\[97;40m(.*)\u{1B}\[0m/))
    return String(framed.1)
  }
}

private func evaluate(_ coefficients: [UInt8], at point: UInt8) -> UInt8 {
  var result: UInt8 = 0
  for coefficient in coefficients {
    result = GF256.multiply(result, point) ^ coefficient
  }
  return result
}

// Not an independent decoder: it reuses production's function-pattern map,
// mask predicates, zigzag geometry, and BCH format polynomial, so round-trips
// prove internal self-consistency plus an independent Reed-Solomon syndrome
// check. The external geometry proof is the node-qrcode golden fixtures.
private func decode(_ code: QRCode) -> String? {
  let version = Version(number: (code.size - 17) / 4)
  var canvas = Canvas(version: version)
  canvas.drawFunctionPatterns()

  var formatBits = 0
  for i in 0 ... 5 {
    formatBits |= (code[i, 8] ? 1 : 0) << i
  }
  formatBits |= (code[7, 8] ? 1 : 0) << 6
  formatBits |= (code[8, 8] ? 1 : 0) << 7
  formatBits |= (code[8, 7] ? 1 : 0) << 8
  for i in 9 ... 14 {
    formatBits |= (code[8, 14 - i] ? 1 : 0) << i
  }
  let unmasked = formatBits ^ 0x5412
  let data5 = unmasked >> 10
  var remainder = data5
  for _ in 0 ..< 10 {
    remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537)
  }
  guard data5 << 10 | remainder == unmasked else { return nil }
  let mask = data5 & 0b111
  guard data5 >> 3 == 1 else { return nil }

  var bits: [Bool] = []
  var right = code.size - 1
  while right >= 1 {
    if right == 6 { right = 5 }
    for vertical in 0 ..< code.size {
      for j in 0 ... 1 {
        let column = right - j
        let upward = (right + 1) & 2 == 0
        let row = upward ? code.size - 1 - vertical : vertical
        if !canvas.isFunction[row * code.size + column] {
          bits.append(code[row, column] != Canvas.masked(mask, row: row, column: column))
        }
      }
    }
    right -= 2
  }

  let blockCount = Version.blockCounts[version.number - 1]
  let degree = Version.parityPerBlock[version.number - 1]
  let total = version.totalDataCodewords + blockCount * degree
  guard bits.count >= total * 8 else { return nil }
  var codewords: [UInt8] = []
  for i in 0 ..< total {
    var byte: UInt8 = 0
    for j in 0 ..< 8 {
      byte = byte << 1 | (bits[i * 8 + j] ? 1 : 0)
    }
    codewords.append(byte)
  }

  let short = version.totalDataCodewords / blockCount
  let lengths = (0 ..< blockCount).map { short + ($0 >= blockCount - version.totalDataCodewords % blockCount ? 1 : 0) }
  var blocks: [[UInt8]] = Array(repeating: [], count: blockCount)
  var cursor = 0
  for i in 0 ..< lengths.max()! {
    for block in 0 ..< blockCount where i < lengths[block] {
      blocks[block].append(codewords[cursor])
      cursor += 1
    }
  }
  var parities: [[UInt8]] = Array(repeating: [], count: blockCount)
  for _ in 0 ..< degree {
    for block in 0 ..< blockCount {
      parities[block].append(codewords[cursor])
      cursor += 1
    }
  }
  for block in 0 ..< blockCount {
    for i in 0 ..< degree {
      guard evaluate(blocks[block] + parities[block], at: GF256.exp[i]) == 0 else { return nil }
    }
  }

  let data = Array(blocks.joined())
  guard data[0] >> 4 == 0b0100 else { return nil }
  let countBits = version.characterCountBits
  var stream: [Bool] = []
  for byte in data {
    for j in 0 ..< 8 {
      stream.append(byte >> (7 - j) & 1 == 1)
    }
  }
  func read(_ offset: Int, _ count: Int) -> Int {
    var value = 0
    for i in 0 ..< count {
      value = value << 1 | (stream[offset + i] ? 1 : 0)
    }
    return value
  }
  let length = read(4, countBits)
  var bytes: [UInt8] = []
  for i in 0 ..< length {
    bytes.append(UInt8(read(4 + countBits + i * 8, 8)))
  }
  return String(decoding: bytes, as: UTF8.self)
}
