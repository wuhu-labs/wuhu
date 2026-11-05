/// A GIF89a or GIF87a stream walked block by block: each frame's rectangle, palette, timing and
/// where its LZW data starts, nothing decoded. A stream without its trailer is no GIF; one with
/// more than `maxFrames` frames is refused when the parse reaches the next one.
struct GIF {
  enum Disposal { case keep, background, previous }

  struct Frame {
    var x, y, width, height: Int
    var interlaced: Bool
    var palette: Range<Int>
    var transparent: Int?
    var disposal: Disposal
    /// How long a browser shows the frame: a delay of 10 ms or less plays as 100 ms.
    var delayMs: Int
    var codeSize: Int
    var data: Int
  }

  let bytes: [UInt8]
  let width: Int
  let height: Int
  let frames: [Frame]

  static let maxFrames = 10000

  init?(_ bytes: [UInt8]) throws(CapabilityError) {
    guard bytes.count > 13, bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) else { return nil }
    func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    var index = 13
    func table(_ packed: UInt8) -> Range<Int> {
      let size = packed & 0x80 == 0 ? 0 : 3 << (Int(packed & 7) + 1)
      defer { index += size }
      return index ..< index + size
    }
    func skipSubBlocks() -> Bool {
      while index < bytes.count {
        let length = Int(bytes[index])
        index += 1 + length
        if length == 0 { return index <= bytes.count }
      }
      return false
    }
    let global = table(bytes[10])
    var frames: [Frame] = []
    var control: (disposal: Disposal, centiseconds: Int, transparent: Int?) = (.keep, 0, nil)
    while index < bytes.count {
      switch bytes[index] {
      case 0x21:
        guard index + 2 < bytes.count else { return nil }
        if bytes[index + 1] == 0xF9, bytes[index + 2] == 4, index + 6 < bytes.count {
          let packed = bytes[index + 3]
          let disposal: Disposal = switch packed >> 2 & 7 { case 2: .background; case 3: .previous; default: .keep }
          control = (disposal, word(index + 4), packed & 1 == 0 ? nil : Int(bytes[index + 6]))
        }
        index += 2
        guard skipSubBlocks() else { return nil }
      case 0x2C:
        guard index + 10 < bytes.count else { return nil }
        let descriptor = index
        index += 10
        let local = table(bytes[descriptor + 9])
        guard index < bytes.count, (1 ... 8).contains(bytes[index]) else { return nil }
        guard frames.count < Self.maxFrames else {
          throw CapabilityError(.invalidArgument, "Image capabilities read a GIF of at most \(Self.maxFrames) frames.", hint: "Read a GIF this long on a machine.")
        }
        frames.append(Frame(
          x: word(descriptor + 1), y: word(descriptor + 3), width: word(descriptor + 5), height: word(descriptor + 7),
          interlaced: bytes[descriptor + 9] & 0x40 != 0, palette: local.isEmpty ? global : local,
          transparent: control.transparent, disposal: control.disposal,
          delayMs: control.centiseconds <= 1 ? 100 : control.centiseconds * 10,
          codeSize: Int(bytes[index]), data: index + 1,
        ))
        index += 1
        guard skipSubBlocks() else { return nil }
        control = (.keep, 0, nil)
      case 0x3B:
        let (width, height) = (word(6), word(8))
        guard !frames.isEmpty, width > 0, height > 0 else { return nil }
        (self.bytes, self.width, self.height, self.frames) = (bytes, width, height, frames)
        return
      default:
        return nil
      }
    }
    return nil
  }
}

