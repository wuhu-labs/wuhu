import Foundation
import Testing
import WuhuVFS

struct VFSPathTests {
  @Test func `child names accept valid names and reject invalid names`() {
    #expect(VFSPathComponent(rawValue: "note.txt")?.rawValue == "note.txt")
    #expect(VFSPathComponent(rawValue: "renamed note.txt")?.rawValue == "renamed note.txt")

    for invalid in ["", ".", "..", "nested/file.txt", "nested\\file.txt"] {
      #expect(VFSPathComponent(rawValue: invalid) == nil)
    }
  }

  @Test func `root round trips through codable and absolute file path`() throws {
    let encoded = try JSONEncoder().encode(VFSPath.root)
    let decoded = try JSONDecoder().decode(VFSPath.self, from: encoded)

    #expect(decoded == .root)
    #expect(decoded.absoluteFilePath == "/")
    #expect(try VFSPath(absoluteFilePath: "/") == .root)
  }

  @Test func `absolute file path rejects invalid components`() {
    #expect(throws: VFSPathError.invalidComponent(".")) { _ = try VFSPath(absoluteFilePath: "/safe/.") }
    #expect(throws: VFSPathError.invalidComponent("..")) { _ = try VFSPath(absoluteFilePath: "/safe/..") }
    #expect(throws: VFSPathError.invalidComponent("")) { _ = try VFSPath(absoluteFilePath: "/safe//leaf") }
  }

  @Test func `stripping scheme and host decodes URL paths and treats empty path as root`() throws {
    #expect(try VFSPath(strippingSchemeAndHost: #require(URL(string: "wuhu://host"))) == .root)
    #expect(try VFSPath(strippingSchemeAndHost: #require(URL(string: "wuhu://host/"))) == .root)
    #expect(
      try VFSPath(strippingSchemeAndHost: #require(URL(string: "wuhu://host/renamed%20note.txt"))).absoluteFilePath
        == "/renamed note.txt",
    )
    #expect(
      try VFSPath(absoluteFilePath: "/100% done").url(scheme: "wuhu", host: "host").absoluteString
        == "wuhu://host/100%25%20done",
    )

    #expect(throws: VFSPathError.invalidComponent("nested/file.txt")) {
      _ = try VFSPath(strippingSchemeAndHost: #require(URL(string: "wuhu://host/nested%2Ffile.txt")))
    }
  }

  @Test func `relative resolution normalizes dot segments without escaping root`() throws {
    let base = try VFSPath(absoluteFilePath: "/docs/v1")
    let guide = try VFSPath(absoluteFilePath: "/docs/v1/guide.md")
    let image = try VFSPath(absoluteFilePath: "/docs/assets/image.png")
    #expect(try base.resolving(relativeSlashPath: "./guide.md") == guide)
    #expect(try base.resolving(relativeSlashPath: "../assets/image.png") == image)

    #expect(throws: VFSPathError.pathEscape("../../outside")) {
      _ = try VFSPath.root.resolving(relativeSlashPath: "../../outside")
    }
  }

  @Test func `parent last component and appending handle root and non-root paths`() throws {
    let docs = try VFSPath(absoluteFilePath: "/docs")
    let note = docs.appending(try #require(VFSPathComponent(rawValue: "note.txt")))

    #expect(VFSPath.root.parent == nil)
    #expect(VFSPath.root.lastComponent == nil)
    #expect(docs.parent == .root)
    #expect(docs.lastComponent?.rawValue == "docs")
    #expect(note.parent == docs)
    #expect(note.lastComponent?.rawValue == "note.txt")
    #expect(note.absoluteFilePath == "/docs/note.txt")
  }
}
