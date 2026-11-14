#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

import Fetch
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import Serve
import Synchronization

public struct ServeNIOConnectionContext: Sendable {
  public var localAddress: SocketAddress?
  public var remoteAddress: SocketAddress?

  public init(
    localAddress: SocketAddress? = nil,
    remoteAddress: SocketAddress? = nil,
  ) {
    self.localAddress = localAddress
    self.remoteAddress = remoteAddress
  }
}

/// What the graceful wait knows about a request it leaves to the shutdown. Only the requests it
/// tracks are listed: a streaming response whose handler already returned, an upgraded socket and
/// the HTTP/2 parent connection (which serves no request itself) are not.
public struct ServeNIOInFlightRequest: Sendable, Equatable {
  public enum Activity: String, Sendable {
    /// The head is read and the body is still arriving.
    case receivingRequest
    /// The head is read and the response has not finished: the handler runs, or its buffered
    /// response is still being written (possibly blocked on the client). ServeNIO does not track
    /// a response's start, so a slow backend and a slow client look the same here.
    case awaitingResponse
  }

  public var method: String
  public var path: String
  public var version: String
  public var age: Duration
  public var activity: Activity

  public init(method: String, path: String, version: String, age: Duration, activity: Activity) {
    self.method = method
    self.path = path
    self.version = version
    self.age = age
    self.activity = activity
  }
}

/// How the graceful wait ended: the requests answered, the bound ran out on them, or the wait
/// itself was cancelled.
public enum ServeNIOGracefulDrainOutcome: Sendable {
  case drained(after: Duration)
  case boundExpired(ending: [ServeNIOInFlightRequest])
  case cancelled(after: Duration, leaving: [ServeNIOInFlightRequest])
}

/// One connection the close phase is still waiting on, as the registered state knows it.
public struct ServeNIOClosingConnection: Sendable, Equatable {
  public enum Kind: String, Sendable {
    case request
    case stream
    case upgraded
  }

  public var kind: Kind
  /// The request the connection last served; nil where no head reached the handler — an upgrade
  /// NIO negotiated, or a keep-alive connection between requests.
  public var method: String?
  public var path: String?
  public var age: Duration?
  public var channelClosed: Bool
  public var taskCompleted: Bool
}

/// One await of the shutdown, timed, or the connections a wait is still holding.
public enum ServeNIOShutdownProgress: Sendable {
  case step(_ name: String, after: Duration)
  /// The wait is still running, one second or ten seconds in, with the connections still registered.
  case stillClosing(after: Duration, connections: [ServeNIOClosingConnection])
}

public struct ServeNIOHooks: Sendable {
  public var onDidBind: @Sendable (SocketAddress) -> Void
  public var onStartupFailure: @Sendable (any Error) -> Void
  public var onWillShutdown: @Sendable (SocketAddress) -> Void
  public var onDidShutdown: @Sendable (SocketAddress) -> Void
  public var onDidAcceptConnection: @Sendable (ServeNIOConnectionContext) -> Void
  public var onConnectionError: @Sendable (ServeNIOConnectionContext, any Error) -> Void
  public var onHandlerError: @Sendable (ServeNIOConnectionContext, any Error) -> Void
  public var onGracefulDrain: @Sendable (ServeNIOGracefulDrainOutcome) -> Void
  public var onShutdownProgress: @Sendable (ServeNIOShutdownProgress) -> Void

  public init(
    onDidBind: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onStartupFailure: @escaping @Sendable (any Error) -> Void = { _ in },
    onWillShutdown: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onDidShutdown: @escaping @Sendable (SocketAddress) -> Void = { _ in },
    onDidAcceptConnection: @escaping @Sendable (ServeNIOConnectionContext) -> Void = { _ in },
    onConnectionError: @escaping @Sendable (ServeNIOConnectionContext, any Error) -> Void = { _, _ in },
    onHandlerError: @escaping @Sendable (ServeNIOConnectionContext, any Error) -> Void = { _, _ in },
    onGracefulDrain: @escaping @Sendable (ServeNIOGracefulDrainOutcome) -> Void = { _ in },
    onShutdownProgress: @escaping @Sendable (ServeNIOShutdownProgress) -> Void = { _ in },
  ) {
    self.onDidBind = onDidBind
    self.onStartupFailure = onStartupFailure
    self.onWillShutdown = onWillShutdown
    self.onDidShutdown = onDidShutdown
    self.onDidAcceptConnection = onDidAcceptConnection
    self.onConnectionError = onConnectionError
    self.onHandlerError = onHandlerError
    self.onGracefulDrain = onGracefulDrain
    self.onShutdownProgress = onShutdownProgress
  }
}

// swiftlint:disable:next no_unchecked_sendable - NIO channel state bridge
public final class ServeNIOServer: @unchecked Sendable {
  public let boundAddress: SocketAddress

  private let serverChannel: Channel
  private let hooks: ServeNIOHooks
  private let state: ServeNIOServerState
  private let drain: ServeOptions.GracefulDrain?

  public var localAddress: SocketAddress? {
    self.boundAddress
  }

