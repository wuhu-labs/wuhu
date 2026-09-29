#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import struct SpaceContract.GroupID

/// The host a space's content lives under: the bare host serves the API and
/// the web app, `<group>.<host>` serves that group's content.
struct ContentHost: Sendable, Equatable {
  /// The bare host, lowercased.
  let host: String
  /// `host[:port]` as a client writes it after `<group>.`.
  let base: String
  /// The bare host's origin, where the web app runs.
  let origin: String

  /// The host of `origin`, which is --origin or, without one,
  /// `https://localhost:<port>`.
  init?(origin: String) {
    guard let url = URL(string: origin), let host = url.host.map(withoutTrailingDot)?.lowercased(), !host.isEmpty
    else { return nil }
    self.host = host
    base = url.port.map { "\(host):\($0)" } ?? host
    self.origin = "\(url.scheme ?? "https")://\(base)"
  }

  /// Where a request's Host puts it. A name nested deeper under the host is
  /// no group: a connection the certificate lets a browser reuse for it gets
  /// 421, and the browser retries on a fresh one. Every other name — an IP
  /// address, a LAN name a machine dials — reaches the API.
  func plane(of requestHost: String?) -> HostPlane {
    guard let requested = requestHost.map(withoutTrailingDot)?.lowercased(), requested.hasSuffix("." + host)
    else { return .api }
    let label = requested.dropLast(host.count + 1)
    return label.isEmpty || label.contains(".") ? .misdirected : .content(GroupID(rawValue: String(label)))
  }
}

enum HostPlane: Equatable {
  case api
  case content(GroupID)
  case misdirected
}

/// `host.` and `host` are one name.
private func withoutTrailingDot(_ host: String) -> String {
  host.hasSuffix(".") ? String(host.dropLast()) : host
}
