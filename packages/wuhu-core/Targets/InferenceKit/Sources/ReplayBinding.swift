import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct SessionDomain.SessionID

extension ModelsDocument.Provider {
  func bindingIdentity(providerID: String, credentialEpoch: String) -> String {
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

func replayCacheKey(session: SessionID, bindingIdentity: String, routeEpoch: String) -> String {
  replayDigest([session.rawValue, bindingIdentity, routeEpoch])
}

private func replayDigest(_ fields: [String]) -> String {
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

actor UnverifiedOIDCIdentities {
  static let shared = UnverifiedOIDCIdentities()
  private let capacity: Int
  private var providers: [String: [(identity: String, epoch: String)]] = [:]

  init(capacity: Int = 128) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  func epoch(provider: String, token: String) -> String {
    let identity = unverifiedIdentity(token)
    var entries = providers[provider, default: []]
    let binding: (identity: String, epoch: String)
    if let index = entries.firstIndex(where: { $0.identity == identity }) {
      binding = entries.remove(at: index)
    } else {
      binding = (identity, UUID().uuidString)
    }
    entries.append(binding)
    if entries.count > capacity { entries.removeFirst() }
    providers[provider] = entries
    return binding.epoch
  }
}

private func unverifiedIdentity(_ token: String) -> String {
  let parts = token.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 3 else { return replayDigest(["opaque", token]) }
  var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
  guard let data = Data(base64Encoded: encoded),
        let claims = JSONValue.parse(String(decoding: data, as: UTF8.self))?.object,
        let issuer = claims["iss"]?.stringValue, !issuer.isEmpty,
        let subject = claims["sub"]?.stringValue, !subject.isEmpty else { return replayDigest(["opaque", token]) }
  let audiences: [String]
  switch claims["aud"] {
  case let .string(audience): audiences = [audience]
  case let .array(values):
    audiences = values.compactMap(\.stringValue)
    guard audiences.count == values.count else { return replayDigest(["opaque", token]) }
  default: return replayDigest(["opaque", token])
  }
  guard !audiences.isEmpty, audiences.allSatisfy({ !$0.isEmpty }) else { return replayDigest(["opaque", token]) }
  return replayDigest(["claims", issuer, subject] + Set(audiences).sorted())
}
