#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import NIOHTTP1
import Serve

struct ParsedRequestHead {
  var method: Fetch.Method
  var url: URL
  var headers: Headers
  var contentType: String?
  var contentLength: Int?
  var isChunked: Bool
}

enum RequestHeadParser {
  static func validateLimits(_ head: HTTPRequestHead, options: ServeOptions) throws {
    let requestLineBytes = "\(head.method.rawValue) \(head.uri) HTTP/\(head.version.major).\(head.version.minor)\r\n".utf8.count
    guard requestLineBytes <= options.maximumHeaderLineBytes else {
      throw ServeError.headerLineTooLarge(limit: options.maximumHeaderLineBytes)
    }

    var totalHeadBytes = requestLineBytes + 2
    for (name, value) in head.headers {
      let lineBytes = name.utf8.count + 2 + value.utf8.count + 2
      guard lineBytes <= options.maximumHeaderLineBytes else {
        throw ServeError.headerLineTooLarge(limit: options.maximumHeaderLineBytes)
      }
      totalHeadBytes += lineBytes
      guard totalHeadBytes <= options.maximumHeadBytes else {
        throw ServeError.headersTooLarge(limit: options.maximumHeadBytes)
      }
    }

    guard totalHeadBytes <= options.maximumHeadBytes else {
      throw ServeError.headersTooLarge(limit: options.maximumHeadBytes)
    }
  }

  static func parse(_ head: HTTPRequestHead, options: ServeOptions) throws -> ParsedRequestHead {
    guard head.version.major == 1 || head.version.major == 2 else {
      throw ServeError.unsupportedHTTPVersion("\(head.version.major).\(head.version.minor)")
    }

    var headers = Headers()
    var headerCount = 0
    for header in head.headers {
      headerCount += 1
      guard headerCount <= options.maximumHeaderCount else {
        throw ServeError.tooManyHeaders(limit: options.maximumHeaderCount)
      }
      if let name = HTTPField.Name(header.name) {
        headers.append(HTTPField(name: name, value: header.value))
      }
    }

    let hostValues = head.headers["host"]
    guard hostValues.count <= 1 else {
      throw ServeError.duplicateHeader("host")
    }
    guard let host = hostValues.first, !host.isEmpty else {
      throw ServeError.missingHostHeader
    }

    let contentLengthValues = head.headers["content-length"]
    guard contentLengthValues.count <= 1 else {
      throw ServeError.duplicateHeader("content-length")
    }
    let contentLength = try contentLengthValues.first.map { value in
      guard let length = Int(value), length >= 0 else {
        throw ServeError.invalidContentLength
      }
      return length
    }

    let transferEncoding = head.headers["transfer-encoding"].last
    if contentLength != nil, transferEncoding != nil {
      throw ServeError.conflictingBodyHeaders
    }

    if let transferEncoding, transferEncoding.lowercased() != "chunked" {
      throw ServeError.unsupportedTransferEncoding(transferEncoding)
    }

    if let contentLength, contentLength > options.maximumBodyBytes {
      throw ServeError.requestBodyTooLarge(limit: options.maximumBodyBytes)
    }

    guard let method = Fetch.Method(rawValue: head.method.rawValue) else {
      throw ServeError.invalidRequestLine
    }

    return ParsedRequestHead(
      method: method,
      url: try Serve.requestURL(target: head.uri, method: method, host: host, options: options),
      headers: headers,
      contentType: Serve.firstHeaderValue(named: "content-type", in: headers),
      contentLength: contentLength,
      isChunked: transferEncoding != nil,
    )
  }
}
