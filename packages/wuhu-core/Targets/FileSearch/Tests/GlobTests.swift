import FileSearch
import Testing

/// find's glob dialect (gitignore's), seen through find and `.gitignore`.
@Suite struct GlobTests {
  /// Whether `find(pattern)` from `/` finds a file at `path`.
  private func finds(_ pattern: String, _ path: String) async throws -> Bool {
    let tree = MemoryTree(files: ["/" + path: ""])
    let page = try await SearchQuery(mode: .find, pattern: pattern, root: "/", scope: "test").run(in: tree)
    return page.hits.map(\.path) == ["/" + path]
  }

  @Test(arguments: [
    ("*.swift", "a.swift", true),
    ("*.swift", "src/deep/a.swift", true),
    ("*.swift", "a.swift.bak", false),
    ("src/*.swift", "src/a.swift", true),
    ("src/*.swift", "src/x/a.swift", false),
    ("src/*.swift", "lib/src/a.swift", false),
    ("/a", "a", true),
    ("/a", "x/a", false),
    ("**/a", "a", true),
    ("**/a", "x/y/a", true),
    ("a/**", "a/b/c", true),
    ("a/**", "a", false),
    ("a/**/b", "a/b", true),
    ("a/**/b", "a/x/y/b", true),
    ("a?c", "abc", true),
    ("a?c", "a/c", false),
    ("[abc]x", "bx", true),
    ("[!abc]x", "bx", false),
    ("[^abc]x", "dx", true),
    ("[a-c]x", "cx", true),
    ("[]]", "]", true),
    ("[a-]", "-", true),
    ("\\*", "*", true),
    ("\\*", "a", false),
    ("é*", "étoile", true),
    ("a*b*c", "aXbYbZc", true),
    ("a*b*c", "aXbYbZ", false),
  ])
  func matches(_ pattern: String, _ path: String, _ expected: Bool) async throws {
    #expect(try await finds(pattern, path) == expected)
  }

  @Test func aTrailingSlashMatchesDirectoriesOnly() async throws {
    let tree = MemoryTree(files: ["/x/.gitignore": "build/\n", "/x/a/build/out": "", "/x/b/build": ""])
    let page = try await SearchQuery(mode: .find, pattern: "*", root: "/x", scope: "test").run(in: tree)
    #expect(page.hits.map(\.path) == ["/x/b/build"])
  }

  @Test(arguments: ["[abc", "a\\", "", "/", "a//b", "[z-a]"])
  func malformedGlobsAreRefused(_ pattern: String) {
    let error = #expect(throws: SearchError.self) {
      try SearchQuery(mode: .find, pattern: pattern, root: "/", scope: "test").validate()
    }
    #expect(error?.code == .invalidGlob)
  }
}
