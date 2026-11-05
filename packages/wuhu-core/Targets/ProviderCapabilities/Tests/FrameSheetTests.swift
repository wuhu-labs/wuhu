import Foundation
import ProviderCapabilities
import Testing

typealias Pixel = [UInt8]
private let red: Pixel = [255, 0, 0, 255], green: Pixel = [0, 255, 0, 255], blue: Pixel = [0, 0, 255, 255], clear: Pixel = [0, 0, 0, 0]

private struct Frame {
  var x = 0, y = 0, width: Int, height: Int
  var indices: [UInt8]
  var palette: [Pixel]?
  var centiseconds = 10
  var disposal = 1
  var transparent: UInt8?
  var interlaced = false
  var keptBytes: Int?

  static func solid(_ width: Int, _ height: Int, _ index: UInt8, x: Int = 0, y: Int = 0, disposal: Int = 1) -> Frame {
    Frame(x: x, y: y, width: width, height: height, indices: Array(repeating: index, count: width * height), disposal: disposal)
  }
}

private func gif(_ width: Int, _ height: Int, palette: [Pixel] = [red, green, blue], _ frames: [Frame]) -> Data {
  func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
  func table(_ colors: [Pixel]) -> (bits: Int, bytes: [UInt8]) {
    let bits = (1 ... 8).first { 1 << $0 >= colors.count }!
    return (bits, (colors + Array(repeating: clear, count: (1 << bits) - colors.count)).flatMap { $0.prefix(3) })
  }
  let global = table(palette)
  var bytes = Array("GIF89a".utf8) + word(width) + word(height) + [0xF0 | UInt8(global.bits - 1), 0, 0] + global.bytes
  for frame in frames {
    let local = frame.palette.map(table)
    let rows = frame.interlaced ? [(0, 8), (4, 8), (2, 4), (1, 2)].flatMap { Array(stride(from: $0, to: frame.height, by: $1)) } : Array(0 ..< frame.height)
    let ordered = rows.flatMap { frame.indices[$0 * frame.width ..< ($0 + 1) * frame.width] }
    let codeSize = max(2, (local ?? global).bits)
    var data = lzw(ordered, codeSize: codeSize)
    if let kept = frame.keptBytes { data = Array(data.prefix(kept)) }
    bytes += [0x21, 0xF9, 4, UInt8(frame.disposal << 2) | (frame.transparent == nil ? 0 : 1)] + word(frame.centiseconds) + [frame.transparent ?? 0, 0]
    bytes += [0x2C] + word(frame.x) + word(frame.y) + word(frame.width) + word(frame.height)
    bytes += [(local.map { 0x80 | UInt8($0.bits - 1) } ?? 0) | (frame.interlaced ? 0x40 : 0)] + (local?.bytes ?? []) + [UInt8(codeSize)]
    for start in stride(from: 0, to: data.count, by: 255) {
      let block = data[start ..< min(start + 255, data.count)]
      bytes += [UInt8(block.count)] + block
    }
    bytes += [0]
  }
  return Data(bytes + [0x3B])
}

private func lzw(_ indices: [UInt8], codeSize: Int) -> [UInt8] {
  let clearCode = 1 << codeSize
  var (table, next, size) = ([Int: Int](), clearCode + 2, codeSize + 1)
  var (output, bits, held) = ([UInt8](), 0, 0)
  func emit(_ code: Int) {
    (bits, held) = (bits | code << held, held + size)
    while held >= 8 {
      output.append(UInt8(bits & 0xFF))
      (bits, held) = (bits >> 8, held - 8)
    }
  }
  emit(clearCode)
  var prefix = Int(indices[0])
  for index in indices.dropFirst() {
    let key = prefix << 8 | Int(index)
    if let code = table[key] {
      prefix = code
      continue
    }
    emit(prefix)
    if next < 4096 {
      table[key] = next
      next += 1
      if next > 1 << size, size < 12 { size += 1 }
    } else {
      emit(clearCode)
      (table, next, size) = ([:], clearCode + 2, codeSize + 1)
    }
    prefix = Int(index)
  }
  emit(prefix)
  emit(clearCode + 1)
  if held > 0 { output.append(UInt8(bits & 0xFF)) }
  return output
}

