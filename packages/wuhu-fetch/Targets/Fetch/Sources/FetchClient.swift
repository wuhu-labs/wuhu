import Dependencies

public struct FetchClient: Sendable {
  public var fetch: @Sendable (Request) async throws -> Response

  public init(fetch: @escaping @Sendable (Request) async throws -> Response) {
    self.fetch = fetch
  }

  public func callAsFunction(_ request: Request) async throws -> Response {
    try await self.fetch(request)
  }
}

public enum FetchClientKey: TestDependencyKey, DependencyKey {
  public static var liveValue: FetchClient {
    FetchClient { _ in
      throw FetchError.unimplemented
    }
  }

  public static var testValue: FetchClient {
    FetchClient { _ in
      throw FetchError.unimplemented
    }
  }
}

extension DependencyValues {
  public var fetch: FetchClient {
    get { self[FetchClientKey.self] }
    set { self[FetchClientKey.self] = newValue }
  }
}
