import NIOCore
import NIOHTTP2
import NIOPosix
import NIOSSL
import Serve
import ServeTLS

extension ServeNIOServer {
  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    tls identity: TLSIdentity,
    subdomains: [String: TLSIdentity] = [:],
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handler: @escaping Handler,
  ) async throws -> Self {
    try await self.bind(
      host: host,
      port: port,
      tls: identity,
      subdomains: subdomains,
      options: options,
      hooks: hooks,
      eventLoopGroup: eventLoopGroup,
      upgrading: { .response(try await handler($0)) },
    )
  }

  /// `identity` answers every handshake except one whose SNI name is exactly
  /// one label under a `subdomains` key, which gets that key's identity (a
  /// wildcard certificate for `*.<key>`).
  public static func bind(
    host: String = "127.0.0.1",
    port: Int,
    tls identity: TLSIdentity,
    subdomains: [String: TLSIdentity] = [:],
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    upgrading handler: @escaping UpgradingHandler,
  ) async throws -> Self {
    self.validateOptions(options)
    var secureOptions = options
    secureOptions.scheme = "https"
    let options = secureOptions
    let sslContext: NIOSSLContext
    do {
      sslContext = try makeSSLContext(identity: identity, subdomains: subdomains)
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
    let state = ServeNIOServerState()
    let bootstrap = self.makeBootstrap(eventLoopGroup: eventLoopGroup, hooks: hooks, state: state) { channel, connectionID, context in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
      }.flatMap {
        channel.configureHTTP2SecureUpgrade(
          h2ChannelConfigurator: { channel in
            channel.eventLoop.makeCompletedFuture {
              _ = try channel.pipeline.syncOperations.configureHTTP2Pipeline(
                mode: .server,
                connectionConfiguration: .init(),
                streamConfiguration: .init(),
              ) { stream in
                stream.eventLoop.makeCompletedFuture {
                  try configureHTTP2Stream(
                    stream,
                    options: options,
                    hooks: hooks,
                    state: state,
                    context: context,
                    handler: handler,
                  )
                }
              }
            }
          },
          http1ChannelConfigurator: { channel in
            channel.eventLoop.makeCompletedFuture {
              try self.configureHTTP1(
                channel: channel,
                options: options,
                hooks: hooks,
                state: state,
                connectionID: connectionID,
                context: context,
                handler: handler,
              )
            }
          },
        )
      }
    }

    do {
      let serverChannel = try await bootstrap.bind(host: host, port: port).get()
      guard let boundAddress = serverChannel.localAddress else {
        try? await serverChannel.close()
        throw TLSBindError.missingBoundAddress
      }
      let server = Self(
        serverChannel: serverChannel,
        boundAddress: boundAddress,
        hooks: hooks,
        state: state,
      )
      hooks.onDidBind(boundAddress)
      return server
    } catch {
      hooks.onStartupFailure(error)
      throw error
    }
  }
}

private func makeSSLContext(identity: TLSIdentity, subdomains: [String: TLSIdentity]) throws -> NIOSSLContext {
  let (certificates, privateKey) = try sources(identity)
  var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: privateKey)
  configuration.applicationProtocols = ["h2", "http/1.1"]
  if !subdomains.isEmpty {
    var overrides: [String: NIOSSLContextConfigurationOverride] = [:]
    for (parent, subdomainIdentity) in subdomains {
      var override = NIOSSLContextConfigurationOverride()
      (override.certificateChain, override.privateKey) = try sources(subdomainIdentity)
      overrides[normalizedHostname(parent)] = override
    }
    let selected = overrides
    configuration.sslContextCallback = { values, promise in
      promise.succeed(values.serverHostname.flatMap { selected[parentHostname(of: $0)] } ?? .noChanges)
    }
  }
  return try NIOSSLContext(configuration: configuration)
}

private func sources(_ identity: TLSIdentity) throws -> ([NIOSSLCertificateSource], NIOSSLPrivateKeySource) {
  let certificates = try NIOSSLCertificate.fromPEMBytes(Array(identity.certificatePEM.utf8))
  let privateKey = try NIOSSLPrivateKey(bytes: Array(identity.privateKeyPEM.utf8), format: .pem)
  return (certificates.map { .certificate($0) }, .privateKey(privateKey))
}

private func normalizedHostname(_ name: String) -> String {
  let lowered = name.lowercased()
  return lowered.hasSuffix(".") ? String(lowered.dropLast()) : lowered
}

/// The name one label up from an SNI name, or "" for a single label.
private func parentHostname(of serverHostname: String) -> String {
  let name = normalizedHostname(serverHostname)
  guard let dot = name.firstIndex(of: "."), dot != name.startIndex else { return "" }
  return String(name[name.index(after: dot)...])
}

private func configureHTTP2Stream(
  _ stream: Channel,
  options: ServeOptions,
  hooks: ServeNIOHooks,
  state: ServeNIOServerState,
  context: ServeNIOConnectionContext,
  handler: @escaping UpgradingHandler,
) throws {
  let streamID = state.makeConnectionID()
  guard state.registerConnection(id: streamID, channel: stream) else {
    throw TLSBindError.shuttingDown
  }
  let pipeline = stream.pipeline.syncOperations
  try pipeline.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
  try pipeline.addHandler(
    ServeNIOHTTPHandler(
      options: options,
      hooks: hooks,
      context: context,
      state: state,
      connectionID: streamID,
      activity: ConnectionActivity(),
      handler: httpOnly(handler),
    ),
  )
}

private enum TLSBindError: Error {
  case missingBoundAddress
  case shuttingDown
}
