import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension ModelsDocument.Provider {
  /// The replay scope a credential epoch has on this provider: a new epoch, or any change to how
  /// the provider is reached, makes opaque blocks from before it portable text.
  public func bindingIdentity(providerID: String, credentialEpoch: String) -> String {
    replayDigest([
      providerID,
      credentialEpoch,
      dialect.rawValue,
      baseURL.absoluteString,
      auth?.rawValue ?? "credential",
      transport?.rawValue ?? "sse",
      originator ?? "wuhu",
      effectiveOpaqueReplay.rawValue,
    ])
  }
}

/// A session's prompt-cache key on one binding and route epoch.
public func replayCacheKey(session: String, bindingIdentity: String, routeEpoch: String) -> String {
  replayDigest([session, bindingIdentity, routeEpoch])
}

/// The hex SHA-256 of `fields`, each length-prefixed so no two lists share one.
public func replayDigest(_ fields: [String]) -> String {
  let data = fields.reduce(into: Data()) { data, field in
    let bytes = Data(field.utf8)
    data.append(contentsOf: "\(bytes.count):".utf8)
    data.append(bytes)
  }
  return SHA256.hash(data: data).map { byte in
    let hex = String(byte, radix: 16)
    return hex.count == 1 ? "0" + hex : hex
  }.joined()
}
