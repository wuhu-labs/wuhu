#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import protocol MachineChannel.FrameTransport
import Synchronization

/// The worker's line to main's API, bound once main has built its handler.
/// Every tool the worker owns reaches main through it, as the session, with
/// the session's token; nothing of main's own types crosses here.
public final class MainConnection: Sendable {
  private struct Binding: Sendable {
    let fetch: FetchClient
    let dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)?
  }

  private let client = Mutex<Binding?>(nil)

  public init() {}

  public func bind(
    _ client: FetchClient,
    dial: (@Sendable (URL, [(String, String)]) async throws -> any FrameTransport)? = nil,
  ) {
    self.client.withLock { $0 = Binding(fetch: client, dial: dial) }
  }

  public func bindDial(_ dial: @escaping @Sendable (URL, [(String, String)]) async throws -> any FrameTransport) {
    client.withLock { binding in
      guard let current = binding else { preconditionFailure("main API must be bound before its dial") }
      binding = Binding(fetch: current.fetch, dial: dial)
    }
  }

  func fetch(_ request: Request) async throws -> Response {
    guard let client = client.withLock({ $0 }) else { throw MainUnavailable() }
    return try await client.fetch(request)
  }

  func dial(_ url: URL, headers: [(String, String)]) async throws -> any FrameTransport {
    guard let dial = client.withLock({ $0?.dial }) else { throw MainUnavailable() }
    return try await dial(url, headers)
  }
}

/// Main has not bound its API to this worker.
public struct MainUnavailable: Error, CustomStringConvertible {
  public init() {}
  public var description: String { "main is not reachable from this worker" }
}