extension FrameSheet {
  fileprivate func pixel(_ x: Int, _ y: Int) -> [UInt8] {
    Array(rgba[(y * width + x) * 4 ..< (y * width + x) * 4 + 4])
  }

  fileprivate var size: [Int] { [width, height] }

  fileprivate var shown: [[Int]] { frames.map { [$0.index, $0.atMs] } }
}

@Suite struct FrameSheetTests {
  @Test func theChosenFramesTileInTheirOrderLeftToRightThenDown() throws {
    let sheet = try FrameSheet(gif: gif(2, 2, [.solid(2, 2, 0), .solid(2, 2, 1), .solid(2, 2, 2)]), frames: .indices([2, 0, 1]))
    #expect(sheet.size == [4, 4])
    #expect([sheet.pixel(1, 1), sheet.pixel(2, 0), sheet.pixel(1, 3), sheet.pixel(3, 3)] == [blue, red, green, clear])
    #expect(sheet.shown == [[2, 200], [0, 0], [1, 100]])
    #expect(sheet.answer(path: "/sheet.png") == ["path": "/sheet.png", "width": 4, "height": 4, "frames": [["index": 2, "atMs": 200], ["index": 0, "atMs": 0], ["index": 1, "atMs": 100]]])
  }

  @Test func aCountTakesTheFrameOnScreenMidwayThroughEachEqualStretchOfTime() throws {
    var frames = (0 ..< 4).map { _ in Frame.solid(1, 1, 0) }
    frames[3].centiseconds = 70
    let data = gif(1, 1, frames)
    #expect(try FrameSheet(gif: data, frames: .count(4)).shown == [[1, 100], [3, 300]])
    #expect(try FrameSheet(gif: data, frames: .count(1)).shown == [[3, 300]])
    #expect(try FrameSheet(gif: data, frames: .count(10)).shown.map(\.[0]) == [0, 1, 2, 3])
  }

  @Test func aDelayOfTenMillisecondsOrLessPlaysForAHundredAsInABrowser() throws {
    let frames = [0, 1, 2, 3].map { var frame = Frame.solid(1, 1, 0); frame.centiseconds = $0; return frame }
    let data = gif(1, 1, frames)
    #expect(try ImageInfo(data)?.delaysMs == [100, 100, 20, 30])
    #expect(try FrameSheet(gif: data, frames: .indices([3])).shown == [[3, 220]])
  }

  @Test(arguments: [(1, blue), (2, clear), (3, red)])
  func aFrameLeavesTheCanvasAsItsDisposalSays(disposal: Int, left: Pixel) throws {
    let frames = [Frame.solid(2, 1, 0), .solid(1, 1, 2, disposal: disposal), .solid(1, 1, 1, x: 1)]
    let sheet = try FrameSheet(gif: gif(2, 1, frames), frames: .indices([2]))
    #expect([sheet.pixel(0, 0), sheet.pixel(1, 0)] == [left, green])
  }

  @Test(arguments: [1, 2, 3])
  func aFrameWhollyOffTheCanvasDrawsAndDisposesNothing(disposal: Int) throws {
    let frames = [Frame.solid(1, 1, 0), .solid(1, 1, 2, x: 2, disposal: disposal), .solid(1, 1, 1, y: 2, disposal: disposal)]
    let sheet = try FrameSheet(gif: gif(1, 1, frames), frames: .indices([0, 1, 2]))
    #expect(sheet.rgba == red + red + red + clear)
  }

  @Test func theTransparentIndexShowsWhatIsBeneath() throws {
    var top = Frame(width: 2, height: 1, indices: [2, 1])
    top.transparent = 2
    let sheet = try FrameSheet(gif: gif(2, 1, [Frame(width: 2, height: 1, indices: [0, 2], transparent: 2), top]), frames: .indices([0, 1]))
    #expect([sheet.pixel(0, 0), sheet.pixel(1, 0), sheet.pixel(2, 0), sheet.pixel(3, 0)] == [red, clear, red, green])
  }

