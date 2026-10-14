import class AsyncHTTPClient.HTTPClient
import class NIOPosix.MultiThreadedEventLoopGroup

func withUnixHTTP<R: Sendable>(_ body: @Sendable (HTTPClient) async throws -> R) async throws -> R {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  var configuration = HTTPClient.Configuration()
  configuration.redirectConfiguration = .disallow
  let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
  let result: Result<R, any Error>
  do { result = .success(try await body(client)) }
  catch { result = .failure(error) }
  var teardownFailure: (any Error)?
  do { try await client.shutdown() } catch { teardownFailure = error }
  do { try await group.shutdownGracefully() } catch { teardownFailure = teardownFailure ?? error }
  switch result {
  case let .failure(error): throw error
  case let .success(value):
    if let teardownFailure { throw teardownFailure }
    return value
  }
}
