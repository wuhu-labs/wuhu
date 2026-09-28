#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import AsyncHTTPClient
import Fetch
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTP2

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FetchClient {
  public static func asyncHTTPClient(
    _ client: HTTPClient,
    timeout: TimeAmount? = .seconds(30),
  ) -> Self {
    Self { request in
      var clientRequest = HTTPClientRequest(url: request.url.absoluteString)
      clientRequest.method = HTTPMethod(rawValue: request.method.rawValue)

      for field in request.headers.fields {
        clientRequest.headers.add(name: field.name.rawName, value: field.value)
      }
      for (name, value) in request.headers.sensitiveValues {
        clientRequest.headers.add(name: name, value: value)
      }

      if let body = request.body {
        if clientRequest.headers["content-type"].isEmpty, let contentType = body.contentType {
          clientRequest.headers.add(name: "content-type", value: contentType)
        }

        clientRequest.body = .stream(
          RequestBodySequence(stream: body.asyncBytes()),
          length: body.contentLength.map(HTTPClientRequest.Body.Length.known) ?? .unknown,
        )
      }

      let response: HTTPClientResponse
      do {
        response = try await client.execute(
          clientRequest,
          deadline: timeout.map { .now() + $0 } ?? .distantFuture,
        )
      } catch {
        throw mapTransportError(error)
      }
      let headers = Headers(response.headers)

      return Response(
        status: Status(code: Int(response.status.code), reasonPhrase: response.status.reasonPhrase),
        headers: headers,
        body: .stream(
          length: firstHeaderValue(named: "content-length", in: headers).flatMap(Int64.init),
          contentType: firstHeaderValue(named: "content-type", in: headers),
          ResponseBodySequence(base: response.body),
        ),
      )
    }
  }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct RequestBodySequence: AsyncSequence, Sendable {
  typealias Element = ByteBuffer

  let stream: BodyStream

  func makeAsyncIterator() -> Iterator {
    Iterator(base: self.stream.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: BodyStream.AsyncIterator

    mutating func next() async throws -> ByteBuffer? {
      guard let bytes = try await self.base.next() else {
        return nil
      }
      return ByteBuffer(bytes: bytes)
    }
  }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private struct ResponseBodySequence: AsyncSequence, Sendable {
  typealias Element = Bytes

  let base: HTTPClientResponse.Body

  func makeAsyncIterator() -> Iterator {
    Iterator(base: self.base.makeAsyncIterator())
  }

  struct Iterator: AsyncIteratorProtocol {
    var base: HTTPClientResponse.Body.AsyncIterator

    mutating func next() async throws -> Bytes? {
      let buffer: ByteBuffer?
      do {
        buffer = try await self.base.next()
      } catch {
        throw mapTransportError(error)
      }
      guard let buffer else { return nil }
      return Data(buffer.readableBytesView)
    }
  }
}

// AsyncHTTPClient/NIO transport failures are Swift structs foreign to the Fetch
// error vocabulary; a retryable network failure is restated as
// `FetchError.transportFailure` so callers classify it without importing NIO.
// Cancellation stays cancellation, and non-transient client errors (bad URL,
// length mismatch) pass through unchanged so they remain terminal.
func mapTransportError(_ error: any Error) -> any Error {
  if error is CancellationError { return error }
  if let clientError = error as? HTTPClientError {
    if clientError == .cancelled { return CancellationError() }
    let transient: [(HTTPClientError, TransportFailureKind)] = [
      (.remoteConnectionClosed, .connectionClosed),
      (.readTimeout, .readTimeout),
      (.deadlineExceeded, .deadlineExceeded),
      (.connectTimeout, .connectTimeout),
      (.getConnectionFromPoolTimeout, .poolTimeout),
    ]
    if let match = transient.first(where: { $0.0 == clientError }) {
      return FetchError.transportFailure(kind: match.1)
    }
    return error
  }
  // An HTTP/2 stream or connection dying under a request is the h2 spelling
  // of remoteConnectionClosed; a fresh connection is the only cure.
  if error is NIOHTTP2Errors.StreamClosed
    || error is NIOHTTP2Errors.NoSuchStream
    || error is NIOHTTP2Errors.IOOnClosedConnection
  {
    return FetchError.transportFailure(kind: .connectionClosed)
  }
  if error is ChannelError {
    return FetchError.transportFailure(kind: .channel)
  }
  if error is IOError {
    return FetchError.transportFailure(kind: .io)
  }
  return error
}

private extension Headers {
  init(_ headers: HTTPHeaders) {
    self.init()

    for header in headers {
      if let fieldName = HTTPField.Name(header.name) {
        self[fieldName] = header.value
      }
    }
  }
}

private func firstHeaderValue(named rawName: String, in headers: Headers) -> String? {
  for field in headers where field.name.rawName.lowercased() == rawName.lowercased() {
    return field.value
  }
  return nil
}
