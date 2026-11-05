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

/// A PNG, JPEG, GIF or WebP read back from its bytes. A still image is one frame with no delays;
/// a GIF's delays are how long a browser shows each frame. A GIF over `GIF.maxFrames` is refused.
public struct ImageInfo: Equatable, Sendable {
  public let mimeType: String
  public let bytes: Int
  public let width: Int
  public let height: Int
  public let delaysMs: [Int]

  public var frames: Int { max(1, delaysMs.count) }
  public var durationMs: Int { delaysMs.reduce(0, +) }

  public init?(_ data: Data) throws(CapabilityError) {
    let bytes = [UInt8](data)
    guard let size = ImageMedia.pixelSize(ofBytes: bytes), let mimeType = ImageMedia.mimeType(ofBytes: bytes) else { return nil }
    switch mimeType {
    case ImageFormat.png.mimeType:
      guard bytes[12 ..< 16].elementsEqual(Array("IHDR".utf8)) else { return nil }
      delaysMs = []
    case ImageFormat.gif.mimeType:
      guard let gif = try GIF(bytes) else { return nil }
      delaysMs = gif.frames.map(\.delayMs)
    default:
      delaysMs = []
    }
    (self.mimeType, self.bytes, width, height) = (mimeType, bytes.count, size.width, size.height)
  }

  /// What a provider returned, which must be a whole `format` image.
  public static func returned(_ data: Data, as format: ImageFormat) throws(CapabilityError) -> ImageInfo {
    guard let info = try ImageInfo(data), info.mimeType == format.mimeType else {
      throw CapabilityError(.providerUnavailable, "The provider returned an image that is not a \(format.rawValue.uppercased()).")
    }
    return info
  }

  /// `generateImage`'s answer for this image written at `path`.
  public func answer(path: String) -> JSONValue {
    var answer: OrderedDictionary<String, JSONValue> = ["path": .string(path), "mimeType": .string(mimeType), "bytes": .integer(bytes), "width": .integer(width), "height": .integer(height)]
    if mimeType == ImageFormat.gif.mimeType { (answer["frames"], answer["durationMs"]) = (.integer(frames), .integer(durationMs)) }
    return .object(answer)
  }

  /// `inspectImage`'s answer.
  public var inspection: JSONValue {
    .object([
      "mimeType": .string(mimeType), "bytes": .integer(bytes), "width": .integer(width), "height": .integer(height),
      "frames": .integer(frames), "durationMs": .integer(durationMs), "delaysMs": .array(delaysMs.map(JSONValue.integer)),
    ])
  }
}
