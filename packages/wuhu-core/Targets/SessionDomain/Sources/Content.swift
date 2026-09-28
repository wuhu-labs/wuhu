import Foundation
import enum SpaceContract.ImageMedia
import struct SpaceContract.PixelSize

// An image is a png, jpeg, gif or webp whose bytes match its type, at any size;
// whether a model takes it inline is decided at delivery, not at rest. Rows
// written before sizes were recorded carry no size and were all under the
// model limit; rows written before pixel sizes were recorded carry none.
public enum Attachment: Hashable, Sendable, Codable {
  case image(path: String, mimeType: String, size: Int?, pixels: PixelSize? = nil)
  case file(path: String, mimeType: String, size: Int)

  public var path: String {
    switch self {
    case let .image(path, _, _, _), let .file(path, _, _): path
    }
  }

  public var mimeType: String {
    switch self {
    case let .image(_, mimeType, _, _), let .file(_, mimeType, _): mimeType
    }
  }

  var size: Int? {
    switch self {
    case let .image(_, _, size, _): size
    case let .file(_, _, size): size
    }
  }

  var pixels: PixelSize? {
    guard case let .image(_, _, _, pixels) = self else { return nil }
    return pixels
  }

  var isModelImage: Bool {
    guard case let .image(_, _, size, _) = self else { return false }
    return (size ?? 0) <= ImageMedia.maxBytes
  }

  private enum Kind: String, Codable {
    case image
    case file
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case path
    case mimeType
    case size
    case width
    case height
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let path = try container.decode(String.self, forKey: .path)
    let mimeType = try container.decode(String.self, forKey: .mimeType)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .image:
      self = .image(
        path: path,
        mimeType: mimeType,
        size: try container.decodeIfPresent(Int.self, forKey: .size),
        pixels: try PixelSize(container, width: .width, height: .height),
      )
    case .file:
      self = .file(path: path, mimeType: mimeType, size: try container.decode(Int.self, forKey: .size))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .image: try container.encode(Kind.image, forKey: .kind)
    case .file: try container.encode(Kind.file, forKey: .kind)
    }
    try container.encode(path, forKey: .path)
    try container.encode(mimeType, forKey: .mimeType)
    try container.encodeIfPresent(size, forKey: .size)
    try container.encodeIfPresent(pixels?.width, forKey: .width)
    try container.encodeIfPresent(pixels?.height, forKey: .height)
  }
}

public enum MessageKind: String, Hashable, Sendable, Codable {
  case message
  case request
  case progress
  case final
}

public struct MessageContent: Hashable, Sendable, Codable {
  public var text: String
  public var attachments: [Attachment]

  public init(text: String, attachments: [Attachment] = []) {
    self.text = text
    self.attachments = attachments
  }

  public var modelImages: [Attachment] {
    attachments.filter(\.isModelImage)
  }
}

public struct Sender: Hashable, Sendable, Codable {
  public var id: String
  public var timeZone: TimeZone
  // The device the person spoke from, derived server-side from the request
  // credential. Never a body field: a client cannot claim one.
  public var device: String?

  public init(id: String, timeZone: TimeZone, device: String? = nil) {
    self.id = id
    self.timeZone = timeZone
    self.device = device
  }
}