  @Test func interlacedRowsLandWhereTheyBelong() throws {
    let palette = (0 ..< 10).map { (i: Int) -> Pixel in [UInt8(i * 20), 0, 0, 255] }
    let sheet = try FrameSheet(gif: gif(1, 10, palette: palette, [Frame(width: 1, height: 10, indices: Array(0 ..< 10), interlaced: true)]), frames: .count(1))
    #expect((0 ..< 10).map { sheet.pixel(0, $0) } == palette)
  }

  @Test func aLocalPaletteAndAFrameOutsideTheCanvasDrawOnlyWhatFits() throws {
    let frames = [Frame(x: 1, y: 1, width: 2, height: 2, indices: [0, 0, 0, 0], palette: [blue])]
    let sheet = try FrameSheet(gif: gif(2, 2, frames), frames: .indices([0]))
    #expect([sheet.pixel(0, 0), sheet.pixel(1, 0), sheet.pixel(0, 1), sheet.pixel(1, 1)] == [clear, clear, clear, blue])
  }

  @Test func aTruncatedFrameStopsWhereItsDataEndsAndLaterFramesStillPlay() throws {
    var cut = Frame.solid(4, 4, 0)
    cut.keptBytes = 1
    let sheet = try FrameSheet(gif: gif(4, 4, [cut, .solid(1, 1, 1, x: 3, y: 3)]), frames: .indices([0, 1]))
    #expect([sheet.pixel(0, 0), sheet.pixel(1, 0), sheet.pixel(3, 3)] == [red, clear, clear])
    #expect([sheet.pixel(4, 0), sheet.pixel(5, 0), sheet.pixel(7, 3)] == [red, clear, green])
  }

  @Test func aNoisyFrameLongerThanTheCodeTableDecodesExactly() throws {
    let palette = (0 ..< 256).map { (i: Int) -> Pixel in [UInt8(i), UInt8(255 - i), UInt8(i * 7 & 0xFF), 255] }
    var seed: UInt32 = 1
    let indices = (0 ..< 6000).map { _ in
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return UInt8(seed >> 24)
    }
    let sheet = try FrameSheet(gif: gif(100, 60, palette: palette, [Frame(width: 100, height: 60, indices: indices)]), frames: .count(1))
    #expect(sheet.rgba == indices.flatMap { palette[Int($0)] })
  }

  @Test func aGIFFromAnotherEncoderDecodesExactly() throws {
    let colors = (0 ..< 32).map { (i: Int) -> Pixel in [UInt8(i * 8), UInt8(255 - i * 8), UInt8(i * 37 % 256), 255] }
    let sheet = try FrameSheet(gif: Data(base64Encoded: pillowGIF)!, frames: .indices([0, 1]))
    #expect(sheet.size == [40, 12])
    #expect(sheet.shown == [[0, 0], [1, 50]])
    func color(_ x: Int, _ y: Int, _ frame: Int) -> Pixel { colors[(x * x * 3 + y * 7 + x * y + frame * 11) % 32] }
    let expected: [UInt8] = (0 ..< 12).flatMap { y in [0, 1].flatMap { frame in (0 ..< 20).flatMap { x in color(x, y, frame) } } }
    #expect(sheet.rgba == expected)
  }

  @Test func aSheetWiderThan2000PixelsShrinksAveragingOnlyWhatIsOpaque() throws {
    let stripes = Frame(width: 1500, height: 4, indices: (0 ..< 6000).map { $0 % 2 == 0 ? 1 : 2 }, transparent: 2)
    let sheet = try FrameSheet(gif: gif(1500, 4, [.solid(1500, 4, 0, disposal: 2), stripes]), frames: .count(2))
    #expect(sheet.size == [2000, 2])
    #expect([sheet.pixel(999, 1), sheet.pixel(1000, 0), sheet.pixel(1001, 1)] == [red, green, [0, 255, 0, 128]])
  }

