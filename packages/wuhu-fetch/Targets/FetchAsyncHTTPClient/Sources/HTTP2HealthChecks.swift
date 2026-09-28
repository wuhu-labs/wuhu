import AsyncHTTPClient
import NIOCore
import NIOHTTP2

extension HTTPClient.Configuration {
  public mutating func enableHTTP2HealthChecks(
    idleInterval: TimeAmount = .seconds(30),
    acknowledgementTimeout: TimeAmount = .seconds(10),
  ) {
    precondition(idleInterval > .zero)
    precondition(acknowledgementTimeout > .zero)
    let previousInitializer = http2ConnectionDebugInitializer
    http2ConnectionDebugInitializer = { channel in
      channel.eventLoop.makeCompletedFuture {
        let pipeline = channel.pipeline.syncOperations
        let codec = try pipeline.handler(type: NIOHTTP2Handler.self)
        if (try? pipeline.handler(type: HTTP2HealthCheckHandler.self)) == nil {
          try pipeline.addHandler(
            HTTP2HealthCheckHandler(
              idleInterval: idleInterval,
              acknowledgementTimeout: acknowledgementTimeout,
            ),
            position: .after(codec),
          )
        }
      }.flatMap {
        previousInitializer?(channel) ?? channel.eventLoop.makeSucceededVoidFuture()
      }
    }
  }
}
