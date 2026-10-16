#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import NIOCore
import NIOPosix
import Serve
import Synchronization

extension ServeNIOServer {
  /// Consumes an already-listening socket; the caller must validate its provenance before adoption.
  public static func adoptListeningSocket(
    _ descriptor: Int32,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    initiallyAccepting: Bool = true,
    handler: @escaping Handler,
  ) async throws -> Self {
    try await self.adoptListeningSocket(
      descriptor, options: options, hooks: hooks, eventLoopGroup: eventLoopGroup, initiallyAccepting: initiallyAccepting, handler: handler,
      start: { bootstrap, descriptor in bootstrap.withBoundSocket(descriptor) },
    )
  }

  static func adoptListeningSocket(
    _ descriptor: Int32,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    initiallyAccepting: Bool = true,
    handler: @escaping Handler,
    start: @Sendable (ServerBootstrap, Int32) -> EventLoopFuture<Channel>,
    initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void> = { $0.eventLoop.makeSucceededFuture(()) },
    dispose: @escaping @Sendable (Int32) -> Void = disposeListeningSocket,
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      reuseAddress: false,
      handler: { .response(try await handler($0)) },
    )
    return try await startListeningSocket(descriptor, bootstrap: bootstrap, state: state, hooks: hooks, initiallyAccepting: initiallyAccepting, start: start, initialize: initialize, dispose: dispose)
  }

  static func startListeningSocket(
    _ descriptor: Int32,
    bootstrap: ServerBootstrap,
    state: ServeNIOServerState,
    hooks: ServeNIOHooks,
    initiallyAccepting: Bool,
    start: @Sendable (ServerBootstrap, Int32) -> EventLoopFuture<Channel> = { $0.withBoundSocket($1) },
    initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void> = { $0.eventLoop.makeSucceededFuture(()) },
    dispose: @escaping @Sendable (Int32) -> Void = disposeListeningSocket,
  ) async throws -> Self {
    let nioOwnsCleanup = Mutex(false)
    let bootstrap = bootstrap.serverChannelInitializer { channel in
      // No channel options may precede this callback: NIO owns cleanup only from here onward.
      nioOwnsCleanup.withLock { $0 = true }
      return channel.setOption(ChannelOptions.autoRead, value: initiallyAccepting).flatMap { initialize(channel) }
    }
    do {
      let serverChannel = try await start(bootstrap, descriptor).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(serverChannel: serverChannel, boundAddress: boundAddress, hooks: hooks, state: state)
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      if !nioOwnsCleanup.withLock({ $0 }) { dispose(descriptor) }
      hooks.onStartupFailure(error)
      throw error
    }
  }
}

func disposeListeningSocket(_ descriptor: Int32) {
  _ = close(descriptor)
}