  @Test func aGIFOfMoreThanTenThousandFramesIsRefusedByBoth() throws {
    let frames = Array(repeating: Frame.solid(1, 1, 0), count: 10000)
    #expect(try ImageInfo(gif(1, 1, frames))?.frames == 10000)
    let longer = gif(1, 1, frames + [.solid(1, 1, 1)])
    let refusals = [
      #expect(throws: CapabilityError.self) { try ImageInfo(longer) },
      #expect(throws: CapabilityError.self) { try FrameSheet(gif: longer, frames: .count(1)) },
    ]
    #expect(refusals.map { $0?.message } == Array(repeating: "Image capabilities read a GIF of at most 10000 frames.", count: 2))
  }

  @Test func whatIsNotAGIFOrAskedOutOfBoundsIsRefusedBeforeDecoding() {
    let three = gif(1, 1, [.solid(1, 1, 0), .solid(1, 1, 1), .solid(1, 1, 2)])
    let refusals: [(Data, FrameSelection)] = [
      (Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgZGIGAAAOAAfXb+R4AAAAAElFTkSuQmCC")!, .count(1)),
      (three.dropLast(), .count(1)), (three, .indices([])), (three, .indices([3])), (three, .indices([-1])), (three, .count(0)), (three, .count(101)),
      (three, .indices(Array(repeating: 0, count: 101))), (gif(10000, 5000, [.solid(1, 1, 0)]), .count(1)),
    ]
    for (data, selection) in refusals {
      let error = #expect(throws: CapabilityError.self) { try FrameSheet(gif: data, frames: selection) }
      #expect(error?.code == .invalidArgument)
    }
  }
}

// Written by Pillow 12.3 from 20×12 frames whose pixel (x, y) in frame f is color (x²·3 + 7y + xy + 11f) mod 32, shown 50 and 120 ms.
private let pillowGIF = "R0lGODlhFAAMAIQAAAD/AAj3JRDvShjnbyDflCjXuTDP3jjHA0C/KEi3TVCvclinl2CfvGiX4XCPBniHK4B/UIh3dZBvmphnv6Bf5KhXCbBPLrhHU8A/eMg3ndAvwtgn5+AfDOgXMfAPVvgHeyH/C05FVFNDQVBFMi4wAwEAAAAh+QQEBQAAACwAAAAAFAAMAAAI/wABDGCwAcICBhMATGCwAMIGBgMEEjywoEKBDRcyBHgwoEOHAQ8CZLiwoUAFBxM8PDAwwMADDxMcPLAwwMIDlCorbDiQIcKDCR0aDPgQIMGFBQUKLLiQgMMACAM4bACwgMMECBM4LACwwSnUAQsyNDhwoEGGBQMCFHjwoUKECRsSdFAwQcAFCRM0HNAwQcIFARMUHKBrN8KGBQE6fDhQIcGAAQkqHPjQIcCCDREwDKCwAMECCgMwTKCwAcEGChM0c/6woEOFCRcCRDgwoECDDQ8SJHiwoUEBAxMMfPAwwMEHCxMsfHAwwMMH4MJv597du8CAAxECXJhQocOCDxkCAgAh+QQEDAAAACwAAAAAFAAMAIQA/wAI9yUQ70oY528g35Qo17kwz944xwNAvyhIt01Qr3JYp5dgn7xol+FwjwZ4hyuAf1CId3WQb5qYZ7+gX+SoVwmwTy64R1PAP3jIN53QL8LYJ+fgHwzoFzHwD1b4B3sI/wAXOLhgYIOFCx4WeLhgYYOBCw4EEpRgAQAEAwIIMNDgAAECBxoYEBBgAAKADB4SaIjgIIKGBB4yaAjgIIAGlCoBGJBAgIMGDwgwOFDAgIIACxAgWBBA4YCDDQ4OGFhg4YCHDR4OWFhgwClUBxYIYJAgAQMBCw4YQNCgAAAHDwYoIKjgoYGADh4KSCjgoYOABh4qSKBrl4MBCwwQKJAAgIIDBxQASFCAgIEFAxwGOPhgYYKFDw4GePhgYIKBDx40c1ZgAQEADwIYcJDgAAIGAxooUNBgAAOECB4iKEjgIIOCAB4CKMjgIIEC4MJv597dG4IDCRwYCPAAAIEFBQQCAgA7"