  init(
    serverChannel: Channel,
    boundAddress: SocketAddress,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    drain: ServeOptions.GracefulDrain?,
  ) {
    self.serverChannel = serverChannel
    self.boundAddress = boundAddress
    self.hooks = hooks
    self.state = state
    self.drain = drain
  }

  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler,
  ) async throws -> Self {
    try await self.bind(
      host: host,
      port: port,
      options: options,
      hooks: hooks,
      eventLoopGroup: eventLoopGroup,
      upgrading: { .response(try await handler($0)) },
    )
  }

  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    upgrading handler: @escaping UpgradingHandler,
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: handler,
    )

    do {
      let serverChannel = try await bootstrap.bind(host: host, port: port).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state,
        drain: options.gracefulDrain,
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  public static func bind(
    unixDomainSocketPath: String,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler,
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(
      eventLoopGroup: eventLoopGroup,
      options: options,
      hooks: hooks,
      state: state,
      handler: { .response(try await handler($0)) },
      reusePort: false,
    )

    do {
      let serverChannel = try await bootstrap.bind(unixDomainSocketPath: unixDomainSocketPath).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state,
        drain: options.gracefulDrain,
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  /// Serves on `socket`, a stream socket that is already bound and
  /// listening; the server owns it from here and closes it on shutdown. A
  /// caller that keeps a duplicate of it keeps the listener alive past this
  /// server: connections then wait in its backlog for the next one.
  public static func bind(
    listeningSocket socket: CInt,
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    upgrading handler: @escaping UpgradingHandler,
  ) async throws -> Self {
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(eventLoopGroup: eventLoopGroup, options: options, hooks: hooks, state: state, handler: handler)
    return try await self.adopt(bootstrap.withBoundSocket(socket), hooks: hooks, state: state, drain: options.gracefulDrain)
  }

  static func adopt(
    _ bound: EventLoopFuture<Channel>,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    drain: ServeOptions.GracefulDrain?,
  ) async throws -> Self {
    do {
      let serverChannel = try await bound.get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw BindError.missingBoundAddress
      }
      let server = Self(serverChannel: serverChannel, boundAddress: boundAddress, hooks: hooks, state: state, drain: drain)
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }

  /// Stops taking connections and closes the listening socket this server
  /// owns; the connections it has go on until `shutdown`.
  public func stopAccepting() async {
    try? await self.serverChannel.close()
  }

  public func waitUntilShutdown() async {
    await self.state.waitUntilShutdown()
  }

  public func runUntilCancelled() async {
    await withTaskCancellationHandler {
      await self.waitUntilShutdown()
    } onCancel: {
      Task {
        await self.shutdown()
      }
    }
  }

  /// Stops in the order a replacement process on the same port needs. The
  /// listener goes first, so a connection arriving from now on reaches the
  /// other process; then every request already running answers over its own
  /// connection, which the drain has marked to close after that response; then
  /// what would never end by itself — sockets, streaming responses, parked
  /// keep-alive connections — is closed, and their clients reconnect as after
  /// any restart. A drain with a bound gives only that long before it ends the
  /// requests still running with the rest; the GOAWAY writes queued before them
  /// are delivered inside that same bound, and with no bound they are queued and
  /// not waited for — no wait on a peer is ever without one. Every remaining await
  /// on a peer is bounded by the TLS shutdown timeout or the drain's bound.
  public func shutdown() async {
    switch self.state.beginShutdown() {
    case let .start(http2Connections):
      self.hooks.onWillShutdown(self.boundAddress)
      await self.step("listener close") {
        try? await self.serverChannel.close()
      }
      let goAways = await self.step("goaway") {
        http2Connections.map { Self.sendGoAway(on: $0.channel) }
      }
      await self.step("drain") {
        await self.waitForRequestsToFinish(goAways: goAways)
      }
      let ending = self.state.connectionsToEnd()
      ending.tasks.forEach { $0.cancel() }
      await self.step("channel closes") {
        await withTaskGroup(of: Void.self) { group in
          for channel in ending.channels {
            group.addTask { try? await channel.channel.close() }
          }
        }
      }
      await self.step("connection wait") {
        await self.waitForConnectionsToDrain()
      }
      self.hooks.onDidShutdown(self.boundAddress)
      self.state.finishShutdown()
    case .inProgress, .finished:
      await self.state.waitUntilShutdown()
    }
  }

  /// Times one await of the shutdown and reports it.
  @discardableResult
  private func step<Value>(_ name: String, _ body: () async -> Value) async -> Value {
    let started = NIODeadline.now()
    let value = await body()
    self.hooks.onShutdownProgress(.step(name, after: elapsed(since: started)))
    return value
  }

  private enum DrainSignal: Hashable {
    case requests
    case writes
    case expired
  }

  /// Completes when every GOAWAY write has landed; a cancelled wait leaves the writes alone.
  private static func delivered(_ goAways: [EventLoopFuture<Void>]) async {
    let (landed, continuation) = AsyncStream<Void>.makeStream()
    let count = Mutex(0)
    for future in goAways {
      future.whenComplete { _ in
        let finished = count.withLock { count in
          count += 1
          return count
        }
        if finished == goAways.count { continuation.finish() }
      }
    }
    for await _ in landed { break }
  }

  /// Gives the requests already running, and the GOAWAY writes queued before them, the drain's
  /// bound to finish when one is set; past it they are ended with the streams, sockets and idle
  /// connections below, as they were before a graceful drain existed. With no bound the writes
  /// are queued and not waited for.
  private func waitForRequestsToFinish(goAways: [EventLoopFuture<Void>]) async {
    let started = NIODeadline.now()
    guard let drain = self.drain else {
      await self.state.waitForRequestsToFinish()
      self.hooks.onGracefulDrain(.drained(after: elapsed(since: started)))
      return
    }
    let expired = await withTaskGroup(of: DrainSignal.self) { group in
      group.addTask {
        await self.state.waitForRequestsToFinish()
        return .requests
      }
      if !goAways.isEmpty {
        // A future a stalled peer never completes is left behind at the bound: cancelled, never
        // joined, so the force-close below is what ends it.
        group.addTask {
          await Self.delivered(goAways)
          return .writes
        }
      }
      group.addTask {
        do { try await drain.wait(drain.timeout) } catch { return .expired }
        return .expired
      }
      var outstanding: Set<DrainSignal> = goAways.isEmpty ? [.requests] : [.requests, .writes]
      while let signal = await group.next() {
        guard signal != .expired else {
          group.cancelAll()
          return true
        }
        outstanding.remove(signal)
        guard !outstanding.isEmpty else {
          group.cancelAll()
          return false
        }
      }
      return false
    }
    if Task.isCancelled {
      self.hooks.onGracefulDrain(.cancelled(after: elapsed(since: started), leaving: self.state.inFlightRequests()))
    } else if expired {
      self.hooks.onGracefulDrain(.boundExpired(ending: self.state.inFlightRequests()))
    } else {
      self.hooks.onGracefulDrain(.drained(after: elapsed(since: started)))
    }
  }

  private func elapsed(since start: NIODeadline) -> Duration {
    .nanoseconds(max(0, (NIODeadline.now() - start).nanoseconds))
  }

  /// Waits out the connections the force-close ended; a bound's own clock marks one and ten
  /// seconds, and the watcher only reports — it never ends or shortens the wait.
  private func waitForConnectionsToDrain() async {
    let started = NIODeadline.now()
    guard let drain = self.drain else {
      await self.state.waitForConnectionsToDrain()
      return
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.state.waitForConnectionsToDrain() }
      group.addTask {
        do {
          try await drain.wait(.seconds(1))
          self.hooks.onShutdownProgress(.stillClosing(after: self.elapsed(since: started), connections: self.state.closingConnections()))
          try await drain.wait(.seconds(9))
          self.hooks.onShutdownProgress(.stillClosing(after: self.elapsed(since: started), connections: self.state.closingConnections()))
        } catch {}
      }
      await group.next()
      group.cancelAll()
    }
  }

  /// The largest last stream ID, so every stream already open still gets its
  /// response and the peer opens no new one.
  private static func sendGoAway(on channel: Channel) -> EventLoopFuture<Void> {
    channel.writeAndFlush(HTTP2Frame(streamID: .rootStream, payload: .goAway(lastStreamID: .maxID, errorCode: .noError, opaqueData: nil)))
  }

  public func close() async {
    await self.shutdown()
  }

  static func validateOptions(_ options: ServeOptions) {
    precondition(
      options.requestBodyLowWatermarkBytes < options.requestBodyHighWatermarkBytes,
      "requestBodyLowWatermarkBytes must be below requestBodyHighWatermarkBytes",
    )
  }

  static func makeBootstrap(
    eventLoopGroup: EventLoopGroup,
    options: ServeOptions,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    handler: @escaping UpgradingHandler,
    reusePort: Bool = true,
  ) -> ServerBootstrap {
    self.validateOptions(options)
    return self.makeBootstrap(eventLoopGroup: eventLoopGroup, hooks: hooks, state: state, reusePort: reusePort) { channel, connectionID, context, activity in
      channel.eventLoop.makeCompletedFuture {
        try self.configureHTTP1(
          channel: channel,
          options: options,
          hooks: hooks,
          state: state,
          connectionID: connectionID,
          context: context,
          activity: activity,
          handler: handler,
        )
      }
    }
  }

  static func makeBootstrap(
    eventLoopGroup: EventLoopGroup,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    reusePort: Bool = true,
    initializer: @escaping @Sendable (Channel, Int, ServeNIOConnectionContext, ConnectionActivity) -> EventLoopFuture<Void>,
  ) -> ServerBootstrap {
    let bootstrap = ServerBootstrap(group: eventLoopGroup)
    _ = bootstrap.serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    // The port of a roll: the incoming process binds it while the outgoing one
    // is still accepting, and the kernel spreads new connections over both
    // until the outgoing listener closes. Unix domain sockets reject the
    // option, so a listener on one keeps `reusePort` off.
    if reusePort {
      _ = bootstrap.serverChannelOption(.socketOption(.reusePort), value: 1)
    }
    return bootstrap.childChannelInitializer { channel in
      let connectionID = state.makeConnectionID()
      let activity = ConnectionActivity(initialPhase: .receivingRequest)
      guard state.registerConnection(id: connectionID, channel: channel, activity: activity) else {
        return channel.close()
      }

      let context = ServeNIOConnectionContext(
        localAddress: channel.localAddress,
        remoteAddress: channel.remoteAddress,
      )
      hooks.onDidAcceptConnection(context)
      return initializer(channel, connectionID, context, activity)
    }
  }

  static func configureHTTP1(
    channel: Channel,
    options: ServeOptions,
    hooks: ServeNIOHooks,
    state: ServeNIOServerState,
    connectionID: Int,
    context: ServeNIOConnectionContext,
    activity: ConnectionActivity,
    handler: @escaping UpgradingHandler,
  ) throws {
    let pipeline = channel.pipeline.syncOperations
    // Timeout handlers live at the channel head so they cover the entire
    // connection lifetime — including the window before the first request head
    // is decoded, which a silent or trickling client would otherwise hold open
    // forever. On a successful WebSocket upgrade the activity is marked upgraded
    // so these events stop reaping the (long-lived) socket.
    let readTimeout = options.requestReadInactivityTimeout.map(timeAmount)
    let idleTimeout = options.keepAliveIdleTimeout.map(timeAmount)
    let hasTimeoutHandlers = readTimeout != nil || idleTimeout != nil
    if hasTimeoutHandlers {
      try pipeline.addHandler(
        IdleStateHandler(readTimeout: readTimeout, allTimeout: idleTimeout),
        name: idleStateHandlerName,
      )
      try pipeline.addHandler(
        IdleTimeoutHandler(activity: activity, readTimeout: readTimeout),
        name: idleTimeoutHandlerName,
      )
    }
    try pipeline.addHandler(HTTPHeadLimitHandler(options: options))
    let negotiation = WebSocketNegotiation()
    let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration<WebSocketNegotiationOutcome>(
      upgraders: [
        webSocketUpgrader(
          options: options,
          hooks: hooks,
          context: context,
          negotiation: negotiation,
          activity: activity,
          hasTimeoutHandlers: hasTimeoutHandlers,
          handler: handler,
        ),
      ],
      notUpgradingCompletionHandler: { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            ServeNIOHTTPHandler(
              options: options,
              hooks: hooks,
              context: context,
              state: state,
              connectionID: connectionID,
              activity: activity,
              handler: httpOnly(handler),
            ),
          )
          return .http
        }
      },
    )
    var configuration = NIOUpgradableHTTPServerPipelineConfiguration(upgradeConfiguration: upgradeConfiguration)
    configuration.enableErrorHandling = false
    let outcome = try pipeline.configureUpgradableHTTPServerPipeline(configuration: configuration)
    try pipeline.addHandler(WebSocketRefusalObserver(negotiation: negotiation))
    outcome.whenComplete { result in
      self.serveNegotiationOutcome(result, negotiation: negotiation, channel: channel, state: state, connectionID: connectionID)
    }
  }

  private static func serveNegotiationOutcome(
    _ result: Result<WebSocketNegotiationOutcome, any Error>,
    negotiation: WebSocketNegotiation,
    channel: Channel,
    state: ServeNIOServerState,
    connectionID: Int,
  ) {
    switch result {
    case .success(.http):
      // A refused upgrade never replays the request head (NIO consumed it for
      // negotiation), so the stashed response must be written here — the HTTP
      // handler only ever sees non-upgrade requests.
      guard let response = negotiation.takeResponse() else { break }
      let task = Task {
        defer {
          state.taskDidComplete(id: connectionID)
        }
        try? await ServeNIOHTTPHandler.writeResponse(response, version: .http1_1, channel: channel, closeConnection: true)
        try? await channel.close()
      }
      if state.storeTask(task, id: connectionID) {
        task.cancel()
      }
    case let .success(.boundedWebSocket(session, transport)):
      let task = Task {
        defer { state.taskDidComplete(id: connectionID); transport.abort() }
        await withTaskCancellationHandler { await session(transport) } onCancel: { transport.abort() }
      }
      if state.storeTask(task, id: connectionID) { task.cancel() }
    case let .success(.webSocket(session, socket)):
      let task = Task {
        defer {
          state.taskDidComplete(id: connectionID)
        }
        await withTaskCancellationHandler {
          await session(socket)
        } onCancel: {
          socket.close()
        }
        socket.close()
      }
      if state.storeTask(task, id: connectionID) {
        task.cancel()
      }
    case .failure:
      channel.close(promise: nil)
    }
  }
}

