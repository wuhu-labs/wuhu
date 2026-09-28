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
  // An image already within the limits goes out byte for byte. Past them it is
  // scaled where the platform has an image codec (ImageIO), and replaced by a
  // line saying so where it has none.
  public static func fit(_ data: Data, mimeType: String, limits: ImageLimits) -> FittedImage {
    let size = ImageMedia.pixelSize(ofBytes: data)
    if let size, data.count <= limits.maxBytes, limits.fitted(size) == size {
      return .image(data, mimeType: mimeType)
    }
    #if canImport(ImageIO)
      if let scaled = scaled(data, limits: limits) { return scaled }
    #endif
    // Bytes no codec here can size are left for the provider to judge.
    if size == nil, data.count <= limits.maxBytes { return .image(data, mimeType: mimeType) }
    let shape = size.map { "\($0.width)x\($0.height) px, " } ?? ""
    return .note(
      "[image not sent: at \(shape)\(data.count) bytes it is past what this model takes (\(limits.maxLongEdge) px on the long edge, \(limits.maxBytes) bytes), and this server could not scale it]",
    )
  }
}

#if canImport(ImageIO)
  extension ImageFitting {
    private static func scaled(_ data: Data, limits: ImageLimits) -> FittedImage? {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
        // At the original size a PNG re-encode would come out as big as the
        // bytes that were already too many.
        let formats = size == PixelSize(width: width, height: height)
          ? [("public.jpeg", "image/jpeg")]
          : [("public.png", "image/png"), ("public.jpeg", "image/jpeg")]
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