extension GIF {
  /// Plays the frames up to the last of `shown` on an RGBA canvas that starts transparent, as a
  /// browser does, and hands `show` the canvas each time a frame in `shown` is on it.
  func play(through last: Int, show: (Int, [UInt8]) -> Void) {
    var canvas = [UInt8](repeating: 0, count: width * height * 4)
    var decoder = LZWDecoder()
    for (number, frame) in frames.prefix(last + 1).enumerated() {
      let columns = max(0, min(frame.width, width - frame.x))
      let rows = columns == 0 ? 0 : max(0, min(frame.height, height - frame.y))
      let saved = frame.disposal == .previous ? region(of: canvas, frame, columns, rows) : []
      let indices = decoder.decode(subBlocks(from: frame.data), codeSize: frame.codeSize, count: frame.width * frame.height)
      let order = frame.interlaced ? interlacedRows(frame.height) : Array(0 ..< frame.height)
      for (position, index) in indices.enumerated() {
        let row = order[position / frame.width], column = position % frame.width
        let entry = frame.palette.lowerBound + Int(index) * 3
        guard row < rows, column < columns, Int(index) != frame.transparent, entry + 3 <= frame.palette.upperBound else { continue }
        let pixel = ((frame.y + row) * width + frame.x + column) * 4
        (canvas[pixel], canvas[pixel + 1], canvas[pixel + 2], canvas[pixel + 3]) = (bytes[entry], bytes[entry + 1], bytes[entry + 2], 255)
      }
      show(number, canvas)
      switch frame.disposal {
      case .keep: break
      case .background: restore(&canvas, frame, columns, rows, from: [UInt8](repeating: 0, count: columns * rows * 4))
      case .previous: restore(&canvas, frame, columns, rows, from: saved)
      }
    }
  }

  private func subBlocks(from start: Int) -> [UInt8] {
    var data: [UInt8] = []
    var index = start
    while index < bytes.count, bytes[index] != 0 {
      let end = index + 1 + Int(bytes[index])
      data += bytes[index + 1 ..< end]
      index = end
    }
    return data
  }

  private func region(of canvas: [UInt8], _ frame: Frame, _ columns: Int, _ rows: Int) -> [UInt8] {
    (0 ..< rows).flatMap { row in
      let start = ((frame.y + row) * width + frame.x) * 4
      return canvas[start ..< start + columns * 4]
    }
  }

  private func restore(_ canvas: inout [UInt8], _ frame: Frame, _ columns: Int, _ rows: Int, from saved: [UInt8]) {
    for row in 0 ..< rows {
      let start = ((frame.y + row) * width + frame.x) * 4
      canvas.replaceSubrange(start ..< start + columns * 4, with: saved[row * columns * 4 ..< (row + 1) * columns * 4])
    }
  }

  private func interlacedRows(_ height: Int) -> [Int] {
    [(0, 8), (4, 8), (2, 4), (1, 2)].flatMap { start, step in Array(stride(from: start, to: height, by: step)) }
  }
}

/// GIF's variable-width LZW. A truncated or corrupt stream stops early, leaving the rest of the
/// frame undrawn, as browsers do.
private struct LZWDecoder {
  private var prefix = [Int](repeating: -1, count: 4096)
  private var suffix = [UInt8](repeating: 0, count: 4096)
  private var first = [UInt8](repeating: 0, count: 4096)
  private var string: [UInt8] = []

  mutating func decode(_ data: [UInt8], codeSize: Int, count: Int) -> [UInt8] {
    let clear = 1 << codeSize, end = clear + 1
    for code in 0 ..< clear {
      (prefix[code], suffix[code], first[code]) = (-1, UInt8(truncatingIfNeeded: code), UInt8(truncatingIfNeeded: code))
    }
    var output: [UInt8] = []
    output.reserveCapacity(min(count, 1 << 22))
    var (size, next, previous) = (codeSize + 1, clear + 2, -1)
    var (bits, held, position) = (0, 0, 0)
    while output.count < count {
      while held < size, position < data.count {
        bits |= Int(data[position]) << held
        (held, position) = (held + 8, position + 1)
      }
      guard held >= size else { break }
      let code = bits & ((1 << size) - 1)
      (bits, held) = (bits >> size, held - size)
      if code == clear {
        (size, next, previous) = (codeSize + 1, clear + 2, -1)
        continue
      }
      guard code != end, code <= next, previous >= 0 || code < clear else { break }
      if previous >= 0, next < 4096 {
        (prefix[next], suffix[next], first[next]) = (previous, code < next ? first[code] : first[previous], first[previous])
        next += 1
        if next == 1 << size, size < 12 { size += 1 }
      }
      guard code < next else { break }
      string.removeAll(keepingCapacity: true)
      var link = code
      while link >= 0 {
        string.append(suffix[link])
        link = prefix[link]
      }
      output.append(contentsOf: string.reversed())
      previous = code
    }
    return output.count > count ? Array(output.prefix(count)) : output
  }
}