@available(*, deprecated, renamed: "ServeNIOServer")
public typealias ServeNIOListener = ServeNIOServer

enum BindError: Error {
  case missingBoundAddress
}

// swiftlint:disable:next no_unchecked_sendable - NIO channel state bridge
final class ChannelBox: @unchecked Sendable {
  let channel: Channel

  init(channel: Channel) {
    self.channel = channel
  }
}

// swiftlint:disable:next no_unchecked_sendable - NIO channel state bridge
final class ServeNIOServerState: @unchecked Sendable {
  private enum Phase {
    case running
    case shuttingDown
    case finished
  }

  private struct RequestWaiter {
    let id: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct ServedRequest {
    let method: String
    let path: String
    let version: String
    let startedAt: NIODeadline

    func inFlight(activity: ServeNIOInFlightRequest.Activity) -> ServeNIOInFlightRequest {
      ServeNIOInFlightRequest(
        method: method, path: path, version: version,
        age: .nanoseconds(max(0, (NIODeadline.now() - startedAt).nanoseconds)),
        activity: activity,
      )
    }
  }

  private struct ActiveConnection {
    let channel: ChannelBox
    let activity: ConnectionActivity
    var served: ServedRequest?
    var task: Task<Void, Never>?
    var channelClosed = false
    var taskCompleted = false
    var streaming = false
    var http2Connection = false
  }

  struct ConnectionsToEnd {
    let channels: [ChannelBox]
    let tasks: [Task<Void, Never>]
  }

  enum BeginShutdownResult {
    case start(http2Connections: [ChannelBox])
    case inProgress
    case finished
  }

  private struct State {
    var nextConnectionID = 0
    var phase: Phase = .running
    /// Past the graceful drain: `connectionsToEnd` has taken the snapshot, so a
    /// connection or task registered now would never be closed by it.
    var ending = false
    var connections: [Int: ActiveConnection] = [:]
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var requestWaiters: [RequestWaiter] = []
    var nextWaiterID = 0
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private var state = State()
  private var lock = pthread_mutex_t()

  init() {
    pthread_mutex_init(&self.lock, nil)
  }

  deinit {
    pthread_mutex_destroy(&self.lock)
  }

  var isShuttingDown: Bool {
    self.lockState()
    let result = self.state.phase != .running
    self.unlockState()
    return result
  }

