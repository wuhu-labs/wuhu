#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes

public struct S3ObjectStore: ObjectStore {
  let configuration: S3Configuration
  let fetch: FetchClient
  let now: @Sendable () -> Date

  public init(
    configuration: S3Configuration,
    fetch: FetchClient,
    now: @escaping @Sendable () -> Date = { Date() },
  ) {
    self.configuration = configuration
    self.fetch = fetch
    self.now = now
  }

  public func put(_ key: ObjectKey, body: Body) async throws {
    precondition(
      body.contentLength != nil,
      "S3ObjectStore.put requires a known Content-Length: an unknown-length body signs as UNSIGNED-PAYLOAD and sends Transfer-Encoding: chunked, which S3/R2 reject.",
    )
    let request = try self.makeRequest(
      method: .put,
      rawPath: self.configuration.rawKeyPath(key),
      queryItems: [],
      contentType: body.contentType,
      payloadHash: SigV4.unsignedPayload,
      body: body,
    )
    let response = try await self.fetch(request)
    try await self.expectSuccess(response)
  }

  public func get(_ key: ObjectKey) async throws -> GetResult {
    let request = try self.makeRequest(
      method: .get,
      rawPath: self.configuration.rawKeyPath(key),
      queryItems: [],
      contentType: nil,
      payloadHash: SigV4.emptyPayloadHash,
      body: nil,
    )
    let response = try await self.fetch(request)
    switch response.status.code {
    case 200 ... 299:
      return GetResult(body: response.body, metadata: self.metadata(from: response))
    case 404:
      try? await response.body.discard()
      throw ObjectStoreError.notFound(key)
    default:
      throw await self.statusError(response)
    }
  }

  /// A `Range` GET. Only a 206 whose `Content-Range` is the range asked for
  /// (cut at the object's end) is read; a 200 or any other range is
  /// ``ObjectStoreError/rangeNotHonored(_:_:)``. A 416 is a range past the
  /// end. An empty range is a HEAD, so a missing key still fails.
  ///
  /// A refused answer's body is never read: the response is dropped, which
  /// cancels it at the transport, so a server sending the whole object (or
  /// never ending) costs nothing past its headers.
  public func get(_ key: ObjectKey, bytes range: Range<Int64>) async throws -> Data {
    precondition(range.lowerBound >= 0, "a byte range starts at a nonnegative offset")
    guard !range.isEmpty else {
      guard try await self.head(key) != nil else { throw ObjectStoreError.notFound(key) }
      return Data()
    }
    var request = try self.makeRequest(
      method: .get,
      rawPath: self.configuration.rawKeyPath(key),
      queryItems: [],
      contentType: nil,
      payloadHash: SigV4.emptyPayloadHash,
      body: nil,
    )
    request.headers.set("range", "bytes=\(range.lowerBound)-\(range.upperBound - 1)")
    let response = try await self.fetch(request)
    let contentRange = response.headers[.contentRange]
    switch response.status.code {
    case 206:
      guard let served = contentRange.flatMap(ContentRange.init), let first = served.first, let last = served.last,
            first == range.lowerBound, last < range.upperBound, served.total.map({ last < $0 }) ?? true,
            last == range.upperBound - 1 || served.total.map({ last == $0 - 1 }) == true
      else {
        throw ObjectStoreError.rangeNotHonored(key, "206 with Content-Range \(contentRange ?? "missing")")
      }
      let expected = Int(last - first + 1)
      let data: Data
      do {
        data = try await response.body.bytes(upTo: expected)
      } catch FetchError.bodyLimitExceeded {
        throw ObjectStoreError.rangeNotHonored(key, "a body longer than Content-Range \(contentRange ?? "")")
      }
      guard data.count == expected else {
        throw ObjectStoreError.rangeNotHonored(key, "\(data.count) bytes for Content-Range \(contentRange ?? "")")
      }
      return data
    case 416:
      try? await response.body.discard()
      if let total = contentRange.flatMap(ContentRange.init)?.total, total > range.lowerBound {
        throw ObjectStoreError.rangeNotHonored(key, "416 for an object of \(total) bytes")
      }
      return Data()
    case 404:
      try? await response.body.discard()
      throw ObjectStoreError.notFound(key)
    case 200 ... 299:
      throw ObjectStoreError.rangeNotHonored(key, "status \(response.status.code)")
    default:
      throw await self.statusError(response)
    }
  }

  public func head(_ key: ObjectKey) async throws -> ObjectMetadata? {
    let request = try self.makeRequest(
      method: .head,
      rawPath: self.configuration.rawKeyPath(key),
      queryItems: [],
      contentType: nil,
      payloadHash: SigV4.emptyPayloadHash,
      body: nil,
    )
    let response = try await self.fetch(request)
    let metadata = self.metadata(from: response)
    try? await response.body.discard()
    switch response.status.code {
    case 200 ... 299:
      return metadata
    case 404:
      return nil
    default:
      throw ObjectStoreError.unexpectedStatus(code: response.status.code, message: nil)
    }
  }

  public func delete(_ key: ObjectKey) async throws {
    let request = try self.makeRequest(
      method: .delete,
      rawPath: self.configuration.rawKeyPath(key),
      queryItems: [],
      contentType: nil,
      payloadHash: SigV4.emptyPayloadHash,
      body: nil,
    )
    let response = try await self.fetch(request)
    switch response.status.code {
    case 200 ... 299, 404:
      try? await response.body.discard()
    default:
      throw await self.statusError(response)
    }
  }

