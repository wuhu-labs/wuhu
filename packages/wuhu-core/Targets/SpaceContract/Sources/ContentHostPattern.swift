#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ContentHostPattern: Equatable, Sendable {
  public let template: String
  private let suffix: String

  public init?(_ pattern: String, origin: URL) {
    let marker = "{group}"
    guard pattern.hasPrefix(marker), pattern.components(separatedBy: marker).count == 2,
          let url = URL(string: "https://" + ("shared" + pattern.dropFirst(marker.count))),
          let host = url.host?.lowercased(), url.user == nil, url.password == nil,
          url.path.isEmpty, url.query == nil, url.fragment == nil,
          url.port == nil || url.port == (origin.port ?? 443),
          host.count <= 253,
          host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
            $0.count <= 63 && GroupID.isValid($0)
          })
    else { return nil }
    let suffix = String(host.dropFirst("shared".count))
    guard !suffix.isEmpty else { return nil }
    self.suffix = suffix
    template = marker + suffix + (origin.port.map { ":\($0)" } ?? "")
  }

  public func group(host: String) -> GroupID? {
    guard host.hasSuffix(suffix), host.count <= 253,
          host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ $0.count <= 63 })
    else { return nil }
    let label = host.dropLast(suffix.count)
    guard GroupID.isValid(label), label.dropFirst(2).prefix(2) != "--" else { return nil }
    return GroupID(rawValue: String(label))
  }
}