  func makeConnectionID() -> Int {
    self.lockState()
    let connectionID = self.state.nextConnectionID
    self.state.nextConnectionID += 1
    self.unlockState()
    return connectionID
  }

  func registerConnection(id: Int, channel: Channel, activity: ConnectionActivity) -> Bool {
    self.lockState()
    guard self.state.phase == .running else {
      self.unlockState()
      return false
    }
    self.state.connections[id] = ActiveConnection(channel: ChannelBox(channel: channel), activity: activity)
    self.unlockState()

    channel.closeFuture.whenComplete { _ in
      self.channelDidClose(id: id)
    }
    return true
  }

  func markHTTP2Connection(id: Int) {
    self.withLock { $0.connections[id]?.http2Connection = true }
  }

  /// The head a connection is serving, kept for the per-request lines a drain bound reports.
  func requestBegan(id: Int, method: String, path: String, version: String) {
    self.withLock { state in
      state.connections[id]?.served = ServedRequest(method: method, path: path, version: version, startedAt: .now())
    }
  }

  /// The requests the drain still waits on, each with what the connection knows about it.
  func inFlightRequests() -> [ServeNIOInFlightRequest] {
    self.withLock { state in
      state.connections.values.compactMap { connection in
        guard Self.isRequestInFlight(connection), let served = connection.served else { return nil }
        let activity: ServeNIOInFlightRequest.Activity = connection.activity.phase == .receivingRequest ? .receivingRequest : .awaitingResponse
        return served.inFlight(activity: activity)
      }
    }
  }

  /// Admits a request the connection holds: refused once the drain has begun,
  /// so no handler starts behind the shutdown wait. Whatever stream the
  /// connection wrote before has ended.
  func admitRequest(id: Int) -> Bool {
    self.withLock { state in
      guard state.phase == .running else { return false }
      state.connections[id]?.streaming = false
      return true
    }
  }

  /// A body that streams is a response whose connection ends only by force:
  /// its handler has already returned, so the drain stops waiting on the
  /// connection and closes it with the sockets.
  func markStreaming(id: Int) {
    let requestWaiters = self.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.connections[id]?.streaming = true
      return self.takeRequestWaitersIfNeeded(state: &state)
    }
    self.resume(requestWaiters)
  }

  /// A parked connection: the response went out, so the drain may stop waiting
  /// on it. Parking under the state's lock is what makes a waiter's
  /// registration unable to race past the last completion.
  func requestDidPark(id: Int, generation: Int) {
    let requestWaiters = self.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.connections[id]?.activity.parkIfCurrent(generation: generation)
      if state.connections[id]?.activity.phase == .idle { state.connections[id]?.served = nil }
      return self.takeRequestWaitersIfNeeded(state: &state)
    }
    self.resume(requestWaiters)
  }

  /// A task registered during the graceful drain keeps running: its connection
  /// may already have admitted a request, and the drain waits for that answer.
  /// Only the force-close phase, or a closed channel, cancels it.
  func storeTask(_ task: Task<Void, Never>, id: Int) -> Bool {
    self.lockState()
    guard var connection = self.state.connections[id] else {
      self.unlockState()
      return true
    }
    connection.task = task
    self.state.connections[id] = connection
    let shouldCancel = self.state.ending || self.state.phase == .finished || connection.channelClosed
    self.unlockState()
    return shouldCancel
  }

  func taskDidComplete(id: Int) {
    let (drainWaiters, requestWaiters) = self.withLock {
      state -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
      guard var connection = state.connections[id] else {
        return ([], [])
      }
      connection.taskCompleted = true
      connection.task = nil
      if connection.channelClosed {
        state.connections.removeValue(forKey: id)
      } else {
        state.connections[id] = connection
      }
      return (self.takeDrainWaitersIfNeeded(state: &state), self.takeRequestWaitersIfNeeded(state: &state))
    }
    self.resume(drainWaiters)
    self.resume(requestWaiters)
  }

  func beginShutdown() -> BeginShutdownResult {
    self.withLock { state in
      switch state.phase {
      case .running:
        state.phase = .shuttingDown
        return .start(http2Connections: state.connections.values.filter(\.http2Connection).map(\.channel))
      case .shuttingDown:
        return .inProgress
      case .finished:
        return .finished
      }
    }
  }

