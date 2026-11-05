#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import JSONValue
import OrderedCollections
import enum SpaceContract.ImageMedia

/// What an image capability writes, named by its destination's extension.
public enum ImageFormat: String, Sendable, Codable, Hashable {
  case png, gif

  public init(destination: String) throws(CapabilityError) {
    let name = destination.split(separator: "/").last ?? ""
    switch name.contains(".") ? name.split(separator: ".").last?.lowercased() : nil {
    case "gif": self = .gif
    case "svg": throw CapabilityError(.unsupportedFeature, "Image capabilities write PNG or GIF, not SVG.", hint: "Write SVG markup yourself with write.")
    default: self = .png
    }
  }

  public var mimeType: String { "image/\(rawValue)" }
}

/// A PNG or GIF read back from its bytes; a still PNG is one frame of no duration.
public struct ImageInfo: Equatable, Sendable {
  public let format: ImageFormat
  public let bytes: Int
  public let width: Int
  public let height: Int
  public let frames: Int
  public let durationMs: Int

  public init?(_ data: Data) {
    let bytes = [UInt8](data)
    guard let size = ImageMedia.pixelSize(ofBytes: bytes) else { return nil }
    switch ImageMedia.mimeType(ofBytes: bytes) {
    case "image/png":
      guard bytes[12 ..< 16].elementsEqual(Array("IHDR".utf8)) else { return nil }
      (format, frames, durationMs) = (.png, 1, 0)
    case "image/gif":
      guard let animation = Self.gifFrames(bytes) else { return nil }
      (format, frames, durationMs) = (.gif, animation.frames, animation.durationMs)
    default: return nil
    }
    (self.bytes, width, height) = (bytes.count, size.width, size.height)
  }

  /// What a provider returned, which must be a whole `format` image.
  public static func returned(_ data: Data, as format: ImageFormat) throws(CapabilityError) -> ImageInfo {
    guard let info = ImageInfo(data), info.format == format else {
      throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a \(format.rawValue.uppercased()).")
    }
    return info
  }

  /// `generateImage`'s answer for this image written at `path`.
  public func answer(path: String) -> JSONValue {
    var answer: OrderedDictionary<String, JSONValue> = ["path": .string(path), "mimeType": .string(format.mimeType), "bytes": .integer(bytes), "width": .integer(width), "height": .integer(height)]
    if format == .gif { (answer["frames"], answer["durationMs"]) = (.integer(frames), .integer(durationMs)) }
    return .object(answer)
  }

  // A GIF89a block walk: each image descriptor is a frame, and the graphic control extension before
  // it holds that frame's delay in hundredths of a second. A stream without its trailer is no GIF.
  private static func gifFrames(_ bytes: [UInt8]) -> (frames: Int, durationMs: Int)? {
    guard bytes.count > 13 else { return nil }
    var index = 13
    if bytes[10] & 0x80 != 0 { index += 3 << (Int(bytes[10] & 7) + 1) }
    var (frames, centiseconds, delay) = (0, 0, 0)
    func skipSubBlocks() -> Bool {
      while index < bytes.count {
        let length = Int(bytes[index])
        index += 1 + length
        if length == 0 { return true }
      }
      return false
    }
    while index < bytes.count {
      switch bytes[index] {
      case 0x21:
        guard index + 2 < bytes.count else { return nil }
        if bytes[index + 1] == 0xF9, bytes[index + 2] == 4, index + 5 < bytes.count {
          delay = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8
        }
        index += 2
        guard skipSubBlocks() else { return nil }
      case 0x2C:
        guard index + 9 < bytes.count else { return nil }
        let packed = bytes[index + 9]
        index += 11
        if packed & 0x80 != 0 { index += 3 << (Int(packed & 7) + 1) }
        guard skipSubBlocks() else { return nil }
        (frames, centiseconds, delay) = (frames + 1, centiseconds + delay, 0)
      case 0x3B:
        return frames > 0 ? (frames, centiseconds * 10) : nil
      default:
        return nil
      }
    }
    return nil
  }
}
