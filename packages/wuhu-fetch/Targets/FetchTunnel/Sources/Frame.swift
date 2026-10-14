#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import HTTPTypes

struct Frame: Sendable {
  enum Kind: UInt8 { case request = 1, response, chunk, end, abort }
  var kind: Kind
  var id: UInt64
  var payload: Bytes = .init()

  func encoded() -> Bytes {
    var bytes = Bytes([1, kind.rawValue])
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: id >> shift)) }
    bytes.append(payload)
    return bytes
  }

  static func decode(_ bytes: Bytes, limits: TunnelLimits) throws -> Self {
    guard bytes.count >= 10, bytes[0] == 1, let kind = Kind(rawValue: bytes[1]) else { throw TunnelError.corruptFraming }
    let id = bytes[2 ..< 10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard id != 0 else { throw TunnelError.corruptFraming }
    let size = bytes.count - 10
    let cap: Int = switch kind {
    case .request, .response: limits.headBytes
    case .chunk: limits.chunkBytes
    case .end: 0
    case .abort: 128
    }
    guard size <= cap else {
      if kind == .end { throw TunnelError.corruptFraming }
      throw StreamFault(id: id, error: kind == .chunk ? .bodyTooLarge : kind == .abort ? .protocolViolation : .headTooLarge, openingRequest: kind == .request)
    }
    return Self(kind: kind, id: id, payload: Bytes(bytes.dropFirst(10)))
  }
}

struct StreamFault: Error {
  let id: UInt64
  let error: TunnelError
  var openingRequest = false
}

struct Head: Codable, Sendable {
  var method: String?
  var url: String?
  var status: Int?
  var headers: [[String]]
  var bodyPresent: Bool
  var length: Int?

  init(_ request: Request, count: Int) {
    method = request.method.rawValue
    url = request.url.absoluteString
    var fields = request.headers
    if fields.values["content-type"] == nil, fields.sensitiveValues["content-type"] == nil, let contentType = request.body?.contentType {
      fields["content-type"] = contentType
    }
    headers = fields.values.merging(fields.sensitiveValues, uniquingKeysWith: { _, last in last })
      .sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
    bodyPresent = request.body != nil
    length = count
  }

  init(_ response: Response, count: Int) {
    status = response.status.code
    var fields = response.headers
    if fields[.contentType] == nil { fields[.contentType] = response.body.contentType }
    headers = fields.map { [$0.name.rawName, $0.value] }
    bodyPresent = true
    length = count
  }

  func fields() throws -> Headers {
    var fields = Headers()
    for pair in headers {
      guard pair.count == 2, let name = HTTPField.Name(pair[0]),
            !pair[1].utf8.contains(10), !pair[1].utf8.contains(13), !pair[1].utf8.contains(0)
      else { throw TunnelError.protocolViolation }
      fields.append(.init(name: name, value: pair[1]))
    }
    return fields
  }

  func request(body: Bytes) throws -> Request {
    guard status == nil, let method, let parsedMethod = Method(rawValue: method), let url,
          let parsedURL = URL(string: url), parsedURL.scheme != nil, parsedURL.host != nil,
          bodyPresent || (body.isEmpty && length == 0)
    else { throw TunnelError.protocolViolation }
    let fields = try fields()
    return Request(url: parsedURL, method: parsedMethod, headers: fields, body: bodyPresent ? .bytes(body, contentType: fields[.contentType]) : nil)
  }

  func response(body: Bytes) throws -> Response {
    guard method == nil, url == nil, let status, (100 ... 599).contains(status), bodyPresent else { throw TunnelError.protocolViolation }
    let fields = try fields()
    return Response(status: .init(code: status), headers: fields, body: .bytes(body, contentType: fields[.contentType]))
  }
}

func frames(id: UInt64, kind: Frame.Kind, head: Head, body: Bytes, limits: TunnelLimits) throws -> [Frame] {
  let bytes = try JSONEncoder().encode(head)
  guard bytes.count <= limits.headBytes else { throw TunnelError.headTooLarge }
  var result = [Frame(kind: kind, id: id, payload: bytes)]
  var offset = 0
  while offset < body.count {
    let end = min(body.count, offset + limits.chunkBytes)
    result.append(Frame(kind: .chunk, id: id, payload: Bytes(body[offset ..< end])))
    offset = end
  }
  result.append(Frame(kind: .end, id: id))
  return result
}
