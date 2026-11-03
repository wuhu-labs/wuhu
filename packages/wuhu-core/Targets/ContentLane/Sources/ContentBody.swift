#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import Fetch
import HTTPTypes
import JSONValue
import Serve
import struct SpaceContract.GroupID
import enum SpaceContract.MediaType

/// A file's bytes as a group host serves them: the shell injected into HTML when `shell` is
/// given, tagged by `version` when it has one, and answered against the request's conditional
/// and range headers.
public func served(
  _ data: Data, contentType: String, version: String? = nil, shell: [String: Data]?, group: GroupID, headOnly: Bool, range: String?,
  ifNoneMatch: String?, ifRange: String?,
) -> Response {
  let bytes = injected(data, contentType: contentType, shell: shell, group: group)
  var headers = Headers()
  headers[.contentType] = contentType
  headers[.acceptRanges] = "bytes"
  headers[.cacheControl] = "no-cache"
  var tag: String?
  if let version {
    let current = entityTag(version, bootstrap: bytes.count != data.count ? bootstrapVersion(group) : nil)
    tag = current
    headers[.eTag] = current
    if let ifNoneMatch, matches(ifNoneMatch, current) { return Response(status: .notModified, headers: headers) }
  }
  // A range is only honoured against the representation the client holds:
  // an If-Range that is not this strong tag (a date included) gets the
  // whole body.
  let honouredRange = ifRange == nil || ifRange?.trimmingCharacters(in: .whitespaces) == tag ? range : nil
  let status: Status
  let body: Data
  switch ByteRange(header: honouredRange, length: bytes.count) {
  case .whole:
    status = .ok
    body = bytes
  case let .partial(slice):
    status = .partialContent
    body = bytes.subdata(in: bytes.startIndex + slice.lowerBound ..< bytes.startIndex + slice.upperBound + 1)
    headers[.contentRange] = "bytes \(slice.lowerBound)-\(slice.upperBound)/\(bytes.count)"
  case .unsatisfiable:
    headers[.contentRange] = "bytes */\(bytes.count)"
    headers[.contentLength] = "0"
    return Response(status: .rangeNotSatisfiable, headers: headers)
  }
  headers[.contentLength] = String(body.count)
  if headOnly { return Response(status: status, headers: headers) }
  return Response(status: status, headers: headers, body: .bytes(body, contentType: contentType))
}

/// A query result has no single revision, so its tag is a digest of the result itself.
public func revalidatedJSON(_ value: JSONValue, ifNoneMatch: String?) -> Response {
  let data = Data(value.jsonString().utf8)
  let digest = SHA256.hash(data: data).prefix(16).map { byte in
    (byte < 16 ? "0" : "") + String(byte, radix: 16)
  }
  let tag = "\"" + digest.joined() + "\""
  var headers = Headers()
  headers[.eTag] = tag
  headers[.cacheControl] = "private, no-cache"
  if let ifNoneMatch, matches(ifNoneMatch, tag) { return Response(status: .notModified, headers: headers) }
  headers[.contentType] = "application/json"
  headers[.contentLength] = String(data.count)
  return Response(status: .ok, headers: headers, body: .bytes(data, contentType: "application/json"))
}

private let drawnFlatByTheListProvider = ["wall": "list", "map": "list"]

/// The bundled view provider `/_/views/<file>` names, by asset name or with `.html` added.
public func viewAsset(_ views: [String: Data], file: String) -> (name: String, data: Data)? {
  let asset = drawnFlatByTheListProvider[file] ?? file
  return views[asset].map { (asset, $0) } ?? views[asset + ".html"].map { (asset + ".html", $0) }
}

/// The injections change the bytes without changing the file, so the tag
/// carries their version too: a new import map or shell reaches a cached page.
private func entityTag(_ version: String, bootstrap: String?) -> String {
  "\"\(version)\(bootstrap.map { "-shell-" + $0 } ?? "")\""
}

private func bootstrapVersion(_ group: GroupID) -> String {
  SHA256.hash(data: importMapInjection + groupShellInjection(group)).prefix(6).map { byte in
    (byte < 16 ? "0" : "") + String(byte, radix: 16)
  }.joined()
}