  /// Waits for the requests in flight; a drain's bound cancels this wait, and
  /// the wait then leaves at once so the drain can end them.
  func waitForRequestsToFinish() async {
    let id = self.withLock { state -> Int in
      defer { state.nextWaiterID += 1 }
      return state.nextWaiterID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let waiting = self.withLock { state -> Bool in
          guard !Task.isCancelled, state.connections.values.contains(where: Self.isRequestInFlight) else { return false }
          state.requestWaiters.append(RequestWaiter(id: id, continuation: continuation))
          return true
        }
        if !waiting {
          continuation.resume()
        }
      }
    } onCancel: {
      let waiter = self.withLock { state -> CheckedContinuation<Void, Never>? in
        guard let index = state.requestWaiters.firstIndex(where: { $0.id == id }) else { return nil }
        return state.requestWaiters.remove(at: index).continuation
      }
      waiter?.resume()
    }
  }

  /// Every connection still registered, for the close wait's one- and ten-second reports.
  func closingConnections() -> [ServeNIOClosingConnection] {
    self.withLock { state in
      state.connections.values.map { connection in
        let kind: ServeNIOClosingConnection.Kind = if connection.activity.isUpgraded {
          .upgraded
        } else if connection.streaming {
          .stream
        } else {
          .request
        }
        return ServeNIOClosingConnection(
          kind: kind,
          method: connection.served?.method,
          path: connection.served?.path,
          age: connection.served.map { .nanoseconds(max(0, (NIODeadline.now() - $0.startedAt).nanoseconds)) },
          channelClosed: connection.channelClosed,
          taskCompleted: connection.taskCompleted,
        )
      }
      .sorted { ($0.path ?? "", $0.method ?? "") < ($1.path ?? "", $1.method ?? "") }
    }
  }

  func connectionsToEnd() -> ConnectionsToEnd {
    self.withLock { state in
      state.ending = true
      return ConnectionsToEnd(
        channels: state.connections.values.map(\.channel),
        tasks: state.connections.values.compactMap(\.task),
      )
    }
  }

  func waitForConnectionsToDrain() async {
    await withCheckedContinuation { continuation in
      self.lockState()
      if self.state.connections.isEmpty {
        self.unlockState()
        continuation.resume()
        return
      }
      self.state.drainWaiters.append(continuation)
      self.unlockState()
    }
  }

  func finishShutdown() {
    let shutdownWaiters = self.withLock {
      $0.phase = .finished
      let waiters = $0.shutdownWaiters
      $0.shutdownWaiters = []
      return waiters
    }
    self.resume(shutdownWaiters)
  }

  func waitUntilShutdown() async {
    await withCheckedContinuation { continuation in
      self.lockState()
      if self.state.phase == .finished {
        self.unlockState()
        continuation.resume()
        return
      }
      self.state.shutdownWaiters.append(continuation)
      self.unlockState()
    }
  }

  private func channelDidClose(id: Int) {
    let (task, drainWaiters, requestWaiters) = self.withLock {
      state -> (Task<Void, Never>?, [CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
      guard var connection = state.connections[id] else { return (nil, [], []) }
      connection.channelClosed = true
      if connection.taskCompleted || connection.task == nil {
        state.connections.removeValue(forKey: id)
      } else {
        state.connections[id] = connection
      }
      return (connection.task, self.takeDrainWaitersIfNeeded(state: &state), self.takeRequestWaitersIfNeeded(state: &state))
    }
    task?.cancel()
    self.resume(drainWaiters)
    self.resume(requestWaiters)
  }

  /// A request is in flight until its response starts or its connection goes:
  /// a parked keep-alive connection, a silent one, and a live socket have
  /// nothing that would finish on its own, and a streaming response outlives
  /// the handler that produced it.
  private static func isRequestInFlight(_ connection: ActiveConnection) -> Bool {
    guard !connection.streaming, !connection.activity.isUpgraded, connection.activity.hasRequest else {
      return false
    }
    return connection.activity.phase != .idle
  }

  private func takeDrainWaitersIfNeeded(state: inout State) -> [CheckedContinuation<Void, Never>] {
    guard state.phase == .shuttingDown, state.connections.isEmpty else {
      return []
    }
    let waiters = state.drainWaiters
    state.drainWaiters = []
    return waiters
  }

  private func takeRequestWaitersIfNeeded(state: inout State) -> [CheckedContinuation<Void, Never>] {
    guard !state.connections.values.contains(where: Self.isRequestInFlight) else {
      return []
    }
    let waiters = state.requestWaiters.map(\.continuation)
    state.requestWaiters = []
    return waiters
  }

  private func resume(_ waiters: [CheckedContinuation<Void, Never>]) {
    waiters.forEach { $0.resume() }
  }

  private func withLock<T>(_ body: (inout State) -> T) -> T {
    self.lockState()
    let result = body(&self.state)
    self.unlockState()
    return result
  }

  private func lockState() {
    pthread_mutex_lock(&self.lock)
  }

  private func unlockState() {
    pthread_mutex_unlock(&self.lock)
  }
}

private extension NIOBSDSocket.Option {
  /// The pinned NIO names no option for this: two servers, the outgoing and the
  /// incoming release process, listen on one port through it.
  static var reusePort: Self {
    Self(rawValue: SO_REUSEPORT)
  }
}

private final class HTTPHeadLimitHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private let maximumHeadBytes: Int
  private let maximumHeaderLineBytes: Int
  private var observedHeadBytes = 0
  private var observedLineBytes = 0
  private var recentBytes: [UInt8] = []
  private var didFinishHead = false
  private var didFail = false

  init(options: ServeOptions) {
    self.maximumHeadBytes = options.maximumHeadBytes
    self.maximumHeaderLineBytes = options.maximumHeaderLineBytes
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !self.didFail, !self.didFinishHead else {
      context.fireChannelRead(data)
      return
    }

    let buffer = self.unwrapInboundIn(data)
    for byte in buffer.readableBytesView {
      self.observedHeadBytes += 1
      self.observedLineBytes += 1

      guard self.observedHeadBytes <= self.maximumHeadBytes else {
        self.fail(context: context)
        return
      }
      guard self.observedLineBytes <= self.maximumHeaderLineBytes else {
        self.fail(context: context)
        return
      }

      self.recentBytes.append(byte)
      if self.recentBytes.count > 4 {
        self.recentBytes.removeFirst()
      }

      if byte == 0x0A {
        self.observedLineBytes = 0
      }

      if self.recentBytes == [0x0D, 0x0A, 0x0D, 0x0A] {
        self.didFinishHead = true
        break
      }
    }

    context.fireChannelRead(data)
  }

  private func fail(context: ChannelHandlerContext) {
    self.didFail = true
    var buffer = context.channel.allocator.buffer(capacity: 128)
    buffer.writeString("HTTP/1.1 431 Request Header Fields Too Large\r\n")
    buffer.writeString("content-length: 0\r\n")
    buffer.writeString("connection: close\r\n")
    buffer.writeString("\r\n")
    let channel = ChannelBox(channel: context.channel)
    context.writeAndFlush(self.wrapOutboundOut(buffer)).whenComplete { _ in
      channel.channel.close(promise: nil)
    }
  }
}

func httpOnly(_ handler: @escaping UpgradingHandler) -> Handler {
  { request in
    switch try await handler(request) {
    case let .response(response):
      return response
    case .webSocket, .boundedWebSocket:
      throw WebSocketUpgradeMisuse()
    }
  }
}

struct InboundRequest: Sendable {
  let request: Request
  let version: HTTPVersion
  let keepAlive: Bool
  let generation: Int
  let bodyBuffer: RequestBodyBuffer?
}

// Tracks where a keep-alive connection is in its request cycle so the idle
// timeout handler can gate: read-idle is fatal only while a request is still
// being received, and no timeout fires while a (possibly long-lived streaming)
// response is in flight.
//
// Two unsynchronized writers touch this: the channel handler (event loop) drives
// per-request phase transitions, and the connection loop task parks the
// connection once a response completes. Because HTTPServerPipelineHandler
// delivers the next pipelined request synchronously inside the previous
// response's `.end` write — before the loop task resumes — a bare phase enum
// would let the loop's park stamp `.idle` over the already-arrived next request.
// A monotonic generation, bumped on every request head and compared when
// parking, makes the loop a conditional writer that never clobbers a newer
// request's phase.
final class ConnectionActivity: Sendable {
  enum Phase: Sendable {
    case idle
    case receivingRequest
    case awaitingResponse
  }

  private struct State {
    var phase: Phase
    var generation = 0
    var backpressurePaused = false
    var lastUnpause = NIODeadline.uptimeNanoseconds(0)
    var upgraded = false
  }

  private let state: Mutex<State>

  init(initialPhase: Phase = .receivingRequest) {
    self.state = Mutex(State(phase: initialPhase))
  }

  var phase: Phase {
    self.state.withLock { $0.phase }
  }

  var isUpgraded: Bool {
    self.state.withLock { $0.upgraded }
  }

  var hasRequest: Bool {
    self.state.withLock { $0.generation > 0 }
  }

  func beginRequest() -> Int {
    self.state.withLock { state in
      state.generation += 1
      state.phase = .receivingRequest
      return state.generation
    }
  }

  func requestFullyReceived() {
    self.state.withLock { $0.phase = .awaitingResponse }
  }

  // A malformed head that never became a request still advances the generation
  // so the loop's park (keyed on the prior request's generation) cannot stamp
  // `.idle` over it, and moves to `.awaitingResponse` so a racing errorCaught
  // closes rather than interleaving a second error write.
  func beginErrorResponse() {
    self.state.withLock { state in
      state.generation += 1
      state.phase = .awaitingResponse
    }
  }

  func parkIfCurrent(generation: Int) {
    self.state.withLock { state in
      if state.generation == generation {
        state.phase = .idle
      }
    }
  }

  func setBackpressurePaused(_ paused: Bool) {
    self.state.withLock { state in
      state.backpressurePaused = paused
      // Unpausing only clears the flag; the socket read resumes asynchronously,
      // so record when it happened and require a full idle interval since then
      // before read-idle may reap (`readIdleShouldReap`).
      if !paused {
        state.lastUnpause = .now()
      }
    }
  }

  func markUpgraded() {
    self.state.withLock { $0.upgraded = true }
  }

