import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize

// What one model takes as an image. A bigger one is scaled down when the
// request is built, so the context estimate counts the size actually sent.
public struct ImageLimits: Hashable, Sendable {
  public var maxLongEdge: Int
  public var patch: Int
  public var maxPatches: Int
  public var tokensPerPatch: Double
  public var maxBytes: Int
  public var crowding: Crowding?
  // Every image in the transcript is re-sent on every call, so all of them
  // together share what one request may carry: base64 grows them by a third
  // and the text needs room too.
  public var requestBytes: Int?

  public struct Crowding: Hashable, Sendable {
    public var imageCount: Int
    public var maxLongEdge: Int
  }

  public init(maxLongEdge: Int, patch: Int, maxPatches: Int, tokensPerPatch: Double, maxBytes: Int, crowding: Crowding? = nil, requestBytes: Int? = nil) {
    self.maxLongEdge = maxLongEdge
    self.patch = patch
    self.maxPatches = maxPatches
    self.tokensPerPatch = tokensPerPatch
    self.maxBytes = maxBytes
    self.crowding = crowding
    self.requestBytes = requestBytes
  }

  // Claude refuses a request carrying more than 20 images once any of them
  // exceeds 2000 px, and any request over 32 MB.
  public static let claude: ImageLimits = ImageLimits(
    maxLongEdge: 2576,
    patch: 28,
    maxPatches: 4784,
    tokensPerPatch: 1,
    maxBytes: ImageMedia.maxBytes,
    crowding: Crowding(imageCount: 20, maxLongEdge: 2000),
    requestBytes: 18 << 20,
  )

  // With detail "original" OpenAI keeps an image's size and refuses one over
  // 30,000 patches instead of scaling it, and any request over 50 MB.
  public static let openAI: ImageLimits = ImageLimits(
    maxLongEdge: 65535,
    patch: 32,
    maxPatches: 30000,
    tokensPerPatch: 1.2,
    maxBytes: 20 << 20,
    requestBytes: 30 << 20,
  )

  public func forRequest(imageCount: Int) -> ImageLimits {
    var limits = self
    if let crowding, imageCount > crowding.imageCount {
      limits.maxLongEdge = min(maxLongEdge, crowding.maxLongEdge)
    }
    if let requestBytes, imageCount > 0 {
      // Each change of the share can re-encode images already sent and break
      // the prompt cache from there on, so it only steps at powers of two.
      let shares = 1 << (Int.bitWidth - (imageCount - 1).leadingZeroBitCount)
      limits.maxBytes = min(maxBytes, requestBytes / shares)
    }
    limits.crowding = nil
    limits.requestBytes = nil
    return limits
  }

  public func fitted(_ size: PixelSize) -> PixelSize {
    guard size.width > 0, size.height > 0 else { return size }
    let byEdge = Double(maxLongEdge) / Double(size.longEdge)
    let byArea = (Double(maxPatches * patch * patch) / Double(size.width * size.height)).squareRoot()
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
