import Assertion
import Crypto
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SessionDomain
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct WebOriginTests {
  let injection = #"<script type="module" src="/_/shell.js"></script>"#
  let importMap = #"<script type="importmap">{"imports":{"wuhu:space":"/_/space.js"}}</script>"#

  @Test func servesFilesWithMimeByExtension() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/style.css", "content": "body {}"]))
    _ = try await harness.direct("write", .object(["path": "/app.js", "content": "1"]))
    _ = try await harness.direct("write", .object(["path": "/data.bin", "content": "x"]))

    let css = try await harness.get(harness.web, "/style.css")
    #expect(css.status == .ok)
    #expect(css.headers[.contentType] == "text/css; charset=utf-8")
    #expect(try await css.text() == "body {}")

    let js = try await harness.get(harness.web, "/app.js")
    #expect(js.headers[.contentType] == "text/javascript; charset=utf-8")

    let bin = try await harness.get(harness.web, "/data.bin")
    #expect(bin.headers[.contentType] == "application/octet-stream")

    let missing = try await harness.get(harness.web, "/nope.css")
    #expect(missing.status == .notFound)
  }

  // Safari and iOS play a video only from a server that answers ranges.
  @Test func aRangeRequestGetsThoseBytesAndAnUnsatisfiableOneGets416() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/clip.mp4", "content": "0123456789"]))
    func fetch(_ range: String?) async throws -> Response {
      var request = Request(url: URL(string: "http://space/clip.mp4")!)
      if let range { request.headers[.range] = range }
      return try await harness.web(request)
    }

    let whole = try await fetch(nil)
    #expect(whole.status == .ok)
    #expect(whole.headers[.acceptRanges] == "bytes")
    #expect(whole.headers[.contentType] == "video/mp4")

    let middle = try await fetch("bytes=2-5")
    #expect(middle.status.code == 206)
    #expect(middle.headers[.contentRange] == "bytes 2-5/10")
    #expect(middle.headers[.contentLength] == "4")
    #expect(try await middle.text() == "2345")

    let open = try await fetch("bytes=7-")
    #expect(open.headers[.contentRange] == "bytes 7-9/10")
    #expect(try await open.text() == "789")

    let suffix = try await fetch("bytes=-3")
    #expect(suffix.headers[.contentRange] == "bytes 7-9/10")

    let clamped = try await fetch("bytes=8-100")
    #expect(clamped.headers[.contentRange] == "bytes 8-9/10")

    let beyond = try await fetch("bytes=10-")
    #expect(beyond.status.code == 416)
    #expect(beyond.headers[.contentRange] == "bytes */10")

    let ignored = try await fetch("bytes=0-1,4-5")
    #expect(ignored.status == .ok)
    #expect(try await ignored.text() == "0123456789")
  }

  @Test func filesRevalidateByRevision() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/_/sessions/s1/avatar.png", "content": "one"]))

    let first = try await harness.get(harness.web, "/_/sessions/s1/avatar.png")
    #expect(first.headers[.cacheControl] == "no-cache")
    let tag = try #require(first.headers[.eTag])

    func revalidate(_ header: String) async throws -> Response {
      var headers = RequestHeaders()
      headers[.ifNoneMatch] = header
      return try await harness.web(Request(url: URL(string: "http://space/_/sessions/s1/avatar.png")!, headers: headers))
    }
    let unchanged = try await revalidate(tag)
    #expect(unchanged.status == .notModified)
    #expect(unchanged.headers[.eTag] == tag)
    #expect(try await unchanged.text() == "")
    #expect(try await revalidate("\"0\", W/\(tag)").status == .notModified)

    _ = try await harness.direct("write", .object(["path": "/_/sessions/s1/avatar.png", "content": "two"]))
    let changed = try await revalidate(tag)
    #expect(changed.status == .ok)
    #expect(changed.headers[.eTag] != tag)
    #expect(try await changed.text() == "two")

    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<p>x</p>"]))
    let page = try await harness.get(harness.web, "/page.html")
    #expect(page.headers[.eTag]?.range(of: #"-shell-[0-9a-f]{12}"$"#, options: .regularExpression) != nil)
  }

  @Test func aRangeIsHonouredOnlyForTheTagTheClientHolds() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/clip.mp4", "content": "0123456789"]))
    let tag = try #require(try await harness.get(harness.web, "/clip.mp4").headers[.eTag])
    func fetch(ifRange: String) async throws -> Response {
      var request = Request(url: URL(string: "http://space/clip.mp4")!)
      request.headers[.range] = "bytes=2-5"
      request.headers[.ifRange] = ifRange
      return try await harness.web(request)
    }

    let held = try await fetch(ifRange: tag)
    #expect(held.status.code == 206)
    #expect(try await held.text() == "2345")

    let stale = try await fetch(ifRange: "\"0\"")
    #expect(stale.status == .ok)
    #expect(stale.headers[.contentRange] == nil)
    #expect(try await stale.text() == "0123456789")

    let dated = try await fetch(ifRange: "Sat, 26 Sep 2026 06:00:00 GMT")
    #expect(dated.status == .ok)
    #expect(try await dated.text() == "0123456789")
  }

  @Test func aHeadRevalidatesLikeAGet() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/style.css", "content": "p {}"]))
    let tag = try #require(try await harness.get(harness.web, "/style.css").headers[.eTag])
    var headers = RequestHeaders()
    headers[.ifNoneMatch] = tag
    let head = try await harness.web(Request(url: URL(string: "http://space/style.css")!, method: .head, headers: headers))
    #expect(head.status == .notModified)
    #expect(head.headers[.eTag] == tag)
    #expect(try await head.text() == "")
  }

  @Test func aDirectoryListingCarriesNoTag() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/d/a.txt", "content": "a"]))
    let listing = try await harness.get(harness.web, "/d/")
    #expect(listing.status == .ok)
    #expect(listing.headers[.eTag] == nil)
    #expect(listing.headers[.cacheControl] == "no-cache")
  }

  @Test func directoryIndexPrecedenceHtmlOverMd() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/index.md", "content": "# md root"]))
    _ = try await harness.direct("write", .object(["path": "/docs/index.md", "content": "# docs"]))
    _ = try await harness.direct("write", .object(["path": "/both/index.html", "content": "<h1>html</h1>"]))
    _ = try await harness.direct("write", .object(["path": "/both/index.md", "content": "# md"]))

    let root = try await harness.get(harness.web, "/")
    #expect(root.headers[.contentType] == "text/markdown; charset=utf-8")
    #expect(try await root.text() == "# md root")

    let docs = try await harness.get(harness.web, "/docs")
    #expect(docs.status == .ok)
    #expect(try await docs.text() == "# docs")

    let both = try await harness.get(harness.web, "/both")
    #expect(both.headers[.contentType] == "text/html; charset=utf-8")
    #expect(try await both.text() == importMap + "<h1>html</h1>" + injection)

    let missing = try await harness.get(harness.web, "/missing-dir")
    #expect(missing.status == .notFound)
  }

  @Test func directoryWithoutAnIndexListsEntriesAsShellLinks() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/d/b.md", "content": "b"]))
    _ = try await harness.direct("write", .object(["path": "/d/sub/keep.md", "content": "k"]))
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/d/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )

    let response = try await harness.get(harness.web, "/d")
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/html; charset=utf-8")
    let body = try await response.text()
    #expect(response.headers[.contentLength] == String(body.utf8.count))
    #expect(body.contains(#"href="/d/sub""#))
    #expect(body.contains(#"href="/d/b.md""#))
    #expect(body.contains(#"href="/d/t.table""#))
    #expect(body.contains(">sub<"))
    #expect(body.contains(">b.md<"))
    #expect(body.contains(">t.table<"))
    #expect(body.contains(#"href="/""#))
    #expect(body.contains(">..<"))
    #expect(body.contains(injection + "</body>"))

    let directory = try #require(body.range(of: #"href="/d/sub""#))
    let file = try #require(body.range(of: #"href="/d/b.md""#))
    let table = try #require(body.range(of: #"href="/d/t.table""#))
    #expect(directory.lowerBound < file.lowerBound)
    #expect(file.lowerBound < table.lowerBound)

    let head = try await harness.web(Request(url: URL(string: "http://space/d")!, method: .head))
    #expect(head.status == .ok)
    #expect(head.headers[.contentType] == "text/html; charset=utf-8")
    #expect(head.headers[.contentLength] == response.headers[.contentLength])
    #expect(try await head.text() == "")
  }

  @Test func rootWithoutAnIndexListsHiddenEntriesAndHasNoParentLink() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/notes.md", "content": "n"]))
    _ = try await harness.direct("write", .object(["path": "/.agents/skill.md", "content": "s"]))

    let response = try await harness.get(harness.web, "/")
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "text/html; charset=utf-8")
    let body = try await response.text()
    #expect(body.contains(#"href="/.agents""#))
    #expect(body.contains(#"href="/notes.md""#))
    #expect(!body.contains(">..<"))
    #expect(body.contains(injection + "</body>"))

    let nested = try await harness.get(harness.web, "/.agents")
    #expect(nested.status == .ok)
    #expect(try await nested.text().contains(#"href="/.agents/skill.md""#))
  }

  @Test func emptyDirectoryRendersTheEmptyLine() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/hollow/x.md", "content": "x"]))
    _ = try await harness.direct("rm", .object(["path": "/hollow/x.md"]))

    let response = try await harness.get(harness.web, "/hollow")
    #expect(response.status == .ok)
    let body = try await response.text()
    #expect(body.contains("Empty directory"))
    #expect(body.contains(">..<"))
    #expect(!body.contains("x.md"))
  }

  @Test func listingEscapesAndPercentEncodesEntryNames() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": #"/esc/a <b> & "c" +d.md"#, "content": "x"]))

    let response = try await harness.get(harness.web, "/esc")
    #expect(response.status == .ok)
    let body = try await response.text()
    #expect(body.contains(#"href="/esc/a%20%3Cb%3E%20%26%20%22c%22%20%2Bd.md""#))
    #expect(body.contains(#">a &lt;b&gt; &amp; &quot;c&quot; +d.md<"#))
    #expect(!body.contains("<b>"))
  }

  @Test func underscoreQueryReturnsQueryOutput() async throws {
    let harness = try Harness()
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )
    _ = try await harness.direct(
      "table.mutate",
      .object(["path": "/t.table", "ops": .array([.object(["kind": "insert", "values": .array([.integer(42)])])])]),
    )

    let response = try await harness.get(harness.web, "/_/query", query: ["sql": "SELECT n FROM \"/t.table\""])
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "application/json")
    let output = try JSONValueDecoder().decode(QueryOutput.self, from: try await json(response))
    #expect(output.columns == ["n"])
    #expect(output.rows == [[.integer(42)]])

    let bad = try await harness.get(harness.web, "/_/query", query: ["sql": "DELETE FROM docs"])
    #expect(bad.status.code == 422)

    let unknown = try await harness.get(harness.web, "/_/nope")
    #expect(unknown.status == .notFound)
  }

  @Test func sessionHomesAndAttachmentsServeAsFilesWhileTheRestOfUnderscoreStaysReserved() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/_/sessions/s1/notes.css", "content": "body {}"]))
    let conversation = try await harness.space.sessions.createConversation(members: ["owner"], in: .shared)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let delivery = try await harness.space.sessions.post(
      .conversation(conversation),
      messageID: MessageID("m1"),
      sender: Sender(id: "owner", timeZone: .gmt),
      content: MessageContent(text: "look"),
      uploads: [AttachmentUpload(name: "shot.png", bytes: [UInt8](png))],
    )
    let path = try #require(delivery.message.content.attachments.first?.path)

    let home = try await harness.get(harness.web, "/_/sessions/s1/notes.css")
    #expect(home.status == .ok)
    #expect(try await home.text() == "body {}")

    let attachment = try await harness.get(harness.web, path)
    #expect(attachment.status == .ok)
    #expect(attachment.headers[.contentType] == "image/png")

    let reserved = try await harness.get(harness.web, "/_/blobs/\(String(repeating: "0", count: 64))")
    #expect(reserved.status == .notFound)
  }

  @Test func aDownloadQueryAnswersTheRawBytesAsAnAttachment() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/out/café build.html", "content": "<main>x</main>"]))

    let download = try await harness.get(harness.web, "/out/café build.html", query: ["download": "1"])
    #expect(download.status == .ok)
    #expect(download.headers[HTTPField.Name("Content-Disposition")!] == "attachment; filename*=UTF-8''caf%C3%A9%20build.html")
    #expect(try await download.text() == "<main>x</main>")

    let page = try await harness.get(harness.web, "/out/café build.html")
    #expect(page.headers[HTTPField.Name("Content-Disposition")!] == nil)
    #expect(try await page.text() == importMap + "<main>x</main>" + injection)
  }

  @Test func machineNotesServeUnderTheNameAndTheId() async throws {
    let harness = try Harness()
    let id = try await harness.space.addMachine(name: "studio").id.rawValue
    _ = try await harness.direct("write", .object(["path": "/_/machines/studio/AGENTS.md", "content": "studio manual"]))

    for path in ["/_/machines/studio/AGENTS.md", "/_/machines/\(id)/AGENTS.md"] {
      let notes = try await harness.get(harness.web, path)
      #expect(notes.status == .ok)
      #expect(try await notes.text() == "studio manual")
    }
    let listing = try await harness.get(harness.web, "/_/machines/")
    #expect(listing.status == .ok)
    let body = try await listing.text()
    #expect(body.contains("studio") && !body.contains(id))
    #expect(try await harness.get(harness.web, "/_/machines/ghost/AGENTS.md").status == .notFound)
  }

  @Test func methodsOtherThanGetHeadAreRejected() async throws {
    let harness = try Harness()
    let response = try await harness.web(Request(url: URL(string: "http://space/index.md")!, method: .post))
    #expect(response.status == .methodNotAllowed)
  }

  @Test func headIsSupportedOnContentAndUnderscoreRoutes() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/style.css", "content": "body {}"]))
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )

    let content = try await harness.web(Request(url: URL(string: "http://space/style.css")!, method: .head))
    #expect(content.status == .ok)
    #expect(content.headers[.contentType] == "text/css; charset=utf-8")
    #expect(try await content.text() == "")

    var components = URLComponents(string: "http://space/_/query")!
    components.queryItems = [URLQueryItem(name: "sql", value: "SELECT n FROM \"/t.table\"")]
    let query = try await harness.web(Request(url: components.url!, method: .head))
    #expect(query.status == .ok)
    #expect(query.headers[.contentType] == "application/json")
    #expect(try await query.text() == "")
  }

  @Test func shellSDKIsBundledNoCacheAndHeadHasTheServedLength() async throws {
    let harness = try Harness()
    let script = try await harness.get(harness.web, "/_/shell.js")
    #expect(script.status == .ok)
    #expect(script.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(script.headers[.cacheControl] == "no-cache")
    let body = try await script.text()
    #expect(body.contains("export const context"))
    #expect(body.contains("export function interceptedNavigation"))
    #expect(body.contains("wuhu:ready"))
    #expect(body.contains("wuhu:context"))
    #expect(body.contains("wuhu:navigate"))
    // One served file carries both shell transports; a native app that had to
    // ship its own copy would be a second contract.
    #expect(body.contains("parent.postMessage"))
    #expect(body.contains("messageHandlers?.wuhuShell"))
    #expect(body.contains("--wuhu-inset-${edge}"))

    let head = try await harness.web(Request(url: URL(string: "http://space/_/shell.js")!, method: .head))
    #expect(head.status == .ok)
    #expect(head.headers[.contentLength] == String(body.utf8.count))
    #expect(head.headers[.cacheControl] == "no-cache")
    #expect(try await head.text() == "")
  }

  @Test func thePageWorkerAndItsModulesAreServedNoCacheWithRootScope() async throws {
    let harness = try Harness()
    let worker = try await harness.get(harness.web, "/_/worker.js")
    #expect(worker.status == .ok)
    #expect(worker.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(worker.headers[.cacheControl] == "no-cache")
    #expect(worker.headers[HTTPField.Name("Service-Worker-Allowed")!] == "/")
    #expect(try await worker.text().contains("export function pageWorker"))

    let module = try await harness.get(harness.web, "/_/open-cache.js")
    #expect(module.status == .ok)
    #expect(module.headers[.cacheControl] == "no-cache")
    #expect(module.headers[HTTPField.Name("Service-Worker-Allowed")!] == nil)
    #expect(try await harness.get(harness.web, "/_/open-cache.d.ts").status == .notFound)
  }

  @Test func queryResultsCarryADigestTagAndRevalidate() async throws {
    let harness = try Harness()
    _ = try await harness.direct(
      "table.create",
      .object(["path": "/t.table", "header": .object(["columns": .array([.object(["name": "n", "type": "integer"])])])]),
    )
    func insert(_ n: Int) async throws {
      _ = try await harness.direct(
        "table.mutate",
        .object(["path": "/t.table", "ops": .array([.object(["kind": "insert", "values": .array([.integer(n)])])])]),
      )
    }
    try await insert(1)
    let sql = ["sql": "SELECT n FROM \"/t.table\""]

    let first = try await harness.get(harness.web, "/_/query", query: sql)
    #expect(first.status == .ok)
    // What a query answers depends on who asks, so no shared cache keeps it.
    #expect(first.headers[.cacheControl] == "private, no-cache")
    let tag = try #require(first.headers[.eTag])
    #expect(tag.hasPrefix("\"") && tag.count == 34)

    var components = URLComponents(string: "http://space/_/query")!
    components.queryItems = [URLQueryItem(name: "sql", value: sql["sql"])]
    var headers = RequestHeaders()
    headers[.ifNoneMatch] = tag
    let unchanged = try await harness.web(Request(url: components.url!, headers: headers))
    #expect(unchanged.status == .notModified)
    #expect(unchanged.headers[.eTag] == tag)
    #expect(try await unchanged.text() == "")

    try await insert(2)
    let changed = try await harness.web(Request(url: components.url!, headers: headers))
    #expect(changed.status == .ok)
    #expect(changed.headers[.eTag] != tag)
  }

  @Test func everyHTMLResponseIsInjectedAndLengthsDescribeTransformedBytes() async throws {
    let providers = ViewProviders(files: ["owned.html": Data("<main>owned</main>".utf8)])
    let harness = try Harness(views: providers)
    _ = try await harness.direct("write", .object(["path": "/page.html", "content": "<main>authored</main>"]))
    _ = try await harness.direct("write", .object(["path": "/already.html", "content": .string(injection)]))
    _ = try await harness.direct("write", .object(["path": "/plain.txt", "content": "plain"]))

    let authored = try await harness.get(harness.web, "/page.html")
    let authoredBody = try await authored.text()
    #expect(authoredBody == importMap + "<main>authored</main>" + injection)
    #expect(authored.headers[.contentLength] == String(authoredBody.utf8.count))

    let owned = try await harness.get(harness.web, "/_/views/owned")
    let ownedBody = try await owned.text()
    #expect(ownedBody == importMap + "<main>owned</main>" + injection)
    #expect(owned.headers[.contentLength] == String(ownedBody.utf8.count))

    let cooperative = try await harness.get(harness.web, "/already.html")
    #expect(try await cooperative.text() == importMap + injection + injection)

    _ = try await harness.direct(
      "write",
      .object(["path": "/full.html", "content": "<html><body><code></body></code><p>hi</p></BODY></html>"]),
    )
    let full = try await harness.get(harness.web, "/full.html")
    let fullBody = try await full.text()
    #expect(fullBody == importMap + "<html><body><code></body></code><p>hi</p>" + injection + "</BODY></html>")
    #expect(full.headers[.contentLength] == String(fullBody.utf8.count))

    let plain = try await harness.get(harness.web, "/plain.txt")
    #expect(try await plain.text() == "plain")

    let head = try await harness.web(Request(url: URL(string: "http://space/page.html")!, method: .head))
    #expect(head.headers[.contentLength] == String(authoredBody.utf8.count))
    #expect(try await head.text() == "")
  }

  @Test func percentEncodedSegmentsDecodeButCannotSmuggleSlashes() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/café notes.md", "content": "unicode"]))
    _ = try await harness.direct("write", .object(["path": "/a/b.md", "content": "nested"]))

    let encoded = try await harness.web(Request(url: URL(string: "http://space/caf%C3%A9%20notes.md")!))
    #expect(encoded.status == .ok)
    #expect(try await encoded.text() == "unicode")

    let smuggled = try await harness.web(Request(url: URL(string: "http://space/a%2Fb.md")!))
    #expect(smuggled.status == .notFound)
  }

  @Test func trailingSlashOnAFilePathIs404() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/a.md", "content": "x"]))
    _ = try await harness.direct("write", .object(["path": "/docs/index.md", "content": "# docs"]))

    let file = try await harness.web(Request(url: URL(string: "http://space/a.md/")!))
    #expect(file.status == .notFound)

    let directory = try await harness.web(Request(url: URL(string: "http://space/docs/")!))
    #expect(directory.status == .ok)
  }

  @Test func bundledViewProvidersServeUnderTheUnderscoreNamespace() async throws {
    let providers = ViewProviders(files: [
      "kanban.html": Data("<html>kanban provider</html>".utf8),
      "kanban.js": Data("export {}".utf8),
    ])
    let harness = try Harness(views: providers)

    let bare = try await harness.get(harness.web, "/_/views/kanban")
    #expect(bare.status == .ok)
    #expect(bare.headers[.contentType] == "text/html; charset=utf-8")
    #expect(bare.headers[.cacheControl] == "no-cache")
    #expect(try await bare.text() == importMap + "<html>kanban provider</html>" + injection)

    let asset = try await harness.get(harness.web, "/_/views/kanban.js")
    #expect(asset.headers[.contentType] == "text/javascript; charset=utf-8")

    let missing = try await harness.get(harness.web, "/_/views/gantt")
    #expect(missing.status == .notFound)
    let empty = try await harness.get(harness.web, "/_/views")
    #expect(empty.status == .notFound)
  }

  @Test func wallAndMapAreServedByTheListProvider() async throws {
    let providers = ViewProviders(files: ["list.html": Data("<html>list provider</html>".utf8)])
    let harness = try Harness(views: providers)

    for kind in ["list", "wall", "map"] {
      let response = try await harness.get(harness.web, "/_/views/\(kind)")
      #expect(response.status == .ok)
      #expect(response.headers[.contentType] == "text/html; charset=utf-8")
      #expect(try await response.text() == importMap + "<html>list provider</html>" + injection)
    }

    let missing = try await harness.get(harness.web, "/_/views/kanban")
    #expect(missing.status == .notFound)
  }

  @Test func spaceFilesCannotShadowBundledProviders() async throws {
    let providers = ViewProviders(files: ["kanban.html": Data("<html>bundled</html>".utf8)])
    let harness = try Harness(views: providers)
    await #expect(throws: (any Error).self) {
      _ = try await harness.direct("write", .object(["path": "/_/views/kanban", "content": "impostor"]))
    }
    let response = try await harness.get(harness.web, "/_/views/kanban")
    #expect(try await response.text() == importMap + "<html>bundled</html>" + injection)
  }

  @Test func noBundledProvidersMeansViews404() async throws {
    let harness = try Harness()
    let response = try await harness.get(harness.web, "/_/views/kanban")
    #expect(response.status == .notFound)
  }

  @Test func viewFilesServeAsJSON() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/board.view", "content": #"{"view":"kanban"}"#]))
    let response = try await harness.get(harness.web, "/board.view")
    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "application/json")
  }

  @Test func corsReflectsOnlyThePairedAPIOrigin() async throws {
    let harness = try Harness()
    _ = try await harness.direct("write", .object(["path": "/font.woff2", "content": "f"]))
    let url = URL(string: "http://space/font.woff2")!
    let paired = "http://space:\(Harness.apiPort)"

    var headers = RequestHeaders()
    headers[.origin] = paired
    let allowed = try await harness.web(Request(url: url, headers: headers))
    #expect(allowed.status == .ok)
    #expect(allowed.headers[.accessControlAllowOrigin] == paired)
    #expect(allowed.headers[.accessControlAllowCredentials] == "true")
    #expect(allowed.headers[.vary] == "Origin")

    headers[.origin] = "http://space:\(Harness.apiPort + 1)"
    let wrongPort = try await harness.web(Request(url: url, headers: headers))
    #expect(wrongPort.headers[.accessControlAllowOrigin] == nil)
    #expect(wrongPort.headers[.vary] == "Origin")

    headers[.origin] = "http://evil.example:\(Harness.apiPort)"
    let foreignHost = try await harness.web(Request(url: url, headers: headers))
    #expect(foreignHost.headers[.accessControlAllowOrigin] == nil)

    headers[.origin] = "https://space:\(Harness.apiPort)"
    let wrongScheme = try await harness.web(Request(url: url, headers: headers))
    #expect(wrongScheme.headers[.accessControlAllowOrigin] == nil)

    let noOrigin = try await harness.web(Request(url: url))
    #expect(noOrigin.headers[.accessControlAllowOrigin] == nil)
    #expect(noOrigin.headers[.vary] == "Origin")
  }

  @Test func corsReflectsTheAdvertisedOriginBehindAProxy() async throws {
    let harness = try Harness(origin: "https://example.test")
    _ = try await harness.direct("write", .object(["path": "/font.woff2", "content": "f"]))
    // The proxy terminates TLS on 443 and forwards to the backend web listener;
    // the browser origin is the advertised canonical origin, not the raw port.
    let url = URL(string: "https://example.test/font.woff2")!

    var headers = RequestHeaders()
    headers[.origin] = "https://example.test"
    let allowed = try await harness.web(Request(url: url, headers: headers))
    #expect(allowed.status == .ok)
    #expect(allowed.headers[.accessControlAllowOrigin] == "https://example.test")
    #expect(allowed.headers[.accessControlAllowCredentials] == "true")

    headers[.origin] = "https://evil.test"
    let foreign = try await harness.web(Request(url: url, headers: headers))
    #expect(foreign.headers[.accessControlAllowOrigin] == nil)
    #expect(foreign.headers[.accessControlAllowCredentials] == nil)

    // A --origin serve still admits the same-host raw-API-port fallback.
    headers[.origin] = "https://example.test:\(Harness.apiPort)"
    let fallback = try await harness.web(Request(url: url, headers: headers))
    #expect(fallback.headers[.accessControlAllowOrigin] == "https://example.test:\(Harness.apiPort)")
  }

  @Test func advertisedOriginWithExplicitPortMatchesOnlyThatPort() async throws {
    let harness = try Harness(origin: "https://example.test:8443")
    _ = try await harness.direct("write", .object(["path": "/font.woff2", "content": "f"]))
    let url = URL(string: "https://example.test:8443/font.woff2")!

    var headers = RequestHeaders()
    headers[.origin] = "https://example.test:8443"
    let exact = try await harness.web(Request(url: url, headers: headers))
    #expect(exact.headers[.accessControlAllowOrigin] == "https://example.test:8443")

    headers[.origin] = "https://example.test"
    let implicit443 = try await harness.web(Request(url: url, headers: headers))
    #expect(implicit443.headers[.accessControlAllowOrigin] == nil)

    headers[.origin] = "https://example.test:9000"
    let otherPort = try await harness.web(Request(url: url, headers: headers))
    #expect(otherPort.headers[.accessControlAllowOrigin] == nil)
  }

  @Test func sessionPreflightAllowsTheAdvertisedOriginBehindAProxy() async throws {
    let harness = try Harness(origin: "https://example.test")
    let url = URL(string: "https://example.test/_/session")!
    var headers = RequestHeaders()
    headers[.origin] = "https://example.test"
    headers[.accessControlRequestMethod] = "POST"
    headers[.accessControlRequestHeaders] = "Authorization"

    let response = try await harness.web(Request(url: url, method: .options, headers: headers))
    #expect(response.status == .noContent)
    #expect(response.headers[.accessControlAllowOrigin] == "https://example.test")
    #expect(response.headers[.accessControlAllowCredentials] == "true")
    #expect(response.headers[.accessControlAllowMethods] == "GET, POST, DELETE")
    #expect(response.headers[.accessControlAllowHeaders] == "Authorization")
  }

  @Test func advertisedWebOriginIsNeverAValidRequester() async throws {
    let harness = try Harness(origin: "https://example.test", webOrigin: "https://web.example.test")
    _ = try await harness.direct("write", .object(["path": "/font.woff2", "content": "f"]))
    let url = URL(string: "https://example.test/font.woff2")!

    var headers = RequestHeaders()
    headers[.origin] = "https://web.example.test"
    let webOriginRequester = try await harness.web(Request(url: url, headers: headers))
    #expect(webOriginRequester.headers[.accessControlAllowOrigin] == nil)
    #expect(webOriginRequester.headers[.accessControlAllowCredentials] == nil)
  }

  @Test func sessionPreflightAllowsOnlyThePairedOriginAndBearerHeader() async throws {
    let harness = try Harness()
    let url = URL(string: "http://space/_/session")!
    let paired = "http://space:\(Harness.apiPort)"
    var headers = RequestHeaders()
    headers[.origin] = paired
    headers[.accessControlRequestMethod] = "POST"
    headers[.accessControlRequestHeaders] = "Authorization"

    let response = try await harness.web(Request(url: url, method: .options, headers: headers))
    #expect(response.status == .noContent)
    #expect(response.headers[.accessControlAllowOrigin] == paired)
    #expect(response.headers[.accessControlAllowCredentials] == "true")
    #expect(response.headers[.accessControlAllowMethods] == "GET, POST, DELETE")
    #expect(response.headers[.accessControlAllowHeaders] == "Authorization")
    #expect(response.headers[.vary] == "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")

    headers[.origin] = "http://elsewhere:\(Harness.apiPort)"
    let rejected = try await harness.web(Request(url: url, method: .options, headers: headers))
    #expect(rejected.status == .noContent)
    #expect(rejected.headers[.accessControlAllowOrigin] == nil)
    #expect(rejected.headers[.accessControlAllowCredentials] == nil)

    let other = try await harness.web(Request(url: URL(string: "http://space/index.md")!, method: .options))
    #expect(other.status == .methodNotAllowed)
  }

  @Test func sessionBootstrapMintsAReadSessionFromTheVerifiedBearer() async throws {
    let harness = try Harness(dev: false)
    let identity = try await harness.space.identity().rawValue
    let key = Curve25519.Signing.PrivateKey()
    let account = try await harness.space.addAccount(kind: .human, name: "reader")
    _ = try await harness.space.addKey(
      key.pubkeyLabel,
      account: account.id,
      capabilities: [.device],
      createdBy: nil,
      expiresAt: nil,
    )
    // A deliberately short bearer: the read cookie's lifetime must be the
    // server's own TTL, never this `exp`.
    let assertion = try AssertionClaims(
      key: key.pubkeyLabel,
      space: identity,
      expiresAt: fixedDate.addingTimeInterval(60),
    ).signed(by: key)
    var headers = RequestHeaders()
    headers[.authorization] = "Bearer " + assertion.rawValue
    headers[.origin] = "http://space:\(Harness.apiPort)"

    let response = try await harness.web(Request(
      url: URL(string: "http://space/_/session")!,
      method: .post,
      headers: headers,
    ))
    #expect(response.status == .noContent)
    #expect(response.headers[.accessControlAllowOrigin] == headers[.origin])
    #expect(response.headers[.accessControlAllowCredentials] == "true")
    let cookies = response.headers[values: .setCookie]
    #expect(cookies.count == 2)
    let cookie = try #require(cookies.first)
    #expect(cookie.hasSuffix("; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=43200"))
    // The page worker reads its cache as the account this names; what the
    // origin stores is never wiped.
    #expect(cookies.last == "wuhu_viewer=\(account.id.rawValue); Path=/; Secure; SameSite=Lax; Max-Age=34560000")
    #expect(response.headers[clearSiteData] == nil)
    let rawToken = String(try #require(cookie.split(separator: ";").first).dropFirst("wuhu_read=".count))
    #expect(ReadSessionToken.isValid(rawToken))
    #expect(try await harness.space.account(readSession: ReadSessionToken(rawValue: rawToken), in: .shared) == account.id)

    var cookieHeaders = RequestHeaders()
    cookieHeaders[.cookie] = "wuhu_read=" + rawToken
    let api = try await harness.api(Request(url: URL(string: "http://space/v1/machine")!, headers: cookieHeaders))
    #expect(api.status == .unauthorized)

    // A re-mint carrying the current cookie supersedes it, so a browsing
    // session leaves one live row, not one per page load.
    var reMintHeaders = headers
    reMintHeaders[.cookie] = "wuhu_read=" + rawToken
    let reMinted = try await harness.web(Request(url: URL(string: "http://space/_/session")!, method: .post, headers: reMintHeaders))
    let reCookie = try #require(reMinted.headers[values: .setCookie].first)
    let secondToken = String(try #require(reCookie.split(separator: ";").first).dropFirst("wuhu_read=".count))
    #expect(secondToken != rawToken)
    #expect(try await harness.space.account(readSession: ReadSessionToken(rawValue: rawToken), in: .shared) == nil)
    #expect(try await harness.space.account(readSession: ReadSessionToken(rawValue: secondToken), in: .shared) == account.id)

    // A cookie left by another account is superseded, and the viewer cookie
    // now names this one.
    let other = try await harness.space.addAccount(kind: .human, name: "other")
    let othersToken = try await harness.space.createReadSession(account: other.id, group: .shared, expiresAt: fixedDate.addingTimeInterval(3600))
    var switchHeaders = headers
    switchHeaders[.cookie] = "wuhu_read=" + othersToken.rawValue
    let switched = try await harness.web(Request(url: URL(string: "http://space/_/session")!, method: .post, headers: switchHeaders))
    #expect(switched.status == .noContent)
    #expect(try #require(switched.headers[values: .setCookie].last).hasPrefix("wuhu_viewer=\(account.id.rawValue);"))
    #expect(switched.headers[clearSiteData] == nil)

    var endHeaders = RequestHeaders()
    endHeaders[.cookie] = "wuhu_read=" + secondToken
    let ended = try await harness.web(Request(
      url: URL(string: "http://space/_/session")!,
      method: .delete,
      headers: endHeaders,
    ))
    #expect(ended.status == .noContent)
    #expect(ended.headers[values: .setCookie] == [
      "wuhu_read=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0",
      "wuhu_viewer=; Path=/; Secure; SameSite=Lax; Max-Age=0",
    ])
    #expect(ended.headers[clearSiteData] == nil)
    #expect(try await harness.space.account(readSession: ReadSessionToken(rawValue: secondToken), in: .shared) == nil)
  }

  @Test func sessionBootstrapDevAndPrivateAnonymousBehavior() async throws {
    let sessionURL = URL(string: "http://space/_/session")!
    let dev = try Harness(dev: true)
    let devResponse = try await dev.web(Request(url: sessionURL, method: .post))
    #expect(devResponse.status == .noContent)
    #expect(devResponse.headers[.setCookie] == nil)

    let asGet = try await dev.get(dev.web, "/_/session")
    #expect(asGet.status == .methodNotAllowed)

    let privateSpace = try Harness(dev: false)
    let denied = try await privateSpace.web(Request(url: sessionURL, method: .post))
    #expect(denied.status == .unauthorized)
    #expect(denied.headers[.setCookie] == nil)

    _ = try await privateSpace.direct("write", .object(["path": "/walled.html", "content": "private"]))
    let content = try await privateSpace.get(privateSpace.web, "/walled.html")
    #expect(content.status == .unauthorized)
  }
}

private let clearSiteData = HTTPField.Name("Clear-Site-Data")!
