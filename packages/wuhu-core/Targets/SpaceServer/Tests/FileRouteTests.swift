import DeterministicDependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import SpaceContract
import SpaceCore
import struct SpaceFS.SpacePath
@testable import SpaceServer
import Testing

// A 1x1 transparent PNG: a real byte sequence with a signature, a NUL run, and
// deflate bytes that are not valid UTF-8.
private let onePixelPNG = Data([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])

@Suite(.deterministicDependencies) struct FileRouteTests {
  @Test func bytesRoundTripThroughTheByteRoutes() async throws {
    let harness = try Harness()

    let written = try await harness.put("/logo.png", onePixelPNG)
    #expect(written.status == .ok)
    let version = try await json(written)
    #expect(version.field("rev") == .integer(1))

    let read = try await harness.get(harness.api, "/v1/f/logo.png")
    #expect(read.status == .ok)
    #expect(read.headers[.contentType] == "image/png")
    #expect(read.headers[.contentLength] == String(onePixelPNG.count))
    #expect(try await read.data() == onePixelPNG)
    #expect(read.headers[.eTag] == version.field("token").map { "\"\($0.text ?? "")\"" })
  }

  @Test func aBinaryFileRefusesTheTextToolWireInsteadOfCorrupting() async throws {
    let harness = try Harness()
    #expect(try await harness.put("/logo.png", onePixelPNG).status == .ok)

    let read = try await harness.post("read", .object(["path": "/logo.png"]))
    #expect(read.status == .unprocessableContent)
    let failure = try await json(read)
    #expect(failure.field("code") == .string("unsupported"))
    #expect(failure.field("hint")?.text?.contains("wuhu cat") == true)

    let edit = try await harness.post("edit", .object([
      "path": "/logo.png",
      "edits": .array([.object(["old": "a", "new": "b"])]),
    ]))
    #expect(edit.status == .unprocessableContent)
    #expect((try await json(edit)).field("code") == .string("unsupported"))
  }

  @Test func ifMatchGuardsByteWritesAndMissingPathsAre404() async throws {
    let harness = try Harness()
    let first = try await json(try await harness.put("/a.bin", Data([0x00, 0xFF])))
    let token = try #require(first.field("token")?.text)

    let stale = try await harness.put("/a.bin", Data([0x01]), ifMatch: "\"999\"")
    #expect(stale.status == .conflict)
    #expect((try await json(stale)).field("code") == .string("conflict"))

    let fresh = try await harness.put("/a.bin", Data([0x01]), ifMatch: "\"\(token)\"")
    #expect(fresh.status == .ok)

    let missing = try await harness.get(harness.api, "/v1/f/nope.bin")
    #expect(missing.status == .notFound)
    #expect((try await json(missing)).field("code") == .string("notFound"))
  }

  @Test func historicalBytesReadThroughTheRevisionSuffix() async throws {
    let harness = try Harness()
    let first = try await json(try await harness.put("/a.bin", Data([0x01])))
    let token = try #require(first.field("token")?.text)
    #expect(try await harness.put("/a.bin", Data([0x02]), ifMatch: token).status == .ok)

    let historical = try await harness.get(harness.api, "/v1/f/a.bin@1")
    #expect(historical.status == .ok)
    #expect(try await historical.data() == Data([0x01]))
  }

  @Test func revisionAddressedWritesCannotChangeTheLiveFile() async throws {
    let harness = try Harness()
    let version = try await json(try await harness.put("/doc.md", Data("original".utf8)))
    let token = try #require(version.field("token")?.text)
    for path in ["/doc.md@1", "wuhu://shared.localspace/doc.md@1"] {
      let write = try await harness.post("write", ["path": .string(path), "content": "bad", "ifMatch": .string(token)])
      #expect(write.status == .unprocessableContent)
      #expect((try await json(write)).field("code") == "invalidPath")
    }
    let put = try await harness.put("/doc.md@1", Data("bad bytes".utf8), ifMatch: token)
    #expect(put.status == .badRequest)
    #expect((try await json(put)).field("code") == "invalidPath")
    let live = try await harness.get(harness.api, "/v1/f/doc.md")
    #expect(try await live.data() == Data("original".utf8))
    #expect(live.headers[.eTag] == "\"\(token)\"")
  }

  @Test func byteRoutesShareTheAPIWallWithTheJSONTools() async throws {
    let walled = try Harness(dev: false)
    for response in [
      try await walled.get(walled.api, "/v1/f/a.png"),
      try await walled.put("/a.png", onePixelPNG),
    ] {
      #expect(response.status == .unauthorized)
      #expect((try await json(response)).field("code") == .string("unauthorized"))
    }
  }

  // --public-read opens the content origin, never the API origin: the byte
  // routes must stay as walled as POST /v1/tools/read on a public board.
  @Test func publicReadOpensTheContentOriginButNotTheByteRoutes() async throws {
    let harness = try Harness(dev: false, publicRead: true)
    _ = try await harness.direct("write", .object(["path": "/board.md", "content": "public"]))

    let content = try await harness.get(harness.web, "/board.md")
    #expect(content.status == .ok)

    let bytes = try await harness.get(harness.api, "/v1/f/board.md")
    #expect(bytes.status == .unauthorized)
    let write = try await harness.put("/board.md", Data("defaced".utf8))
    #expect(write.status == .unauthorized)
    let webWrite = try await harness.web(Request(
      url: URL(string: "http://space/v1/f/board.md")!,
      method: .put,
      body: .bytes(Data("defaced".utf8), contentType: "application/octet-stream"),
    ))
    #expect(webWrite.status == .methodNotAllowed)
  }

