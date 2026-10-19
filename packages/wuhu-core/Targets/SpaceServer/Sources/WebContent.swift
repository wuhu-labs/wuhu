#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct WebContent: Sendable {
  public var webApp: WebApp?
  public let views: [String: Data]
  public let scripts: [String: Data]

  public init(webApp: WebApp? = nil, views: [String: Data] = [:], scripts: [String: Data] = [:]) {
    self.webApp = webApp
    self.views = views
    self.scripts = scripts
  }
}
