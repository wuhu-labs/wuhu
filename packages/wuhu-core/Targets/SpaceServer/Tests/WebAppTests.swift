import Fetch
import Foundation
import HTTPTypes
import JSONValue
import Scratch
import SpaceServer
import Testing

private let sampleApp = WebApp(files: [
  "index.html": Data("<html>shell</html>".utf8),
  "_/favicon.ico": Data([0, 1, 2]),
  "_/manifest.webmanifest": Data("{}".utf8),
  "_/service-worker.js": Data("self".utf8),
  "_/assets/app-abc123.js": Data("console.log(1)".utf8),
  "_/assets/app-abc123.css": Data("body{}".utf8),
])!

private let bannerApp = WebApp(files: ["index.html": Data("<html><head></head><body></body></html>".utf8)])!

@Suite struct WebAppTests {
  @Test func indexServedAtRootWithNoCache() async throws {
    let harness = try Harness(webApp: sampleApp)
    let response = try await harness.get(harness.api, "/")
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/html; charset=utf-8")
    #expect(response.headers[.cacheControl] == "no-cache")
    #expect(try await response.text() == "<html>shell</html>")
  }

  @Test func theSPAsOwnFilesLiveUnderTheReservedPrefix() async throws {
    let harness = try Harness(webApp: sampleApp)
    let js = try await harness.get(harness.api, "/_/assets/app-abc123.js")
    #expect(js.status == .ok)
    #expect(js.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(js.headers[.cacheControl] == "public, max-age=31536000, immutable")
    let css = try await harness.get(harness.api, "/_/assets/app-abc123.css")
    #expect(css.headers[.contentType] == "text/css; charset=utf-8")
    let favicon = try await harness.get(harness.api, "/_/favicon.ico")
    #expect(favicon.headers[.contentType] == "image/x-icon")
    #expect(favicon.headers[.cacheControl] == "no-cache")
    let manifest = try await harness.get(harness.api, "/_/manifest.webmanifest")
    #expect(manifest.headers[.contentType] == "application/manifest+json")
    #expect(manifest.headers[.cacheControl] == "no-cache")
    let worker = try await harness.get(harness.api, "/_/service-worker.js")
    #expect(worker.headers[HTTPField.Name("Service-Worker-Allowed")!] == "/")
  }

  @Test func everyOtherPathIsASpaceFileAndGetsTheShell() async throws {
    let harness = try Harness(webApp: sampleApp)
    for path in ["/notes/deep/link.md", "/favicon.ico", "/_/assets/gone.js", "/_/sessions/s1", "/_/settings"] {
      let response = try await harness.get(harness.api, path)
      #expect(response.status == .ok)
      #expect(response.headers[.cacheControl] == "no-cache")
      #expect(try await response.text() == "<html>shell</html>", "\(path)")
    }
  }

  @Test func deepLinksWithEncodedSlashesFallBackToIndex() async throws {
    let harness = try Harness(webApp: sampleApp)
    let deepLink = try await harness.api(Request(url: URL(string: "http://space/notes%2Fdesign.md")!))
    #expect(deepLink.status == .ok)
    #expect(deepLink.headers[.contentType] == "text/html; charset=utf-8")
    #expect(try await deepLink.text() == "<html>shell</html>")
    let smuggledAsset = try await harness.api(Request(url: URL(string: "http://space/_/assets%2Fapp-abc123.js")!))
    #expect(try await smuggledAsset.text() == "<html>shell</html>")
    let api = try await harness.get(harness.api, "/v1/nope")
    #expect(api.status == .notFound)
    #expect(try await api.text() != "<html>shell</html>")
  }

  @Test func theShellCarriesTheSmartAppBannerForTheRequestedURL() async throws {
    let harness = try Harness(webApp: bannerApp)
    let session = try await harness.api(Request(url: URL(string: "https://Space.example:5530/_/sessions/zebra-forest-bike")!))
    #expect(try await session.text() == """
    <html><head><meta name="apple-itunes-app" content="app-id=6807771419, app-argument=wuhu://space.example:5530/_/sessions/zebra-forest-bike"></head><body></body></html>
    """)
    let file = try await harness.api(Request(url: URL(string: "https://box.local/notes/a%20b.md?q=1&r=2")!))
    #expect(try await file.text().contains(#"content="app-id=6807771419, app-argument=wuhu://box.local/notes/a%20b.md?q=1&amp;r=2""#))
    let malformed = try await harness.api(Request(url: URL(string: "https://box.local/a/../b")!))
    #expect(try await malformed.text().contains(#"content="app-id=6807771419">"#))
  }

  @Test func apiRoutesStayAPI() async throws {
    let harness = try Harness(webApp: sampleApp)
    let server = try await harness.get(harness.api, "/v1/server")
    #expect(server.status == .ok)
    #expect(server.headers[.contentType] == "application/json")
    let unknown = try await harness.get(harness.api, "/v1/nope")
    #expect(unknown.status == .notFound)
    #expect(try await unknown.text() != "<html>shell</html>")
  }

  @Test func noEmbeddedAssetsKeepsThe404() async throws {
    let harness = try Harness()
    let response = try await harness.get(harness.api, "/")
    #expect(response.status == .notFound)
  }

  @Test func nonDevServesTheShellButKeepsTheAPIWall() async throws {
    let harness = try Harness(dev: false, webApp: sampleApp)
    let shell = try await harness.get(harness.api, "/deep/link")
    #expect(shell.status == .ok)
    #expect(try await shell.text() == "<html>shell</html>")
    let asset = try await harness.get(harness.api, "/_/assets/app-abc123.js")
    #expect(asset.status == .ok)
    let api = try await harness.get(harness.api, "/v1/machine")
    #expect(api.status == .unauthorized)
  }

  @Test func nonDevWithoutAssetsRejectsEverything() async throws {
    let harness = try Harness(dev: false)
    let response = try await harness.get(harness.api, "/")
    #expect(response.status == .unauthorized)
  }

  @Test func webAppRequiresAnIndex() {
    #expect(WebApp(files: ["assets/app.js": Data()]) == nil)
    #expect(WebApp(files: [:]) == nil)
  }
}

@Suite struct WebAppDirectoryLoadTests {
  private func scratch() throws -> URL {
    let directory = try scratchURL("webapp")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test func loadsEveryFileRecursivelyKeyedByRelativePath() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("<html>disk</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
    try Data("console.log(2)".utf8).write(to: directory.appendingPathComponent("assets/app-xyz789.js"))
    try Data([0, 1, 2]).write(to: directory.appendingPathComponent("favicon.ico"))

    let webApp = try WebApp.load(directory: directory)
    #expect(webApp.files.count == 3)
    #expect(webApp.files["index.html"] == Data("<html>disk</html>".utf8))
    #expect(webApp.files["assets/app-xyz789.js"] == Data("console.log(2)".utf8))
    #expect(webApp.files["favicon.ico"] == Data([0, 1, 2]))
  }

  @Test func aDirectoryWithoutAnIndexFailsLoudly() throws {
    let directory = try scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("console.log(2)".utf8).write(to: directory.appendingPathComponent("app.js"))
    #expect(throws: WebApp.DirectoryLoadError.self) {
      _ = try WebApp.load(directory: directory)
    }
  }

  @Test func aMissingDirectoryFailsLoudly() throws {
    let missing = try scratchURL("missing")
    #expect(throws: WebApp.DirectoryLoadError.self) {
      _ = try WebApp.load(directory: missing)
    }
  }
}
