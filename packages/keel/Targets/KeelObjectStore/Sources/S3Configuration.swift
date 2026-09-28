#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct S3Configuration: Sendable {
  public enum Addressing: Sendable, Hashable {
    case virtualHost
    case pathStyle
  }

  public var endpoint: URL
  public var region: String
  public var bucket: String
  public var addressing: Addressing
  public var credentials: SigV4Credentials

  public init(
    endpoint: URL,
    region: String,
    bucket: String,
    addressing: Addressing,
    credentials: SigV4Credentials,
  ) {
    self.endpoint = endpoint
    self.region = region
    self.bucket = bucket
    self.addressing = addressing
    self.credentials = credentials
  }
}

extension S3Configuration {
  var scheme: String { self.endpoint.scheme ?? "https" }

  // Host header value the transport will send: the endpoint host, plus the port
  // only when it is non-default for the scheme (matching AsyncHTTPClient), plus
  // the bucket label for virtual-host addressing.
  func host() -> String {
    let base = self.endpoint.host ?? ""
    let port = self.endpoint.port
    let defaultPort = self.scheme == "https" ? 443 : 80
    let authority = (port != nil && port != defaultPort) ? "\(base):\(port!)" : base
    switch self.addressing {
    case .virtualHost:
      return "\(self.bucket).\(authority)"
    case .pathStyle:
      return authority
    }
  }

  func rawKeyPath(_ key: ObjectKey) -> String {
    switch self.addressing {
    case .virtualHost:
      return "/" + key.raw
    case .pathStyle:
      return "/" + self.bucket + "/" + key.raw
    }
  }

  func rawListPath() -> String {
    switch self.addressing {
    case .virtualHost:
      return "/"
    case .pathStyle:
      return "/" + self.bucket
    }
  }

  // `canonicalURI` is the already-percent-encoded path; the sent URL must match
  // the signed canonical URI byte for byte.
  func url(canonicalURI: String, canonicalQuery: String) -> URL? {
    var string = "\(self.scheme)://\(self.host())\(canonicalURI)"
    if !canonicalQuery.isEmpty {
      string += "?\(canonicalQuery)"
    }
    return URL(string: string)
  }
}
