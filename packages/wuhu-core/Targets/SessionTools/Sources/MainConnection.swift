import Fetch
import Synchronization

/// The worker's line to main's API, bound once main has built its handler.
/// Every tool the worker owns reaches main through it, as the session, with
/// the session's token; nothing of main's own types crosses here.
public final class MainConnection: Sendable {
  private let client = Mutex<FetchClient?>(nil)

  public init() {}

  public func bind(_ client: FetchClient) {
    self.client.withLock { $0 = client }
  }

  func fetch(_ request: Request) async throws -> Response {
    guard let client = client.withLock({ $0 }) else { throw MainUnavailable() }
    return try await client(request)
  }
}

/// Main has not bound its API to this worker.
public struct MainUnavailable: Error, CustomStringConvertible {
  public init() {}
  public var description: String { "main is not reachable from this worker" }
}