  func readIdleShouldReap(interval: TimeAmount) -> Bool {
    self.state.withLock { state in
      guard state.phase == .receivingRequest, !state.backpressurePaused else {
        return false
      }
      return NIODeadline.now() - state.lastUnpause >= interval
    }
  }

  func allIdleShouldReap() -> Bool {
    // A parked keep-alive connection, or one that has never produced a request
    // head (a silent pre-first-head client), may be reaped.
    self.state.withLock { $0.phase == .idle || $0.generation == 0 }
  }
}

final class ServeNIOHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let options: ServeOptions
  private let hooks: ServeNIOHooks
  private let connectionContext: ServeNIOConnectionContext
  private let serverState: ServeNIOServerState
  private let connectionID: Int
  private let activity: ConnectionActivity
  private let handler: Handler

  private let requests: AsyncStream<InboundRequest>
  private let requestsContinuation: AsyncStream<InboundRequest>.Continuation
  private var currentBody: RequestBodyBuffer?
  private var didStartLoop = false
  private var closingResponse = false

  init(
    options: ServeOptions,
    hooks: ServeNIOHooks,
    context: ServeNIOConnectionContext,
    state: ServeNIOServerState,
    connectionID: Int,
    activity: ConnectionActivity,
    handler: @escaping Handler,
  ) {
    self.options = options
    self.hooks = hooks
    self.connectionContext = context
    self.serverState = state
    self.connectionID = connectionID
    self.activity = activity
    self.handler = handler
    (self.requests, self.requestsContinuation) = AsyncStream.makeStream()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !self.closingResponse else { return }
    switch self.unwrapInboundIn(data) {
    case let .head(head):
      self.receiveHead(head, context: context)

    case let .body(buffer):
      guard let currentBody else { return }
      currentBody.yield(Data(buffer.readableBytesView))

    case .end:
      self.currentBody?.finish()
      self.currentBody = nil
      self.activity.requestFullyReceived()
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    self.currentBody?.finish(throwing: CancellationError())
    self.currentBody = nil
    self.requestsContinuation.finish()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    self.currentBody?.finish(throwing: error)
    self.currentBody = nil
    guard !self.serverState.isShuttingDown, !self.closingResponse else {
      context.close(promise: nil)
      return
    }

    // Only a genuinely parked connection (`.idle`) has no in-flight response to
    // corrupt, so only then may we synthesize a 400. In every other phase a
    // response may be mid-write, so we close rather than interleave a write.
    if self.activity.phase == .idle {
      let channel = ChannelBox(channel: context.channel)
      Self.startErrorResponseTask(status: .badRequest, channel: channel)
    } else {
      self.hooks.onConnectionError(self.connectionContext, error)
      context.close(promise: nil)
    }
  }

  private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    do {
      try self.validateHeadLimits(head)
      let (request, bodyBuffer) = try self.makeRequest(from: head, channel: context.channel)
      let generation = self.activity.beginRequest()
      self.serverState.requestBegan(
        id: self.connectionID,
        method: head.method.rawValue,
        path: request.url.path,
        version: head.version.major == 2 ? "HTTP/2" : "HTTP/\(head.version.major).\(head.version.minor)",
      )
      self.currentBody = bodyBuffer
      self.requestsContinuation.yield(
        InboundRequest(
          request: request,
          version: head.version,
          keepAlive: head.isKeepAlive,
          generation: generation,
          bodyBuffer: bodyBuffer,
        ),
      )
      self.startLoopIfNeeded(context: context)
    } catch let error as ServeError {
      self.activity.beginErrorResponse()
      let channel = ChannelBox(channel: context.channel)
      Self.startErrorResponseTask(status: error.responseStatus, channel: channel)
    } catch {
      self.activity.beginErrorResponse()
      let channel = ChannelBox(channel: context.channel)
      Self.startErrorResponseTask(status: .badRequest, channel: channel)
    }
  }

  private func startLoopIfNeeded(context: ChannelHandlerContext) {
    guard !self.didStartLoop else { return }
    self.didStartLoop = true

    let channel = ChannelBox(channel: context.channel)
    let task = Self.startConnectionLoop(
      requests: self.requests,
      channel: channel,
      handler: self.handler,
      hooks: self.hooks,
      connectionContext: self.connectionContext,
      serverState: self.serverState,
      connectionID: self.connectionID,
    )

    if self.serverState.storeTask(task, id: self.connectionID) {
      task.cancel()
      context.close(promise: nil)
    }
  }

  private static func startConnectionLoop(
    requests: AsyncStream<InboundRequest>,
    channel: ChannelBox,
    handler: @escaping Handler,
    hooks: ServeNIOHooks,
    connectionContext: ServeNIOConnectionContext,
    serverState: ServeNIOServerState,
    connectionID: Int,
  ) -> Task<Void, Never> {
    Task {
      defer {
        serverState.taskDidComplete(id: connectionID)
      }

      for await inbound in requests {
        let keepAlive = await Self.serveOne(
          inbound,
          channel: channel.channel,
          handler: handler,
          hooks: hooks,
          connectionContext: connectionContext,
          serverState: serverState,
          connectionID: connectionID,
        )
        guard keepAlive, !serverState.isShuttingDown else {
          try? await channel.channel.close()
          return
        }
        // Park only if no newer request has already arrived (pipelining delivers
        // the next request synchronously inside the previous `.end` write, so by
        // now `activity` may already describe request N+1).
        serverState.requestDidPark(id: connectionID, generation: inbound.generation)
      }
    }
  }

  private static func startErrorResponseTask(status: Status, channel: ChannelBox) {
    Task {
      try? await Self.writeErrorResponse(status: status, channel: channel.channel)
      try? await channel.channel.close()
    }
  }

  private static func serveOne(
    _ inbound: InboundRequest,
    channel: Channel,
    handler: Handler,
    hooks: ServeNIOHooks,
    connectionContext: ServeNIOConnectionContext,
    serverState: ServeNIOServerState,
    connectionID: Int,
  ) async -> Bool {
    guard serverState.admitRequest(id: connectionID) else {
      try? await channel.close()
      return false
    }
    let response: Response
    do {
      response = try await handler(inbound.request)
    } catch let error as ServeError {
      try? await Self.writeErrorResponse(status: error.responseStatus, channel: channel)
      return false
    } catch {
      hooks.onHandlerError(connectionContext, error)
      try? await Self.writeErrorResponse(status: .internalServerError, channel: channel)
      return false
    }

    // A keep-alive connection may only be reused once the request body is fully
    // consumed off the wire. If the handler left an unconsumed body that we
    // cannot cleanly drain within the body cap (e.g. an oversized chunked
    // upload), reusing the connection would misframe the next request — so a
    // failed or incomplete drain forces the connection closed.
    let requestedClose = response.headers[HTTPField.Name("Connection")!]?.lowercased()
      .split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "close" } ?? false
    let drained = requestedClose ? false : await Self.drainBody(inbound.bodyBuffer)
    // HTTP/2 multiplexes over streams; a stream carries a single request and
    // must be closed after its response. Keep-alive looping is HTTP/1.x only.
    let keepAlive = drained && inbound.keepAlive && inbound.version.major == 1 && !serverState.isShuttingDown
    if !response.body.endsByItself {
      serverState.markStreaming(id: connectionID)
    }

    do {
      if !keepAlive, inbound.version.major == 1 { try await Self.prepareClosingResponse(channel: channel) }
      try await Self.writeResponse(
        response,
        version: inbound.version,
        channel: channel,
        closeConnection: !keepAlive,
      )
      return keepAlive
    } catch let error as ResponseBodyWriteError {
      if !serverState.isShuttingDown {
        hooks.onConnectionError(connectionContext, error.underlying)
      }
      return false
    } catch {
      if !serverState.isShuttingDown {
        hooks.onConnectionError(connectionContext, error)
      }
      return false
    }
  }

  private static func prepareClosingResponse(channel: Channel) async throws {
    try await channel.eventLoop.submit {
      let pipeline = channel.pipeline.syncOperations
      let handler = try pipeline.handler(type: ServeNIOHTTPHandler.self)
      handler.closingResponse = true
      handler.currentBody?.finish(throwing: CancellationError())
      handler.currentBody = nil
      handler.requestsContinuation.finish()
      // Darwin needs reads to observe EOF; NIO's pipeline gate suppresses them until response end.
      let gate = try pipeline.handler(type: HTTPServerPipelineHandler.self)
      return pipeline.removeHandler(gate)
    }.flatMap { $0 }.get()
  }

  private static func drainBody(_ buffer: RequestBodyBuffer?) async -> Bool {
    guard let buffer else { return true }
    return await buffer.drainForKeepAlive()
  }

  private func validateHeadLimits(_ head: HTTPRequestHead) throws {
    try RequestHeadParser.validateLimits(head, options: self.options)
  }

  private func makeRequest(from head: HTTPRequestHead, channel: Channel) throws -> (Request, RequestBodyBuffer?) {
    let parsed = try RequestHeadParser.parse(head, options: self.options)

    let body: Body?
    let buffer: RequestBodyBuffer?
    if let contentLength = parsed.contentLength, contentLength > 0 {
      let bodyBuffer = self.makeBodyBuffer(channel: channel)
      buffer = bodyBuffer
      body = .stream(
        length: Int64(contentLength),
        contentType: parsed.contentType,
        RequestBodyStream(buffer: bodyBuffer),
      )
    } else if parsed.isChunked {
      let bodyBuffer = self.makeBodyBuffer(channel: channel)
      buffer = bodyBuffer
      body = .stream(
        contentType: parsed.contentType,
        RequestBodyStream(buffer: bodyBuffer),
      )
    } else {
      buffer = nil
      body = nil
    }

    return (Request(url: parsed.url, method: parsed.method, headers: parsed.headers, body: body), buffer)
  }

  private func makeBodyBuffer(channel: Channel) -> RequestBodyBuffer {
    // Toggling autoRead is the backpressure valve: reads keep flowing until the
    // buffered-but-unconsumed body crosses the high watermark, then resume once
    // the handler drains below the low watermark. `Channel.setOption` is
    // thread-safe, so the async consumer can resume reads directly. The pause is
    // mirrored into `activity` so the read-inactivity timeout does not reap a
    // healthy upload that we deliberately stopped reading.
    let activity = self.activity
    return RequestBodyBuffer(
      highWatermark: self.options.requestBodyHighWatermarkBytes,
      lowWatermark: self.options.requestBodyLowWatermarkBytes,
      maximumBodyBytes: self.options.maximumBodyBytes,
      setBackpressurePaused: { paused in
        activity.setBackpressurePaused(paused)
        channel.setOption(ChannelOptions.autoRead, value: !paused).whenComplete { _ in
          // An HTTP/2 stream channel only records the option, so reads stay
          // stopped, and the peer's flow-control window stays shut, until
          // something asks for one.
          if !paused { channel.read() }
        }
      },
    )
  }

  static func writeResponse(
    _ response: Response,
    version: HTTPVersion,
    channel: Channel,
    closeConnection: Bool,
  ) async throws {
    let allowsBody = Serve.responseAllowsBody(response.status)
    let explicitContentLength = Serve.firstHeaderValue(named: "content-length", in: response.headers)
    // h2 frames delimit the body and bans connection-specific headers, so the
    // HTTP/1.1 connection/transfer-encoding framing must stay off that path.
    let isHTTP1 = version.major == 1
    var headers = self.responseHeaders(
      response.headers,
      explicitContentLength: allowsBody ? explicitContentLength : nil,
      usesChunkedTransferEncoding: isHTTP1 && allowsBody && explicitContentLength == nil,
    )
    if isHTTP1 {
      if closeConnection {
        headers.replaceOrAdd(name: "connection", value: "close")
      } else if version.minor == 0 {
        headers.replaceOrAdd(name: "connection", value: "keep-alive")
      }
    }

    let head = HTTPResponseHead(
      version: version,
      status: HTTPResponseStatus(statusCode: response.status.code, reasonPhrase: response.status.reasonPhrase),
      headers: headers,
    )
    try await channel.writeAndFlush(HTTPServerResponsePart.head(head))

    guard allowsBody else {
      try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
      return
    }

    do {
      for try await chunk in response.body.asyncBytes() where !chunk.isEmpty {
        var buffer = channel.allocator.buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
      }
      try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
    } catch {
      throw ResponseBodyWriteError(underlying: error)
    }
  }

  private static func writeErrorResponse(status: Status, channel: Channel) async throws {
    let body = Data("\(status.code) \(status.reasonPhrase)\n".utf8)
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "text/plain; charset=utf-8")
    headers.add(name: "content-length", value: String(body.count))
    headers.add(name: "connection", value: "close")
    let head = HTTPResponseHead(
      version: .http1_1,
      status: HTTPResponseStatus(statusCode: status.code, reasonPhrase: status.reasonPhrase),
      headers: headers,
    )
    var buffer = channel.allocator.buffer(capacity: body.count)
    buffer.writeBytes(body)
    try await channel.writeAndFlush(HTTPServerResponsePart.head(head))
    try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
  }

  private static func responseHeaders(
    _ fields: Headers,
    explicitContentLength: String?,
    usesChunkedTransferEncoding: Bool,
  ) -> HTTPHeaders {
    var headers = HTTPHeaders()

    for field in fields {
      let rawName = field.name.rawName.lowercased()

      if rawName == "connection" || rawName == "content-length" || rawName == "transfer-encoding" {
        continue
      }

      headers.add(name: field.name.rawName, value: field.value)
    }

    if let explicitContentLength {
      headers.add(name: "content-length", value: explicitContentLength)
    } else if usesChunkedTransferEncoding {
      headers.add(name: "transfer-encoding", value: "chunked")
    }

    return headers
  }
}

