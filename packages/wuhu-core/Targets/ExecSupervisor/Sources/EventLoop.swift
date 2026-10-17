import class NIOPosix.MultiThreadedEventLoopGroup

/// One explicit one-thread NIOPosix group carrying the rendezvous socket, shut down after `body` whichever way it ends.
func withEventLoop<R: Sendable>(_ body: @Sendable (MultiThreadedEventLoopGroup) async throws -> R) async throws -> R {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let result: Result<R, any Error>
  do { result = .success(try await body(group)) }
  catch { result = .failure(error) }
  let teardown: Result<Void, any Error>
  do { try await group.shutdownGracefully(); teardown = .success(()) } catch { teardown = .failure(error) }
  let value = try result.get()
  try teardown.get()
  return value
}
