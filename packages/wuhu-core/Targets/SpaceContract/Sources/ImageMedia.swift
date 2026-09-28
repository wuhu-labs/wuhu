public enum ImageMedia {
  // The most a message delivers to a model as an image block; a bigger image
  // attachment becomes a line the model can read.
  public static let maxBytes: Int = 3 << 20

  public static let maxReadBytes: Int = 50 << 20

  public static func mimeType(ofPath path: String) -> String? {
    let type = MediaType.of(path: path)
    return types.contains(type) ? type : nil
  }

  // The extension only proposes a type; a provider rejects the whole request
  // when the bytes disagree, parking the session on every turn.
  public static func mimeType(ofBytes data: some Collection<UInt8>) -> String? {
    let head = Array(data.prefix(12))
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
    if head.count >= 12, head.starts(with: Array("RIFF".utf8)), Array(head[8 ..< 12]) == Array("WEBP".utf8) {
      return "image/webp"
    }
    return nil
  }

  // Read from the header alone, so it holds on a server with no image codec.
  public static func pixelSize(ofBytes data: some Collection<UInt8>) -> PixelSize? {
    let bytes = Array(data.prefix(1 << 18))
    let size: PixelSize? = switch mimeType(ofBytes: bytes) {
    case "image/png": bytes.count >= 24 ? PixelSize(width: bytes.bigEndian32(16), height: bytes.bigEndian32(20)) : nil
    case "image/gif": bytes.count >= 10 ? PixelSize(width: bytes.littleEndian(6, 2), height: bytes.littleEndian(8, 2)) : nil
    case "image/jpeg": jpegSize(bytes)
    case "image/webp": webpSize(bytes)
    default: nil
    }
    return size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
  }

  private static let types: Set = ["image/png", "image/jpeg", "image/gif", "image/webp"]

  private static func jpegSize(_ bytes: [UInt8]) -> PixelSize? {
    var index = 2
    while index + 9 < bytes.count {
      guard bytes[index] == 0xFF else { return nil }
      let marker = bytes[index + 1]
      if marker == 0xFF {
        index += 1
      } else if marker == 0x01 || (0xD0 ... 0xD8).contains(marker) {
        index += 2
      } else if (0xC0 ... 0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
        return PixelSize(width: bytes.bigEndian16(index + 7), height: bytes.bigEndian16(index + 5))
      } else {
        index += 2 + bytes.bigEndian16(index + 2)
      }
    }
    return nil
  }

  private static func webpSize(_ bytes: [UInt8]) -> PixelSize? {
    guard bytes.count >= 30 else { return nil }
    switch String(decoding: bytes[12 ..< 16], as: UTF8.self) {
    case "VP8 ":
      return PixelSize(width: bytes.littleEndian(26, 2) & 0x3FFF, height: bytes.littleEndian(28, 2) & 0x3FFF)
    case "VP8L":
      let bits = bytes.littleEndian(21, 4)
      return PixelSize(width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1)
    case "VP8X":
      return PixelSize(width: bytes.littleEndian(24, 3) + 1, height: bytes.littleEndian(27, 3) + 1)
    default:
      return nil
    }
  }
}

public struct PixelSize: Hashable, Sendable, Codable {
  public var width: Int
  public var height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public var longEdge: Int {
    max(width, height)
  }
}

extension [UInt8] {
  fileprivate func bigEndian16(_ offset: Int) -> Int {
    Int(self[offset]) << 8 | Int(self[offset + 1])
  }

  fileprivate func bigEndian32(_ offset: Int) -> Int {
    bigEndian16(offset) << 16 | bigEndian16(offset + 2)
  }

  fileprivate func littleEndian(_ offset: Int, _ count: Int) -> Int {
    (0 ..< count).reduce(0) { value, index in value | Int(self[offset + index]) << (8 * index) }
  }
}
