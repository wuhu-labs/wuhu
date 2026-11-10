#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif
import struct SessionDomain.ImageLimits
import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize

public enum FittedImage: Hashable, Sendable {
  case image(Data, mimeType: String)
  case note(String)
}

public enum ImageFitting {
  /// The copy a transcript keeps. A PNG or JPEG is always re-encoded, so nothing of the source
  /// but its pixels survives; any other format is only fitted.
  public static func prepare(_ data: Data, mimeType: String, limits: ImageLimits = .intake) -> FittedImage {
    guard ["image/png", "image/jpeg"].contains(ImageMedia.mimeType(ofBytes: data)) else {
      return fit(data, mimeType: mimeType, limits: limits)
    }
    let size = ImageMedia.pixelSize(ofBytes: data)
    guard !absurd(size) else { return refusal(data, size: size, limits: limits) }
    #if canImport(ImageIO) || os(Linux)
      return scaled(data, limits: limits) ?? refusal(data, size: size, limits: limits)
    #else
      return fit(data, mimeType: mimeType, limits: limits)
    #endif
  }

  public static func fit(_ data: Data, mimeType: String, limits: ImageLimits = .intake) -> FittedImage {
    let size = ImageMedia.pixelSize(ofBytes: data)
    guard !absurd(size) else { return refusal(data, size: size, limits: limits) }
    if let size, data.count <= limits.maxBytes, limits.fitted(size) == size {
      return .image(data, mimeType: mimeType)
    }
    #if canImport(ImageIO) || os(Linux)
      if let scaled = scaled(data, limits: limits) { return scaled }
    #endif
    // Bytes no codec here can size are left for the provider to judge.
    if size == nil, data.count <= limits.maxBytes { return .image(data, mimeType: mimeType) }
    return refusal(data, size: size, limits: limits)
  }

  private static func absurd(_ size: PixelSize?) -> Bool {
    guard let size else { return false }
    return size.width > Int32.max || size.height > Int32.max || size.width.multipliedReportingOverflow(by: size.height).overflow
  }

  /// Whether a codec here decodes every pixel of `data`: `fit` hands back an image already within
  /// the limits without decoding it. Nil for a format this server has no codec for.
  public static func decodes(_ data: Data) -> Bool? {
    #if canImport(ImageIO)
      guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
      else { return false }
      return image.dataProvider?.data != nil
    #elseif os(Linux)
      guard ["image/png", "image/jpeg"].contains(ImageMedia.mimeType(ofBytes: data)) else { return nil }
      return LinuxImage(data) != nil
    #else
      return nil
    #endif
  }

  /// Unpremultiplied RGBA8 rows as a PNG; nil where this server has no PNG encoder.
  public static func png(rgba: [UInt8], size: PixelSize) -> Data? {
    precondition(rgba.count == size.width * size.height * 4)
    #if canImport(ImageIO)
      guard let provider = CGDataProvider(data: Data(rgba) as CFData),
            let image = CGImage(
              width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
            )
      else { return nil }
      return encode(image, as: "public.png")
    #elseif os(Linux)
      return LinuxImage(pixels: rgba, size: size, isPNG: true).encoded(png: true)
    #else
      return nil
    #endif
  }

  private static func refusal(_ data: Data, size: PixelSize?, limits: ImageLimits) -> FittedImage {
    let shape = size.map { "\($0.width)x\($0.height) px, " } ?? ""
    return .note(
      "[image not sent: at \(shape)\(data.count) bytes it is past what a transcript keeps (\(limits.maxLongEdge) px on the long edge, \(limits.maxBytes) bytes), and this server could not re-encode it]",
    )
  }
}

#if canImport(ImageIO)
  extension ImageFitting {
    private static func scaled(_ data: Data, limits: ImageLimits) -> FittedImage? {
      // A thumbnail of truncated bytes renders what arrived; Linux refuses them.
      guard decodes(data) == true, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
      else { return nil }
      var longEdge = limits.fitted(PixelSize(width: width, height: height)).longEdge
      while longEdge >= 1 {
        guard let image = thumbnail(source, longEdge: longEdge) else { return nil }
        let size = PixelSize(width: image.width, height: image.height)
        guard limits.fitted(size) == size else {
          longEdge -= 1
          continue
        }
        let formats = ImageMedia.mimeType(ofBytes: data) == "image/png"
          ? [("public.png", "image/png"), ("public.jpeg", "image/jpeg")]
          : [("public.jpeg", "image/jpeg")]
        for (type, mimeType) in formats {
          if let encoded = encode(image, as: type), encoded.count <= limits.maxBytes {
            return .image(encoded, mimeType: mimeType)
          }
        }
        longEdge = longEdge * 3 / 4
      }
      return nil
    }

    private static func thumbnail(_ source: CGImageSource, longEdge: Int) -> CGImage? {
      CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: longEdge,
      ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: String) -> Data? {
      let output = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else {
        return nil
      }
      CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    }
  }
#endif

#if os(Linux)
  extension ImageFitting {
    private static func scaled(_ data: Data, limits: ImageLimits) -> FittedImage? {
      guard let original = LinuxImage(data) else { return nil }
      var size = limits.fitted(original.size)
      while size.width > 0, size.height > 0 {
        let image = original.resized(to: size)
        if original.isPNG, let encoded = image.encoded(png: true), encoded.count <= limits.maxBytes {
          return .image(encoded, mimeType: "image/png")
        }
        for quality in [85, 70, 55, 40, 25] {
          if let encoded = image.encoded(png: false, quality: quality), encoded.count <= limits.maxBytes {
            return .image(encoded, mimeType: "image/jpeg")
          }
        }
        if size.longEdge == 1 { break }
        let longEdge = max(1, size.longEdge * 3 / 4)
        let scale = Double(longEdge) / Double(original.size.longEdge)
        size = limits.fitted(PixelSize(
          width: max(1, Int(Double(original.size.width) * scale)),
          height: max(1, Int(Double(original.size.height) * scale)),
        ))
      }
      return nil
    }
  }
#endif
