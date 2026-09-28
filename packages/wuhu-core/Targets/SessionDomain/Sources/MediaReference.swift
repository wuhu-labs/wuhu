import Foundation

// A media block in the transcript names its bytes; it never carries them. The
// URL is opaque to the provider dialects — anything that is not already
// requestable goes through the injected resolver, which is what keeps the
// bytes out of the transcript and out of every request we build until the
// moment one is built.
public enum MediaReference: Hashable, Sendable {
  case blob(String)
  case spaceFile(String)

  static let blobPrefix = "wuhu-blob:"
  static let spacePrefix = "wuhu-space:"

  public var url: URL {
    switch self {
    case let .blob(hash):
      URL(string: Self.blobPrefix + hash)!
    case let .spaceFile(path):
      URL(string: Self.spacePrefix + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
    }
  }

  public init?(_ url: URL) {
    let text = url.absoluteString
    if text.hasPrefix(Self.blobPrefix) {
      self = .blob(String(text.dropFirst(Self.blobPrefix.count)))
    } else if text.hasPrefix(Self.spacePrefix) {
      let encoded = String(text.dropFirst(Self.spacePrefix.count))
      self = .spaceFile(encoded.removingPercentEncoding ?? encoded)
    } else {
      return nil
    }
  }
}