// A bounded request-body sink. Chunks handed to a waiting consumer bypass the
// buffer entirely; only when the handler falls behind do bytes accumulate, and
// crossing the high watermark pauses socket reads until the drain crosses the
// low watermark again.
final class RequestBodyBuffer: Sendable {
  private struct State {
    var chunks: [Data] = []
    var bufferedBytes = 0
    var totalReceived = 0
    var finished = false
    var failure: (any Error)?
    var deliveredFailure = false
    var terminated = false
    var paused = false
    var waiter: CheckedContinuation<Data?, any Error>?
  }

  private enum YieldAction {
    case none
    case pause
    case resumeChunk(CheckedContinuation<Data?, any Error>, Data)
    case resumeThrow(CheckedContinuation<Data?, any Error>, any Error)
  }

  private let state = Mutex(State())
  private let highWatermark: Int
  private let lowWatermark: Int
  private let maximumBodyBytes: Int
  // `true` requests a read pause (buffer full); `false` resumes reads.
  private let setBackpressurePaused: @Sendable (Bool) -> Void

  init(
    highWatermark: Int,
    lowWatermark: Int,
    maximumBodyBytes: Int,
    setBackpressurePaused: @escaping @Sendable (Bool) -> Void,
  ) {
    self.highWatermark = highWatermark
    self.lowWatermark = lowWatermark
    self.maximumBodyBytes = maximumBodyBytes
    self.setBackpressurePaused = setBackpressurePaused
  }

