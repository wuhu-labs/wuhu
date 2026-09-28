#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import Testing

@Suite struct MultipartTests {
  @Test func readerReturnsWhatTheFormWrote() async throws {
    let payload = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    var form = MultipartForm(boundary: "----wuhu-test")
    form.appendField("text", "hello\r\nworld")
    form.appendFile(name: "file", filename: "clip \"one\".mp4", contentType: "video/mp4", bytes: payload)
    form.appendFile(name: "file", filename: "empty.txt", contentType: "text/plain", bytes: Data())
    let body = form.finish()

    let parts = try await Self.read(body, contentType: form.contentType)

    #expect(parts.map(\.0) == [
      MultipartPart(name: "text", filename: nil, contentType: nil),
      MultipartPart(name: "file", filename: "clip %22one%22.mp4", contentType: "video/mp4"),
      MultipartPart(name: "file", filename: "empty.txt", contentType: "text/plain"),
    ])
    #expect(parts[0].1 == Data("hello\r\nworld".utf8))
    #expect(parts[1].1 == payload)
    #expect(parts[2].1.isEmpty)
  }

  @Test func readerFindsBoundariesSplitAcrossTransportChunks() async throws {
    var form = MultipartForm(boundary: "b")
    form.appendField("a", "one")
    form.appendField("b", "two")
    let whole = try await form.finish().bytes()
    let trickled = Body.chunks(whole.map { Data([$0]) })

    let parts = try await Self.read(trickled, contentType: form.contentType)

    #expect(parts.map(\.0.name) == ["a", "b"])
    #expect(parts.map { String(decoding: $0.1, as: UTF8.self) } == ["one", "two"])
  }

  @Test func readerSkipsAPartTheCallerDidNotRead() async throws {
    var form = MultipartForm(boundary: "x")
    form.appendFile(name: "file", filename: "skip.bin", contentType: "application/octet-stream", bytes: Data(repeating: 7, count: 70000))
    form.appendField("after", "kept")
    var reader = try MultipartReader(body: form.finish(), contentType: form.contentType)

    #expect(try await reader.nextPart()?.filename == "skip.bin")
    #expect(try await reader.nextPart()?.name == "after")
    var kept = Data()
    while let chunk = try await reader.nextChunk() {
      kept.append(chunk)
    }
    #expect(kept == Data("kept".utf8))
    #expect(try await reader.nextPart() == nil)
  }

  @Test func readerRefusesATruncatedBody() async throws {
    let body = Body.bytes(Data("--x\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\npartial".utf8))
    var reader = try MultipartReader(body: body, contentType: "multipart/form-data; boundary=x")

    _ = try await reader.nextPart()
    var failure: (any Error)?
    do {
      while try await reader.nextChunk() != nil {}
    } catch {
      failure = error
    }
    #expect(failure as? MultipartError == .malformed("the body ended inside a part"))
  }

  @Test func boundaryComesFromTheContentType() {
    #expect(MultipartReader.boundary(of: "multipart/form-data; boundary=abc") == "abc")
    #expect(MultipartReader.boundary(of: "Multipart/Form-Data;boundary=\"a b\"") == "a b")
    #expect(MultipartReader.boundary(of: "application/json") == nil)
    #expect(MultipartReader.boundary(of: "multipart/form-data") == nil)
    #expect(throws: MultipartError.notMultipart) {
      try MultipartReader(body: .empty, contentType: "text/plain")
    }
  }

  private static func read(_ body: Body, contentType: String) async throws -> [(MultipartPart, Data)] {
    var reader = try MultipartReader(body: body, contentType: contentType)
    var parts: [(MultipartPart, Data)] = []
    while let part = try await reader.nextPart() {
      var bytes = Data()
      while let chunk = try await reader.nextChunk() {
        bytes.append(chunk)
      }
      parts.append((part, bytes))
    }
    return parts
  }
}
