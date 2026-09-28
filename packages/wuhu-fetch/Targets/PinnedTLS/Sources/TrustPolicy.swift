import NIOSSL

public enum TrustPolicy: Sendable, Equatable {
  case system
  case pinned(fingerprint: String)
}

public enum TrustAnchors: Sendable, Equatable {
  case platformDefault
  case certificates([[UInt8]])
}

extension TrustAnchors {
  public func clientConfiguration() -> TLSConfiguration {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.trustRoots = self.trustRoots()
    return configuration
  }

  private func trustRoots() -> NIOSSLTrustRoots {
    switch self {
    case .platformDefault:
      // On Darwin NIOSSL's .default delegates verification to
      // Security.framework (SecTrust with hostname policy), so platform trust
      // includes the keychain: user-installed CAs and trust settings. On
      // Linux it loads the distro CA bundle.
      .default
    case .certificates(let anchors):
      // A keychain export can contain certificates BoringSSL cannot parse;
      // one unparseable anchor must not take down every dial.
      .certificates(anchors.compactMap { try? NIOSSLCertificate(bytes: $0, format: .der) })
    }
  }
}
