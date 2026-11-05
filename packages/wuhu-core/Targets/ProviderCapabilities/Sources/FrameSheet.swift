#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue

/// Which frames of a GIF a `FrameSheet` shows: these indices, or a count spaced evenly in time.
public enum FrameSelection: Sendable, Hashable {
  case indices([Int])
  case count(Int)
}

/// Frames of a GIF as a browser shows them at that moment, tiled ⌈√k⌉ columns wide, left to right
/// and top to bottom, long edge at most 2000 px, as RGBA. A count that lands on one frame twice
/// shows it once.
public struct FrameSheet: Sendable {
  public struct Shown: Hashable, Sendable {
    public let index: Int
    public let atMs: Int
  }

  public let width: Int
  public let height: Int
  public let rgba: [UInt8]
  public let frames: [Shown]

  static let maxPixels = 40_000_000
  static let maxDecodedPixels = 10 * maxPixels
  static let maxShown = 100
  static let maxLongEdge = 2000

  public init(gif data: Data, frames selection: FrameSelection) throws(CapabilityError) {
    guard let gif = try GIF([UInt8](data)) else {
      throw CapabilityError(.invalidArgument, "renderFrames reads a GIF; this file is not one.", hint: "read a still image directly.")
    }
    let bound = CapabilityError(.invalidArgument, "renderFrames decodes at most \(Self.maxPixels) pixels a frame and \(Self.maxDecodedPixels) pixels in all.", hint: "Render a GIF this large on a machine.")
    guard gif.width * gif.height <= Self.maxPixels else { throw bound }
    let starts = gif.frames.reduce(into: [0]) { $0.append($0.last! + $1.delayMs) }
    let shown = try Self.pick(selection, count: gif.frames.count, starts: starts)
    let last = shown.max()!
    guard gif.frames.prefix(last + 1).reduce(0, { $0 + $1.width * $1.height }) <= Self.maxDecodedPixels else { throw bound }

    let columns = (1...).first { $0 * $0 >= shown.count }!
    let rows = (shown.count + columns - 1) / columns
    let longEdge = max(columns * gif.width, rows * gif.height)
    func fit(_ side: Int) -> Int { longEdge <= Self.maxLongEdge ? side : max(1, side * Self.maxLongEdge / longEdge) }
    let cell = (width: fit(gif.width), height: fit(gif.height))
    let (width, height) = (columns * cell.width, rows * cell.height)
    let columnSamples = (0 ..< cell.width).map { Self.samples($0, of: cell.width, over: gif.width) }
    let rowSamples = (0 ..< cell.height).map { Self.samples($0, of: cell.height, over: gif.height) }
    let slots = Dictionary(grouping: shown.indices, by: { shown[$0] })
    var sheet = [UInt8](repeating: 0, count: width * height * 4)
    gif.play(through: last) { number, canvas in
      for slot in slots[number] ?? [] {
        let origin = (x: slot % columns * cell.width, y: slot / columns * cell.height)
        for (y, sourceRows) in rowSamples.enumerated() {
          for (x, sourceColumns) in columnSamples.enumerated() {
            var (red, green, blue, alpha) = (0, 0, 0, 0)
            for sourceY in sourceRows {
              for sourceX in sourceColumns {
                let pixel = (sourceY * gif.width + sourceX) * 4
                let weight = Int(canvas[pixel + 3])
                red += Int(canvas[pixel]) * weight
                green += Int(canvas[pixel + 1]) * weight
                blue += Int(canvas[pixel + 2]) * weight
                alpha += weight
              }
            }
            let samples = sourceRows.count * sourceColumns.count
            let output = ((origin.y + y) * width + origin.x + x) * 4
            if alpha > 0 {
              (sheet[output], sheet[output + 1], sheet[output + 2]) = (UInt8((red + alpha / 2) / alpha), UInt8((green + alpha / 2) / alpha), UInt8((blue + alpha / 2) / alpha))
            }
            sheet[output + 3] = UInt8((alpha + samples / 2) / samples)
          }
        }
      }
    }
    (self.width, self.height, rgba) = (width, height, sheet)
    frames = shown.map { Shown(index: $0, atMs: starts[$0]) }
  }

  /// `renderFrames`'s answer for this sheet written at `path` as a PNG.
  public func answer(path: String) -> JSONValue {
    .object([
      "path": .string(path), "width": .integer(width), "height": .integer(height),
      "frames": .array(frames.map { .object(["index": .integer($0.index), "atMs": .integer($0.atMs)]) }),
    ])
  }

  // A count samples the middle of each of `count` equal stretches of the animation's playing time.
  private static func pick(_ selection: FrameSelection, count frames: Int, starts: [Int]) throws(CapabilityError) -> [Int] {
    switch selection {
    case let .indices(indices):
      guard (1 ... maxShown).contains(indices.count), indices.allSatisfy((0 ..< frames).contains) else {
        throw CapabilityError(.invalidArgument, "frames lists 1 to \(maxShown) indices below the GIF's \(frames) frames.", hint: "inspectImage gives the frame count.")
      }
      return indices
    case let .count(count):
      guard (1 ... maxShown).contains(count) else {
        throw CapabilityError(.invalidArgument, "frames is a count from 1 to \(maxShown) or a list of frame indices.", hint: "Leave frames out for 9.")
      }
      var picked: [Int] = []
      for stretch in 0 ..< count {
        let time = (2 * stretch + 1) * starts.last! / (2 * count)
        let frame = starts.lastIndex { $0 <= time }!
        if picked.last != frame { picked.append(frame) }
      }
      return picked
    }
  }

  // Up to four source positions spread over the span that output `index` covers.
  private static func samples(_ index: Int, of output: Int, over input: Int) -> [Int] {
    let start = index * input / output, end = max(start + 1, (index + 1) * input / output)
    let count = min(4, end - start)
    return (0 ..< count).map { start + (end - start) * (2 * $0 + 1) / (2 * count) }
  }
}
