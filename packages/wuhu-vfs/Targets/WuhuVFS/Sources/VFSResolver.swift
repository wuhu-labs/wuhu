/// Resolves a URL authority (`scheme://host`) to a virtual filesystem.
public struct VFSResolver: Sendable {
  public let resolve: @Sendable (_ scheme: String, _ host: String) async throws -> any VirtualFileSystem

  public init(
    resolve: @escaping @Sendable (_ scheme: String, _ host: String) async throws -> any VirtualFileSystem,
  ) {
    self.resolve = resolve
  }

  /// Wrap this resolver with middleware that can observe or replace resolution.
  public func middleware(
    _ transform: @escaping @Sendable (
      _ scheme: String,
      _ host: String,
      _ next: @Sendable (_ scheme: String, _ host: String) async throws -> any VirtualFileSystem,
    ) async throws -> any VirtualFileSystem,
  ) -> VFSResolver {
    VFSResolver { scheme, host in
      try await transform(scheme, host, resolve)
    }
  }

  /// A resolver with no registered filesystems.
  public static let empty: Self = VFSResolver { scheme, host in
    throw VFSResolverError.notFound(scheme: scheme, host: host)
  }

  /// A resolver backed by a fixed set of `(scheme, host, filesystem)` entries.
  public static func constant(_ filesystems: some Sequence<(String, String, any VirtualFileSystem)>) -> VFSResolver {
    let table = Dictionary(uniqueKeysWithValues: filesystems.map { scheme, host, filesystem in
      (VFSResolverKey(scheme: scheme, host: host), filesystem)
    })
    return VFSResolver { scheme, host in
      guard let filesystem = table[VFSResolverKey(scheme: scheme, host: host)] else {
        throw VFSResolverError.notFound(scheme: scheme, host: host)
      }
      return filesystem
    }
  }
}

public enum VFSResolverError: Error, Sendable, Hashable, CustomStringConvertible {
  case notFound(scheme: String, host: String)

  public var description: String {
    switch self {
    case let .notFound(scheme, host):
      "No virtual filesystem registered for \(scheme)://\(host)"
    }
  }
}

private struct VFSResolverKey: Hashable {
  var scheme: String
  var host: String
}
