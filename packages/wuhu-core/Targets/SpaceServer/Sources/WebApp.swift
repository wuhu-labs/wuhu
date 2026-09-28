#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import HTTPTypes
import Serve
import struct SpaceContract.SpaceURL

public struct WebApp: Sendable {
  public let files: [String: Data]

  public init?(files: [String: Data]) {
    guard files["index.html"] != nil else { return nil }
    self.files = files
  }

  #if WUHU_EMBEDDED
    public static let embedded: WebApp? = WebApp(files: Dictionary(
      uniqueKeysWithValues: EmbeddedWebApp.files.map { file in
        (file.path.joined(separator: "/"), Data(EmbeddedWebApp.bytes(for: file)))
      },
    ))
  #else
    public static let embedded: WebApp? = nil
  #endif

  public struct DirectoryLoadError: Error, CustomStringConvertible {
    public let description: String
  }

  public static func load(directory: URL) throws -> WebApp {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
      throw DirectoryLoadError(description: "web app directory not readable: \(directory.path)")
    }
    var files: [String: Data] = [:]
    while let relative = enumerator.nextObject() as? String {
      let file = directory.appendingPathComponent(relative)
      if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
      files[relative] = try Data(contentsOf: file)
    }
    guard let webApp = WebApp(files: files) else {
      throw DirectoryLoadError(description: "web app directory has no index.html: \(directory.path)")
    }
    return webApp
  }
}

// Fails closed: an unparsable path stays behind the auth wall.
func isAPIPath(_ url: URL) -> Bool {
  guard let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return true }
  guard let first = rawPath.split(separator: "/", omittingEmptySubsequences: true).first else { return false }
  return String(first).removingPercentEncoding.map { $0 == "v1" } ?? true
}

func webAppResponse(_ webApp: WebApp, request: Request) -> Response {
  guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
    return plainStatus(.badRequest)
  }
  var segments: [String] = []
  for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true) {
    guard let decoded = String(raw).removingPercentEncoding else { return plainStatus(.badRequest) }
    segments.append(decoded)
  }
  if segments.first == "v1" { return plainStatus(.notFound) }
  // Every path outside /_/ names a space file and gets the shell. A decoded
  // slash (%2F) must not smuggle extra structure into the asset lookup.
  if segments.first == "_", segments.allSatisfy({ !$0.contains("/") }) {
    let path = segments.joined(separator: "/")
    if let data = webApp.files[path] {
      var headers = staticHeaders(path: path, length: data.count)
      headers[.cacheControl] = segments.dropFirst().first == "assets" ? "public, max-age=31536000, immutable" : "no-cache"
      if path == "_/service-worker.js" { headers[serviceWorkerAllowed] = "/" }
      return Response(status: .ok, headers: headers, body: .bytes(data, contentType: mimeType(for: path)))
    }
  }
  return shellResponse(webApp, components: components)
}

private let appStoreID = "6807771419"
private let serviceWorkerAllowed = HTTPField.Name("Service-Worker-Allowed")!

private func shellResponse(_ webApp: WebApp, components: URLComponents) -> Response {
  var shell = String(decoding: webApp.files["index.html"]!, as: UTF8.self)
  if let head = shell.firstRange(of: "</head>") {
    shell.insert(contentsOf: "<meta name=\"apple-itunes-app\" content=\"\(escaped(smartBanner(components)))\">", at: head.lowerBound)
  }
  let data = Data(shell.utf8)
  var headers = staticHeaders(path: "index.html", length: data.count)
  headers[.cacheControl] = "no-cache"
  return Response(status: .ok, headers: headers, body: .bytes(data, contentType: mimeType(for: "index.html")))
}

private func smartBanner(_ components: URLComponents) -> String {
  let authority = (components.percentEncodedHost ?? "") + (components.port.map { ":\($0)" } ?? "")
  let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
  guard let host = SpaceURL.host(origin: "https://\(authority)"),
        let url = SpaceURL("https://\(host)\(components.percentEncodedPath)\(query)")
  else { return "app-id=\(appStoreID)" }
  return "app-id=\(appStoreID), app-argument=\(url.formatted(.wuhu))"
}

private func staticHeaders(path: String, length: Int) -> Headers {
  var headers = Headers()
  headers[.contentType] = mimeType(for: path)
  headers[.contentLength] = String(length)
  return headers
}