  public func list(_ query: ListQuery) async throws -> ObjectListing {
    var queryItems: [(name: String, value: String)] = [
      ("list-type", "2"),
      ("prefix", query.prefix),
    ]
    if let token = query.continuationToken {
      queryItems.append(("continuation-token", token))
    }
    if let maxKeys = query.maxKeys {
      queryItems.append(("max-keys", String(maxKeys)))
    }

    let request = try self.makeRequest(
      method: .get,
      rawPath: self.configuration.rawListPath(),
      queryItems: queryItems,
      contentType: nil,
      payloadHash: SigV4.emptyPayloadHash,
      body: nil,
    )
    let response = try await self.fetch(request)
    guard (200 ... 299).contains(response.status.code) else {
      throw await self.statusError(response)
    }
    let data = try await response.body.data()
    return try S3ListParser.parse(data)
  }

  private func makeRequest(
    method: HTTPRequest.Method,
    rawPath: String,
    queryItems: [(name: String, value: String)],
    contentType: String?,
    payloadHash: String,
    body: Body?,
  ) throws -> Request {
    let stamps = SigV4Time.stamps(from: self.now())
    let host = self.configuration.host()
    let canonicalURI = SigV4.canonicalURI(path: rawPath, doubleEncode: false)
    let canonicalQuery = SigV4.canonicalQuery(queryItems)

    var signedHeaders: [SigV4.Header] = [
      SigV4.Header(name: "host", value: host),
      SigV4.Header(name: "x-amz-content-sha256", value: payloadHash),
      SigV4.Header(name: "x-amz-date", value: stamps.amzDate),
    ]
    if let contentType {
      signedHeaders.append(SigV4.Header(name: "content-type", value: contentType))
    }
    if let token = self.configuration.credentials.sessionToken {
      signedHeaders.append(SigV4.Header(name: "x-amz-security-token", value: token))
    }

    let (canonicalRequest, signedHeaderList) = SigV4.canonicalRequest(
      method: method.rawValue,
      canonicalURI: canonicalURI,
      canonicalQuery: canonicalQuery,
      headers: signedHeaders,
      payloadHash: payloadHash,
    )
    let scope = SigV4.scope(
      dateStamp: stamps.dateStamp,
      region: self.configuration.region,
      service: "s3",
    )
    let stringToSign = SigV4.stringToSign(
      amzDate: stamps.amzDate,
      scope: scope,
      canonicalRequest: canonicalRequest,
    )
    let signingKey = SigV4.signingKey(
      secretAccessKey: self.configuration.credentials.secretAccessKey,
      dateStamp: stamps.dateStamp,
      region: self.configuration.region,
      service: "s3",
    )
    let signature = SigV4.signature(signingKey: signingKey, stringToSign: stringToSign)
    let authorization = SigV4.authorizationHeader(
      accessKeyID: self.configuration.credentials.accessKeyID,
      scope: scope,
      signedHeaders: signedHeaderList,
      signature: signature,
    )

    guard let url = self.configuration.url(canonicalURI: canonicalURI, canonicalQuery: canonicalQuery) else {
      throw ObjectStoreError.malformedResponse("could not construct request URL")
    }

    var headers = RequestHeaders()
    headers.set("x-amz-content-sha256", payloadHash)
    headers.set("x-amz-date", stamps.amzDate)
    if let contentType {
      headers.set("content-type", contentType)
    }
    headers.setSensitive("authorization", authorization)
    if let token = self.configuration.credentials.sessionToken {
      headers.setSensitive("x-amz-security-token", token)
    }

    return Request(url: url, method: method, headers: headers, body: body)
  }

  /// `Content-Range: bytes first-last/total` (RFC 9110 14.4): `first`/`last`
  /// absent for `bytes */total`, `total` absent for `/*`.
  struct ContentRange: Equatable {
    var first: Int64?
    var last: Int64?
    var total: Int64?

    init?(_ value: String) {
      guard value.hasPrefix("bytes ") else { return nil }
      let parts = value.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      if parts[1] != "*" {
        guard let total = Int64(parts[1]), total >= 0 else { return nil }
        self.total = total
      }
      if parts[0] != "*" {
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]), first >= 0, first <= last else { return nil }
        self.first = first
        self.last = last
      } else if total == nil {
        return nil
      }
    }
  }

  private func metadata(from response: Response) -> ObjectMetadata {
    ObjectMetadata(
      contentLength: response.headers[.contentLength].flatMap(Int64.init),
      contentType: response.headers[.contentType],
      etag: response.headers[.eTag],
    )
  }

  private func expectSuccess(_ response: Response) async throws {
    guard (200 ... 299).contains(response.status.code) else {
      throw await self.statusError(response)
    }
    try? await response.body.discard()
  }

  private func statusError(_ response: Response) async -> ObjectStoreError {
    ObjectStoreError.unexpectedStatus(
      code: response.status.code,
      message: await self.errorMessage(response),
    )
  }

  private func errorMessage(_ response: Response, limit: Int = 8192) async -> String? {
    var collected = Data()
    do {
      for try await chunk in response.body.asyncBytes() {
        let remaining = limit - collected.count
        guard remaining > 0 else { break }
        collected.append(chunk.prefix(remaining))
        if collected.count >= limit { break }
      }
    } catch {}
    let text = String(decoding: collected, as: UTF8.self)
    return text.isEmpty ? nil : text
  }
}
