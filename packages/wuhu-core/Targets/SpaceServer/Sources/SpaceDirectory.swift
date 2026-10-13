import Serve

public protocol SpaceDirectory: Sendable {
  func host(for requestHost: String?) async -> SpaceHost?
}

extension SpaceDirectory {
  public var handler: UpgradingHandler {
    { request in
      guard let host = await self.host(for: request.url.host) else {
        return .response(plainStatus(.misdirectedRequest))
      }
      return try await host.handler(request)
    }
  }
}

public struct SingleSpaceDirectory: SpaceDirectory {
  private let spaceHost: SpaceHost

  public init(host: SpaceHost) { spaceHost = host }

  public func host(for requestHost: String?) -> SpaceHost? { spaceHost }
}
