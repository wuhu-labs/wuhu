import Foundation

/// An absolute path inside one virtual filesystem.
///
/// Root is represented by an empty component list.
public struct VFSPath: Sendable, Hashable, Codable {
  public static let root: VFSPath = VFSPath(components: [])

  public let components: [VFSPathComponent]

  /// The low-level primitive: build a path from already-validated components.
  public init(components: some Sequence<VFSPathComponent>) {
    self.components = Array(components)
  }

  /// Parse an absolute slash-separated path, e.g. `/docs/notes.txt`.
  public init(absoluteFilePath path: String) throws {
    guard path.hasPrefix("/") else {
      throw VFSPathError.notAbsolute(path)
    }
    guard path == "/" || !path.hasSuffix("/") else {
      throw VFSPathError.trailingSlash(path)
    }
    guard path != "/" else {
      self = .root
      return
    }
    try self.init(validating: path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init))
  }

  /// Take the path portion of a VFS URL, discarding its scheme and host.
  ///
  /// The URL path is read percent-encoded so an encoded slash (`%2F`) stays
  /// distinct from a separator and is rejected as an illegal component, rather
  /// than silently splitting the path.
  public init(strippingSchemeAndHost url: URL) throws {
    let path = url.path(percentEncoded: true)
    guard !path.isEmpty, path != "/" else {
      self = .root
      return
    }
    guard path.hasPrefix("/") else {
      throw VFSPathError.notAbsolute(path)
    }
    guard !path.hasSuffix("/") else {
      throw VFSPathError.trailingSlash(path)
    }
    let decoded = try path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { encoded in
      guard let value = String(encoded).removingPercentEncoding else {
        throw VFSPathError.invalidPercentEncoding(String(encoded))
      }
      return value
    }
    try self.init(validating: decoded)
  }

  private init(validating components: some Sequence<String>) throws {
    var validated: [VFSPathComponent] = []
    for component in components {
      guard let childName = VFSPathComponent(rawValue: component) else {
        throw VFSPathError.invalidComponent(component)
      }
      validated.append(childName)
    }
    self.components = validated
  }

  public func resolving(relativeSlashPath path: String) throws -> VFSPath {
    var components = components
    for component in path.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
      switch component {
      case "", ".":
        continue
      case "..":
        guard !components.isEmpty else {
          throw VFSPathError.pathEscape(path)
        }
        components.removeLast()
      default:
        guard let childName = VFSPathComponent(rawValue: component) else {
          throw VFSPathError.invalidComponent(component)
        }
        components.append(childName)
      }
    }
    return VFSPath(components: components)
  }

  public var parent: VFSPath? {
    guard !components.isEmpty else { return nil }
    return VFSPath(components: components.dropLast())
  }

  public var lastComponent: VFSPathComponent? {
    components.last
  }

  public func appending(_ child: VFSPathComponent) -> VFSPath {
    VFSPath(components: components + [child])
  }

  /// Slash-prefixed diagnostic path, not a URL and not a host filesystem path.
  public var absoluteFilePath: String {
    guard !components.isEmpty else { return "/" }
    return "/" + components.map(\.rawValue).joined(separator: "/")
  }

  /// Reattach a scheme and host to produce a VFS URL.
  public func url(scheme: String, host: String) -> URL {
    URL(string: "\(scheme)://\(host)\(percentEncodedAbsoluteFilePath)")!
  }

  private var percentEncodedAbsoluteFilePath: String {
    guard !components.isEmpty else { return "/" }
    return "/" + components.map { component in
      component.rawValue.addingPercentEncoding(withAllowedCharacters: .vfsPathComponentAllowed)!
    }.joined(separator: "/")
  }
}

public enum VFSPathError: Error, Sendable, Hashable, CustomStringConvertible {
  case invalidComponent(String)
  case invalidPercentEncoding(String)
  case notAbsolute(String)
  case pathEscape(String)
  case trailingSlash(String)

  public var description: String {
    switch self {
    case let .invalidComponent(component):
      "Invalid VFS path component: \(component)"
    case let .invalidPercentEncoding(component):
      "Invalid percent-encoded VFS path component: \(component)"
    case let .notAbsolute(path):
      "VFS path must be absolute: \(path)"
    case let .pathEscape(path):
      "VFS path escapes root: \(path)"
    case let .trailingSlash(path):
      "VFS path must not have a trailing slash: \(path)"
    }
  }
}

private extension CharacterSet {
  static let vfsPathComponentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
}