  @Test func aJSXFileReadsCompiledAsJavaScript() async throws {
    let harness = try Harness()
    let source = "export const sizes = ['small']\nexport default () => <Figure value={1} label=\"One\" />\n"
    let written = try await json(try await harness.put("/.widgets/one.widget.jsx", Data(source.utf8)))
    let token = try #require(written.field("token")?.text)

    let compiled = try await harness.get(harness.api, "/v1/f/.widgets/one.widget.jsx", query: ["as": "js"])
    #expect(compiled.status == .ok)
    #expect(compiled.headers[.contentType] == "text/javascript; charset=utf-8")
    #expect(compiled.headers[.eTag] == "\"\(token).js\"")
    let code = String(decoding: try await compiled.data(), as: UTF8.self)
    #expect(code.contains("export const sizes = ['small']"))
    #expect(code.contains("h(Figure, { value: 1, label: \"One\""))

    let raw = try await harness.get(harness.api, "/v1/f/.widgets/one.widget.jsx")
    #expect(String(decoding: try await raw.data(), as: UTF8.self) == source)
  }

  @Test func theProvisionedEverythingCompiles() async throws {
    let harness = try Harness()
    try await provisionEverythingSidebar(harness.space)

    let compiled = try await harness.get(harness.api, "/v1/f/.sidebars/everything.sidebar.jsx", query: ["as": "js"])
    #expect(compiled.status == .ok)
    #expect(String(decoding: try await compiled.data(), as: UTF8.self).contains("h(Sidebar"))
  }

  @Test func aCompileHasAStepBudget() async throws {
    let compiler = JSXCompiler(stepBudget: 2000)
    #expect(try await compiler.javaScript("export default () => <Figure value={1} />", file: "/a.widget.jsx", version: "1").contains("h(Figure"))
    let huge = (0 ..< 20000).map { "export const v\($0) = <List rows={[{ label: '\($0)' }]} />" }.joined(separator: "\n")
    let failure = await #expect(throws: JSXCompiler.Failure.self) { try await compiler.javaScript(huge, file: "/huge.widget.jsx", version: "1") }
    #expect(failure?.message == "/huge.widget.jsx: too long to compile")
    #expect(try await compiler.javaScript("export default () => <Figure value={2} />", file: "/b.widget.jsx", version: "1").contains("value: 2"))
  }

  @Test func aSyntaxErrorNamesTheFileLineAndColumn() async throws {
    let harness = try Harness()
    #expect(try await harness.put("/bad.sidebar.jsx", Data("export default () => <Sidebar name=>".utf8)).status == .ok)

    let compiled = try await harness.get(harness.api, "/v1/f/bad.sidebar.jsx", query: ["as": "js"])
    #expect(compiled.status == .badRequest)
    let failure = try await json(compiled)
    #expect(failure.field("code") == .string("invalidArgument"))
    let message = try #require(failure.field("message")?.text)
    #expect(message.hasPrefix("/bad.sidebar.jsx: "))
    #expect(message.contains("(1:"))
  }

  @Test func onlyJSXHasAJavaScriptForm() async throws {
    let harness = try Harness()
    #expect(try await harness.put("/note.md", Data("# Note".utf8)).status == .ok)

    let compiled = try await harness.get(harness.api, "/v1/f/note.md", query: ["as": "js"])
    #expect(compiled.status == .badRequest)
    #expect((try await json(compiled)).field("code") == .string("invalidArgument"))
  }

  @Test func everythingIsWrittenWhenMissingAndKeptWhenEdited() async throws {
    let harness = try Harness()
    let path = try SpacePath(validating: "/.sidebars/everything.sidebar.jsx")

    try await provisionEverythingSidebar(harness.space)
    let provisioned = try await harness.context.readBytes("/.sidebars/everything.sidebar.jsx")
    #expect(String(decoding: provisioned.data, as: UTF8.self).contains("<Sidebar name='Everything'"))

    _ = try await harness.space.writeFile(path, data: Data("export default () => <Sidebar name='Mine' />".utf8), in: .shared, acting: .shared, ifMatch: nil, createOnly: false)
    try await provisionEverythingSidebar(harness.space)
    let edited = try await harness.context.readBytes("/.sidebars/everything.sidebar.jsx")
    #expect(String(decoding: edited.data, as: UTF8.self).contains("'Mine'"))

    #expect(try await harness.post("rm", ["path": "/.sidebars/everything.sidebar.jsx"]).status == .ok)
    try await provisionEverythingSidebar(harness.space)
    let restored = try await harness.context.readBytes("/.sidebars/everything.sidebar.jsx")
    #expect(String(decoding: restored.data, as: UTF8.self).contains("<Sidebar name='Everything'"))
  }
}

private extension Harness {
  func put(_ path: String, _ data: Data, ifMatch: String? = nil) async throws -> Response {
    var headers = RequestHeaders()
    if let ifMatch { headers[.ifMatch] = ifMatch }
    return try await self.api(Request(
      url: URL(string: "http://space/v1/f" + path)!,
      method: .put,
      headers: headers,
      body: .bytes(data, contentType: "application/octet-stream"),
    ))
  }
}

private extension JSONValue {
  func field(_ name: String) -> JSONValue? {
    guard case let .object(fields) = self else { return nil }
    return fields[name]
  }

  var text: String? {
    guard case let .string(value) = self else { return nil }
    return value
  }
}
