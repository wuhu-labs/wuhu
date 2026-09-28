import SpaceFS
import Testing

struct SpacePathTests {
  @Test func `a valid absolute path keeps its raw form and components`() throws {
    let path = try SpacePath(validating: "/notes/2026/todo.md")
    #expect(path.rawValue == "/notes/2026/todo.md")
    #expect(path.components == ["notes", "2026", "todo.md"])
    #expect(path.lastComponent == "todo.md")
    #expect(!path.isRoot)
  }

  @Test func `root is representable with no components`() throws {
    let root = try SpacePath(validating: "/")
    #expect(root.isRoot)
    #expect(root.components.isEmpty)
    #expect(root.rawValue == "/")
    #expect(root.lastComponent == nil)
  }

  @Test func `a non-absolute path is rejected`() {
    #expect(throws: SpacePathError.notAbsolute("notes/todo.md")) {
      try SpacePath(validating: "notes/todo.md")
    }
  }

  @Test func `empty components are rejected, not normalized away`() {
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes//todo.md") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/") }
  }

  @Test func `dot and dot-dot components are rejected`() {
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/./todo.md") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/../todo.md") }
  }

  @Test func `the at and percent delimiters are banned from components`() {
    #expect(throws: SpacePathError.invalidComponent("todo@1", in: "/notes/todo@1")) {
      try SpacePath(validating: "/notes/todo@1")
    }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a%20b") }
  }

  @Test func `the hash and question URI metacharacters are banned from components`() {
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a#b") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/what?.md") }
  }

  @Test func `control characters are banned from components`() {
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a\tb") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a\u{01}b") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a\u{7F}b") }
  }

  @Test func `format, line and paragraph separators, and all-whitespace components are banned`() {
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/a\u{200B}b.md") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/docs/\u{202E}dm.evil") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/a\u{2028}b") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/a\u{2029}b") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/   ") }
    #expect(throws: SpacePathError.self) { try SpacePath(validating: "/notes/\u{2000}") }
  }

  @Test func `spaces and unicode letters are allowed`() throws {
    let path = try SpacePath(validating: "/my docs/café.md")
    #expect(path.components == ["my docs", "café.md"])
  }

  @Test func `validation normalizes to NFC so the raw value is one canonical byte form`() throws {
    let nfc = try SpacePath(validating: "/caf\u{00E9}.md")
    let nfd = try SpacePath(validating: "/cafe\u{0301}.md")
    #expect(nfc == nfd)
    #expect(nfd.rawValue == "/caf\u{00E9}.md")
    #expect(Array(nfd.rawValue.utf8) == Array("/caf\u{00E9}.md".utf8))
    #expect(Array(nfc.rawValue.utf8) == Array(nfd.rawValue.utf8))
  }

  @Test func `the root underscore namespace is constructible but flagged reserved`() throws {
    #expect(try SpacePath(validating: "/_/query").isReserved)
    #expect(try SpacePath(validating: "/_").isReserved)
    #expect(try !SpacePath(validating: "/notes/_/x").isReserved)
    #expect(try !SpacePath(validating: "/notes/todo.md").isReserved)
    #expect(try !SpacePath(validating: "/sessions/foo.md").isReserved)
  }

  @Test func `only the inside of a session home is writable under the underscore namespace`() throws {
    #expect(try !SpacePath(validating: "/_/sessions/s1/notes.md").isReserved)
    #expect(try !SpacePath(validating: "/_/sessions/s1/.agents/skills/x/SKILL.md").isReserved)
    #expect(try SpacePath(validating: "/_/sessions/s1").isReserved)
    #expect(try SpacePath(validating: "/_/sessions").isReserved)
    #expect(try SpacePath(validating: "/_/conversations/c1/attachments/2026/09/25/052449Z/a.png").isReserved)
  }

  @Test func `the inside of a stored machine notes folder is writable under the underscore namespace`() throws {
    #expect(try !SpacePath(validating: "/_/machines/mc_0000abcd/AGENTS.md").isReserved)
    #expect(try !SpacePath(validating: "/_/machines/mc_0000abcd/.agents/skills/x/SKILL.md").isReserved)
    #expect(try SpacePath(validating: "/_/machines/mc_0000abcd").isReserved)
    #expect(try SpacePath(validating: "/_/machines").isReserved)
    #expect(try SpacePath(validating: "/_/machines/studio/AGENTS.md").isReserved)
    #expect(try SpacePath(validating: "/_/machines/mc_0000abcd/AGENTS.md").homeOwner == nil)
  }

  @Test func `a path under a session home names its owner`() throws {
    #expect(try SpacePath(validating: "/_/sessions/s1/.agents/skills/x/SKILL.md").homeOwner == "s1")
    #expect(try SpacePath(validating: "/_/sessions/s1").homeOwner == "s1")
    #expect(try SpacePath(validating: "/_/sessions").homeOwner == nil)
    #expect(try SpacePath(validating: "/sessions/s1/notes.md").homeOwner == nil)
    #expect(try SpacePath(validating: "/_/conversations/c1/a.png").homeOwner == nil)
  }

  @Test func `parent drops the last component and bottoms out at root`() throws {
    #expect(try SpacePath(validating: "/a/b/c").parent.rawValue == "/a/b")
    #expect(try SpacePath(validating: "/a").parent.rawValue == "/")
    #expect(try SpacePath(validating: "/").parent.rawValue == "/")
  }

  @Test func `resolving extends a relative reference against the receiver`() throws {
    let base = try SpacePath(validating: "/notes")
    #expect(base.resolving("a.md")?.rawValue == "/notes/a.md")
    #expect(base.resolving("sub/b.md")?.rawValue == "/notes/sub/b.md")
    #expect(base.resolving("./a.md")?.rawValue == "/notes/a.md")
    #expect(base.resolving("../x.md")?.rawValue == "/x.md")
    #expect(base.resolving("/abs.md")?.rawValue == "/abs.md")
  }

  @Test func `resolving rejects references that escape root, protocol-relative, or the charset`() throws {
    let base = try SpacePath(validating: "/notes")
    #expect(base.resolving("../../escape") == nil)
    #expect(base.resolving("//host/x") == nil)
    #expect(base.resolving("a@b.md") == nil)
    #expect(base.resolving("a#b.md") == nil)
  }

  @Test func `resolving to root yields the root path, not nil`() throws {
    let base = try SpacePath(validating: "/notes")
    #expect(base.resolving("/")?.rawValue == "/")
    #expect(base.resolving("..")?.rawValue == "/")
    #expect(try SpacePath(validating: "/a/b").resolving("../..")?.rawValue == "/")
  }

  @Test func `resolving shares one grammar authority with validation`() throws {
    let base = try SpacePath(validating: "/notes")
    // Interior empty segments fail instead of silently collapsing, matching init(validating:).
    #expect(base.resolving("a//b.md") == nil)
    #expect((try? SpacePath(validating: "/notes/a//b.md")) == nil)
    // An empty reference resolves to nothing, never a self-reference.
    #expect(base.resolving("") == nil)
    // NFD references normalize through validation.
    #expect(base.resolving("cafe\u{0301}.md")?.rawValue == "/notes/caf\u{00E9}.md")
  }

  @Test func `paths order lexicographically by raw value`() throws {
    let a = try SpacePath(validating: "/a")
    let b = try SpacePath(validating: "/b")
    #expect(a < b)
    #expect([b, a].sorted() == [a, b])
  }
}