private func matches(_ ifNoneMatch: String, _ tag: String) -> Bool {
  ifNoneMatch.split(separator: ",").contains { candidate in
    let trimmed = candidate.trimmingCharacters(in: .whitespaces)
    return trimmed == "*" || trimmed == tag || trimmed == "W/" + tag
  }
}

private let shellInjection = Data(#"<script type="module" src="/_/shell.js"></script>"#.utf8)

/// A group host tells shell.js its group in a meta ahead of the script;
/// `shared.`'s bytes are unchanged.
private func groupShellInjection(_ group: GroupID) -> Data {
  guard group != .shared else { return shellInjection }
  return Data(#"<meta name="wuhu-group" content="\#(group.rawValue)">"#.utf8) + shellInjection
}

/// `wuhu:space` resolves through an import map, which must precede every
/// module a page authors, so it opens `<head>`; shell.js closes `<body>`.
private let importMapInjection = Data(#"<script type="importmap">{"imports":{"wuhu:space":"/_/space.js","wuhu:device":"/_/device.js"}}</script>"#.utf8)

public func injected(_ data: Data, contentType: String, shell: [String: Data]?, group: GroupID) -> Data {
  guard shell != nil, contentType.hasPrefix("text/html") else { return data }
  var served = data
  let injection = groupShellInjection(group)
  if let index = lastIndexOfBodyClose(data) {
    served.insert(contentsOf: injection, at: index)
  } else {
    served += injection
  }
  served.insert(contentsOf: importMapInjection, at: headStart(served))
  return served
}

/// Just past the `<head>` tag; without one, past the doctype; else the start.
private func headStart(_ data: Data) -> Data.Index {
  let bytes = [UInt8](data)
  func tagEnd(_ name: String) -> Int? {
    let needle = Array(name.utf8)
    var start = 0
    while start + needle.count <= bytes.count {
      var matched = true
      for (offset, expected) in needle.enumerated() {
        let byte = bytes[start + offset]
        if (expected.isASCIILetter ? byte | 0x20 : byte) != expected {
          matched = false
          break
        }
      }
      let next = start + needle.count
      if matched, next < bytes.count, [UInt8(ascii: ">"), UInt8(ascii: " "), 0x09, 0x0A, 0x0C, 0x0D, UInt8(ascii: "/")].contains(bytes[next]) {
        guard let close = bytes[next...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        return close + 1
      }
      start += 1
    }
    return nil
  }
  let offset = tagEnd("<head") ?? tagEnd("<!doctype") ?? 0
  return data.index(data.startIndex, offsetBy: offset)
}

private func lastIndexOfBodyClose(_ data: Data) -> Data.Index? {
  let needle = Array("</body>".utf8)
  guard data.count >= needle.count else { return nil }
  func matches(_ start: Data.Index) -> Bool {
    for (offset, expected) in needle.enumerated() {
      let byte = data[data.index(start, offsetBy: offset)]
      let lowered = expected.isASCIILetter ? byte | 0x20 : byte
      if lowered != expected { return false }
    }
    return true
  }
  var start = data.index(data.endIndex, offsetBy: -needle.count)
  while true {
    if matches(start) { return start }
    if start == data.startIndex { return nil }
    start = data.index(before: start)
  }
}

extension UInt8 {
  fileprivate var isASCIILetter: Bool {
    (self | 0x20) >= UInt8(ascii: "a") && (self | 0x20) <= UInt8(ascii: "z")
  }
}

public func resourceResponse(name: String, data: Data, cacheControl: String) -> Response {
  let contentType = mimeType(for: name)
  var headers = Headers()
  headers[.contentType] = contentType
  headers[.contentLength] = String(data.count)
  headers[.cacheControl] = cacheControl
  return Response(status: .ok, headers: headers, body: .bytes(data, contentType: contentType))
}

public func mimeType(for path: String) -> String {
  let type = MediaType.of(path: path)
  return type.hasPrefix("text/") ? type + "; charset=utf-8" : type
}
