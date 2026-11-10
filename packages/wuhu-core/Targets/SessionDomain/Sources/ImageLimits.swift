import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize

// What one model counts an image as. Every image is fitted to `intake` once,
// when it enters a transcript, so the per-model limits only price it.
public struct ImageLimits: Hashable, Sendable, Codable {
  public var maxLongEdge: Int
  public var patch: Int
  public var maxPatches: Int
  public var tokensPerPatch: Double
  public var maxBytes: Int

  public init(maxLongEdge: Int, patch: Int, maxPatches: Int, tokensPerPatch: Double, maxBytes: Int) {
    self.maxLongEdge = maxLongEdge
    self.patch = patch
    self.maxPatches = maxPatches
    self.tokensPerPatch = tokensPerPatch
    self.maxBytes = maxBytes
  }

  // Under every provider's per-image limit at any image count, and under what
  // Claude Code re-encodes by itself, so the bytes a transcript keeps are the
  // bytes every request sends.
  public static let intake: ImageLimits = ImageLimits(
    maxLongEdge: 2000,
    patch: 28,
    maxPatches: 4784,
    tokensPerPatch: 1,
    maxBytes: ImageMedia.maxBytes,
  )

  public static let claude: ImageLimits = ImageLimits(
    maxLongEdge: 2576,
    patch: 28,
    maxPatches: 4784,
    tokensPerPatch: 1,
    maxBytes: ImageMedia.maxBytes,
  )

  public static let openAI: ImageLimits = ImageLimits(
    maxLongEdge: 65535,
    patch: 32,
    maxPatches: 30000,
    tokensPerPatch: 1.2,
    maxBytes: 20 << 20,
  )

  public func fitted(_ size: PixelSize) -> PixelSize {
    guard size.width > 0, size.height > 0 else { return size }
    let byEdge = Double(maxLongEdge) / Double(size.longEdge)
    let byArea = (Double(maxPatches) * Double(patch) * Double(patch) / (Double(size.width) * Double(size.height))).squareRoot()
    var scale = min(1, byEdge, byArea)
    var fit = size.scaled(by: scale)
    while patches(fit) > maxPatches {
      scale *= 0.98
      fit = size.scaled(by: scale)
    }
    return fit
  }

  // A size nobody recorded costs the most one image can.
  public func tokens(_ size: PixelSize?) -> Int {
    let count = size.map { patches(fitted($0)) } ?? maxPatches
    return Int((Double(count) * tokensPerPatch).rounded(.up))
  }

  private func patches(_ size: PixelSize) -> Int {
    ((size.width + patch - 1) / patch) * ((size.height + patch - 1) / patch)
  }
}

extension PixelSize {
  func scaled(by scale: Double) -> PixelSize {
    guard scale < 1 else { return self }
    return PixelSize(
      width: max(1, Int((Double(width) * scale).rounded(.down))),
      height: max(1, Int((Double(height) * scale).rounded(.down))),
    )
  }
}

extension PixelSize {
  init?<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, width: Key, height: Key) throws {
    guard let width = try container.decodeIfPresent(Int.self, forKey: width),
          let height = try container.decodeIfPresent(Int.self, forKey: height)
    else { return nil }
    self.init(width: width, height: height)
  }
}