  // Drains any unconsumed body to its end so a keep-alive connection can be
  // reused. Returns false when the body cannot be cleanly consumed within the
  // cap (oversized/errored), signalling the caller to close instead.
  func drainForKeepAlive() async -> Bool {
    guard self.state.withLock({ $0.failure == nil }) else { return false }
    do {
      while try await self.next() != nil {}
      return self.state.withLock { $0.failure == nil }
    } catch {
      return false
    }
  }

  func yield(_ chunk: Data) {
    guard !chunk.isEmpty else { return }

    let action: YieldAction = self.state.withLock { state in
      guard !state.finished, !state.terminated else { return .none }

      state.totalReceived += chunk.count
      if state.totalReceived > self.maximumBodyBytes {
        let error = ServeError.requestBodyTooLarge(limit: self.maximumBodyBytes)
        state.finished = true
        state.failure = error
        if let waiter = state.waiter {
          state.waiter = nil
          state.deliveredFailure = true
          state.terminated = true
          return .resumeThrow(waiter, error)
        }
        return .none
      }

      if let waiter = state.waiter {
        state.waiter = nil
        return .resumeChunk(waiter, chunk)
      }

      state.chunks.append(chunk)
      state.bufferedBytes += chunk.count
      if state.bufferedBytes >= self.highWatermark, !state.paused {
        state.paused = true
        return .pause
      }
      return .none
    }

    switch action {
    case .none:
      break
    case .pause:
      self.setBackpressurePaused(true)
    case let .resumeChunk(waiter, chunk):
      waiter.resume(returning: chunk)
    case let .resumeThrow(waiter, error):
      waiter.resume(throwing: error)
    }
  }

  func finish(throwing error: (any Error)? = nil) {
    let toResume: (CheckedContinuation<Data?, any Error>, (any Error)?)?
    let resumeReads: Bool
    (toResume, resumeReads) = self.state.withLock { state in
      guard !state.terminated else { return (nil, false) }
      var resume = false
      if !state.finished {
        state.finished = true
        if let error, state.failure == nil {
          state.failure = error
        }
      }
      if state.paused {
        state.paused = false
        resume = true
      }
      guard let waiter = state.waiter else {
        return (nil, resume)
      }
      state.waiter = nil
      if let failure = state.failure {
        state.deliveredFailure = true
        state.terminated = true
        return ((waiter, failure), resume)
      }
      state.terminated = true
      return ((waiter, nil), resume)
    }

    if resumeReads {
      self.setBackpressurePaused(false)
    }
    if let (waiter, error) = toResume {
      if let error {
        waiter.resume(throwing: error)
      } else {
        waiter.resume(returning: nil)
      }
    }
  }

  fileprivate func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let immediate: Immediate = self.state.withLock { state in
        Self.takeImmediate(&state, lowWatermark: self.lowWatermark)
      }

      switch immediate {
      case let .chunk(chunk, resumeReads):
        if resumeReads {
          self.setBackpressurePaused(false)
        }
        return chunk
      case .end:
        return nil
      case let .failure(error):
        throw error
      case .suspend:
        return try await withCheckedThrowingContinuation { continuation in
          let action: Immediate = self.state.withLock { state in
            let immediate = Self.takeImmediate(&state, lowWatermark: self.lowWatermark)
            if case .suspend = immediate {
              state.waiter = continuation
            }
            return immediate
          }

          switch action {
          case let .chunk(chunk, resumeReads):
            if resumeReads {
              self.setBackpressurePaused(false)
            }
            continuation.resume(returning: chunk)
          case .end:
            continuation.resume(returning: nil)
          case let .failure(error):
            continuation.resume(throwing: error)
          case .suspend:
            break
          }
        }
      }

    } onCancel: {
      self.finish(throwing: CancellationError())
    }
  }

  private static func takeImmediate(_ state: inout State, lowWatermark: Int) -> Immediate {
    if state.terminated {
      return .end
    }
    if !state.chunks.isEmpty {
      let chunk = state.chunks.removeFirst()
      state.bufferedBytes -= chunk.count
      var resumeReads = false
      if state.paused, state.bufferedBytes <= lowWatermark {
        state.paused = false
        resumeReads = true
      }
      return .chunk(chunk, resumeReads: resumeReads)
    }
    if let failure = state.failure, !state.deliveredFailure {
      state.deliveredFailure = true
      state.terminated = true
      return .failure(failure)
    }
    if state.finished {
      state.terminated = true
      return .end
    }
    return .suspend
  }

  private enum Immediate {
    case chunk(Data, resumeReads: Bool)
    case end
    case failure(any Error)
    case suspend
  }
}

struct RequestBodyStream: AsyncSequence, Sendable {
  typealias Element = Data

  let buffer: RequestBodyBuffer

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(buffer: self.buffer)
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    let buffer: RequestBodyBuffer

    mutating func next() async throws -> Data? {
      try await self.buffer.next()
    }
  }
}

// Translates IdleStateHandler events into connection closes, gated on where the
// connection is in its request cycle. Read-idle only reaps a connection that is
// still receiving a request; all-idle only reaps a parked keep-alive
// connection. Neither reaps an in-flight response, so a silent SSE client never
// trips the read timeout.
// Pipeline names for the connection-lifetime timeout handlers, so the
// WebSocket upgrade can lift them out once the connection becomes a socket.
let idleStateHandlerName = "wuhu.serve.idleState"
let idleTimeoutHandlerName = "wuhu.serve.idleTimeout"

final class IdleTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias InboundOut = HTTPServerRequestPart

  private let activity: ConnectionActivity
  private let readTimeout: TimeAmount?

  init(activity: ConnectionActivity, readTimeout: TimeAmount?) {
    self.activity = activity
    self.readTimeout = readTimeout
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    guard let idle = event as? IdleStateHandler.IdleStateEvent else {
      context.fireUserInboundEventTriggered(event)
      return
    }

    // A WebSocket-upgraded connection is a long-lived socket; HTTP idle/read
    // timeouts must never reap it.
    guard !self.activity.isUpgraded else { return }

    switch idle {
    case .read:
      // Reap a stalled request receipt, but not one paused by our own
      // backpressure, and not within an idle interval of resuming reads (whose
      // resume is asynchronous and leaves the read clock momentarily stale).
      if let readTimeout, self.activity.readIdleShouldReap(interval: readTimeout) {
        context.close(promise: nil)
      }
    case .all:
      if self.activity.allIdleShouldReap() {
        context.close(promise: nil)
      }
    case .write:
      break
    }
  }
}

private func timeAmount(_ duration: Duration) -> TimeAmount {
  let components = duration.components
  let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
  return .nanoseconds(nanoseconds)
}

private struct ResponseBodyWriteError: Error {
  let underlying: any Error
}
