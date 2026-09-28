import AsyncHTTPClient
import Fetch
@testable import FetchAsyncHTTPClient
import NIOCore
import NIOHTTP2
import Testing

@Suite struct TransportErrorClassificationTests {
  private struct Sentinel: Error {}

  @Test func transientHTTPClientErrorsBecomeTransportFailure() {
    let cases: [(HTTPClientError, TransportFailureKind)] = [
      (.remoteConnectionClosed, .connectionClosed),
      (.readTimeout, .readTimeout),
      (.deadlineExceeded, .deadlineExceeded),
      (.connectTimeout, .connectTimeout),
      (.getConnectionFromPoolTimeout, .poolTimeout),
    ]
    for (error, expected) in cases {
      guard case let .transportFailure(kind) = mapTransportError(error) as? FetchError else {
        Issue.record("expected transportFailure for \(error)")
        continue
      }
      #expect(kind == expected)
    }
  }

  @Test func nioChannelAndIOErrorsBecomeTransportFailure() {
    #expect(
      mapTransportError(ChannelError.ioOnClosedChannel) as? FetchError
        == .transportFailure(kind: .channel),
    )
    #expect(
      mapTransportError(IOError(errnoCode: 54, reason: "connection reset")) as? FetchError
        == .transportFailure(kind: .io),
    )
  }

  @Test func http2StreamAndConnectionDeathsBecomeConnectionClosed() {
    let deaths: [any Error] = [
      NIOHTTP2Errors.StreamClosed(streamID: HTTP2StreamID(1907), errorCode: .internalError),
      NIOHTTP2Errors.NoSuchStream(streamID: HTTP2StreamID(3)),
      NIOHTTP2Errors.IOOnClosedConnection(),
    ]
    for error in deaths {
      #expect(
        mapTransportError(error) as? FetchError == .transportFailure(kind: .connectionClosed),
        "\(error)",
      )
    }
    #expect(mapTransportError(NIOHTTP2Errors.BadClientMagic()) is NIOHTTP2Errors.BadClientMagic)
  }

  @Test func cancellationStaysCancellation() {
    #expect(mapTransportError(CancellationError()) is CancellationError)
    #expect(mapTransportError(HTTPClientError.cancelled) is CancellationError)
  }

  @Test func nonTransientErrorsPassThrough() {
    #expect(mapTransportError(Sentinel()) is Sentinel)
  }
}
